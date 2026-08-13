import agtermCore
import AppKit
import SwiftUI

/// `WindowContentView`'s detail deck: every session's terminal content — panes, split, scratch, and both
/// overlay kinds — plus the inactive-pane mute.
extension WindowContentView {
    /// A DECK of EVERY session's terminal, all mounted so each spawns its shell at startup, only the selected
    /// one visible + hit-testable. Switching is a visibility flip; a re-host would invalidate the Metal
    /// drawable and flicker.
    @ViewBuilder var detailPane: some View {
        let sessions = store.workspaces.flatMap(\.sessions)
        ZStack {
            if store.activeSession == nil {
                Text("No session selected")
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions, id: \.id) { session in
                let isActive = session.id == store.selectedSessionID
                sessionDetail(session, isActive: isActive)
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
            }
        }
    }

    /// One session's terminal content: the primary pane, an axis-aware split, or the
    /// maximized hidden-split pane, plus any overlay. `isActive` gates which pane auto-grabs focus — the
    /// visible deck entry, and within a split the focused pane.
    ///
    /// CONSTANT SHAPE, the rule the rest of this file defers to: no per-session state may add or remove a
    /// child or a modifier above an arranged subview, or AppKit re-hosts the `NSSplitView` — which
    /// re-lays-out, normalizes the divider away from the stored ratio, and overruns into the titlebar. The
    /// boundary is the arranged subview: INSIDE one, a constant-shape ZStack may swap children and vary
    /// modifier values freely; above one even a value flip is suspect, hence `.allowsHitTesting` below.
    /// For the same reason zoom swaps only its own slot to a placeholder (an NSView lives in one host at
    /// a time) rather than unmounting the entry, so a control-opened split/scratch/overlay keeps running
    /// behind it.
    @ViewBuilder private func sessionDetail(_ session: Session, isActive: Bool) -> some View {
        // a FULL overlay (no size) hides the panes and draws translucent; a FLOATING one leaves them VISIBLE
        // under a smaller opaque framed panel. Either way the pane(s) stay non-interactive while one is up.
        let fullOverlay = session.fullOverlayActive
        // while zoomed OR the dashboard is open (mutually exclusive) the deck stays mounted only to realize
        // surfaces: no focus, no drag targets, no focusable controls behind the full-window modal layer.
        let deckInteractive = terminalZoom.target == nil && !dashboard.isOpen
        // the scratch is full-coverage too, so it hides the panes like a FULL overlay does. False for a
        // FLOATING overlay, whose opening must leave the shape alone.
        let hideForOverlay = fullOverlay || session.scratchActive
        // on-screen = selected, not hidden by a full overlay/scratch, not covered by the quick terminal.
        // Shared by BOTH split panes (unlike focus-gated `isActive`), it gates drag-type (un)registration and
        // mouse-cursor tracking (the `deckVisible` note in libghostty.md). Without the quick-terminal term a
        // covered pane races it for the cursor and fans mouse-motion into the covered TUI (issue #225).
        let visible = deckInteractive && isActive && !hideForOverlay && !quickTerminal.isVisible
        // focus gate: a visible quick terminal OWNS first responder, so no deck surface may be `isActive`
        // behind it — `updateNSView` would grab focus and send keystrokes to a covered session. Every
        // automatic reselection (`reselectIfSelectionHidden`, auto-follow) reaches this, not just a click.
        let focusable = deckInteractive && isActive && !quickTerminal.isVisible
        let gates = DeckPaneGates(focusable: focusable, overlaid: DeckPaneGates.coverActive(session),
                                  visible: visible)
        ZStack {
            // the pane(s) stay MOUNTED while an overlay is up so their shells stay alive; a FULL overlay
            // hides them (opacity 0) so its translucency reveals the window backing, not the session.
            Group {
                if session.isSplit {
                    shownSplit(session, gates: gates, deckInteractive: deckInteractive)
                } else if session.splitFocused, session.splitSurface != nil {
                    // split hidden while the right pane had focus: show that pane maximized.
                    deckPane(session, pane: .right, focused: true, gates: gates)
                } else {
                    deckPane(session, pane: .left, focused: true, gates: gates)
                }
            }
            .opacity(hideForOverlay ? 0 : 1)
            // gate on `hideForOverlay`, NOT `session.overlayActive`: a floating overlay opening must not
            // change this modifier (constant shape). Floating leaves the panes hit-testable;
            // `overlayPanel`'s transparent catcher absorbs the clicks around it.
            .allowsHitTesting(deckInteractive && !hideForOverlay)
            // the scratch renders in-deck above the hidden pane(s), BELOW the ephemeral overlay (zIndex 1 vs
            // `overlayPanel`'s 3), and hides under a FULL overlay like they do: under window translucency
            // every surface background renders fully transparent, so a visible scratch would show THROUGH it.
            // A FLOATING panel's opaque backing needs no such hiding.
            if session.scratchActive, deckHostsSurface(session: session, surface: .scratch) {
                // a full overlay renders above the scratch, so it gates focus on top of `focusable` (matching
                // makeScratchSurface's autoFocus suppression); `deckVisible` keeps drops to an on-screen one.
                TerminalView(session: session, surfaceKeyPath: \.scratchSurface, makeSurface: makeScratchSurface,
                             isActive: focusable && !session.programOverlayActive,
                             deckVisible: deckInteractive && isActive && !fullOverlay && !quickTerminal.isVisible)
                    .opacity(fullOverlay ? 0 : 1)
                    .allowsHitTesting(!fullOverlay)
                    .id("\(session.id.uuidString)-scratch")
                    .zIndex(1)
            }
            // renders IN-DECK per session, so its program runs even when the session isn't active;
            // `overlayPanel` owns the constant-shape rule.
            overlayPanel(session: session, isActive: focusable)
                .zIndex(3)
        }
        // on PROGRAM overlay close refocus the topmost remaining surface via `topmostSurface` — never a pane
        // hidden under the scratch. One makeFirstResponder loses the race with the overlay's teardown/re-host,
        // so drive the bounded retry the split-collapse survivor uses. Only the visible session reclaims focus:
        // the quick terminal owns it while it covers the window, and its own hide re-grabs the cover.
        //
        // Keyed on `programOverlayActive`, not the raw slot: a HUD never took first responder, so reclaiming
        // it on the HUD's close would instead YANK focus out of whatever holds it — an open ⌘F search field,
        // an in-progress sidebar rename — and `retryReparentFocus` re-grabs for ~0.36s.
        .onChange(of: session.programOverlayActive) { _, isOpen in
            if !isOpen, deckInteractive, isActive, !quickTerminal.isVisible {
                (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
            }
        }
        // the scratch needs the same retry on SHOW too: its surface is kept alive across hides, so a re-show
        // remounts it and `autoFocus`'s one-shot latch won't re-fire.
        .onChange(of: session.scratchActive) { _, _ in
            guard deckInteractive, isActive, !quickTerminal.isVisible else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
        // the deck is the authority on which panes it lays out, so it also retires a pane overlay whose pane
        // stopped being laid out before its surface ever realized — `AppStore.toggleSplit` covers show/hide,
        // this covers every other writer of `splitFocused` (`session.focus`, a pane click, the dashboard).
        // `dropUnrealizedPaneOverlays` spares a slot terminal zoom claims, so a zoom exit is the other moment
        // the last host can disappear: re-run it there too, else un-zooming a never-mounted target strands it.
        .onChange(of: session.renderedPanes) { _, _ in session.dropUnrealizedPaneOverlays() }
        .onChange(of: terminalZoom.target) { _, _ in session.dropUnrealizedPaneOverlays() }
        // a closing pane overlay un-hides its pane and loses the same race.
        .onChange(of: session.openPaneOverlays) { before, after in
            guard after.count < before.count, deckInteractive, isActive, !quickTerminal.isVisible else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
    }

    /// The terminal hosts keep their pane roles and surface identity when the split axis changes. Only the
    /// AppKit split container is replaced, transposing the existing primary/split pair in place.
    @ViewBuilder private func shownSplit(_ session: Session, gates: DeckPaneGates,
                                         deckInteractive: Bool) -> some View {
        if session.splitAxis == .topBottom {
            VSplitView {
                splitPrimaryPane(session, gates: gates, deckInteractive: deckInteractive)
                deckPane(session, pane: .right, focused: session.splitFocused, gates: gates)
            }
            .id("\(session.id.uuidString)-vsplit")
        } else {
            HSplitView {
                splitPrimaryPane(session, gates: gates, deckInteractive: deckInteractive)
                deckPane(session, pane: .right, focused: session.splitFocused, gates: gates)
            }
            .id("\(session.id.uuidString)-hsplit")
        }
    }

    /// The ratio probe belongs to the stable primary pane wrapper, never a third arranged subview.
    private func splitPrimaryPane(_ session: Session, gates: DeckPaneGates,
                                  deckInteractive: Bool) -> some View {
        deckPane(session, pane: .left, focused: !session.splitFocused, gates: gates)
            .background {
                SplitRatioAccessor(session: session, titlebarHeight: titlebarHeight,
                                   suspended: !deckInteractive,
                                   deckVisible: gates.visible && !gates.overlaid,
                                   onPersist: { store.save() })
            }
    }

    /// ONE pane of a session's deck entry: its terminal — or the `Color.clear` placeholder while zoom or the
    /// dashboard hosts that surface — under the always-present `paneOverlayPanel` sibling, in the
    /// constant-shape ZStack `sessionDetail` requires. This is the arranged subview of a shown split, so the
    /// `.background` probe and any per-session chrome go INSIDE here or on the result, never on a wrapper.
    ///
    /// `focused` is this pane's share of split focus: the unfocused side of a SHOWN split, else true, since a
    /// pane alone on screen always has it. It gates auto-focus for both the pane and its overlay — one
    /// opening on the other pane must not pull focus off the live one — and doubles as the `paneDim` mute,
    /// which therefore renders only on the unfocused pane of a shown split.
    @ViewBuilder private func deckPane(_ session: Session, pane: OverlayPane, focused: Bool,
                                       gates: DeckPaneGates) -> some View {
        // a pane hidden under its OWN overlay is not on screen: it registers no drag types and sets no mouse
        // cursor (the `deckVisible` note in libghostty.md, issue #225 class), and never takes first responder.
        let covered = session.paneOverlay(pane) != nil
        let slot: ReferenceWritableKeyPath<Session, (any TerminalSurface)?> =
            pane == .left ? \.surface : \.splitSurface
        ZStack {
            if deckHostsSurface(session: session, surface: pane.paneZoomSurface) {
                TerminalView(session: session, surfaceKeyPath: slot,
                             makeSurface: pane == .left ? makeSurface : makeSplitSurface,
                             isActive: gates.focusable && focused && !gates.overlaid && !covered,
                             deckVisible: gates.visible && !covered)
                    .overlay { paneDim(!focused, session: session) }
                    .modifier(PaneOverlayCover(covered: covered))
                    .id(pane == .left ? primarySurfaceID(session) : "\(session.id.uuidString)-split")
            } else {
                Color.clear
                    .id("\(session.id.uuidString)-\(pane == .left ? "primary" : "split")-placeholder")
            }
            paneOverlayPanel(session: session, pane: pane, focused: focused,
                             isActive: gates.focusable && !gates.overlaid && focused, deckVisible: gates.visible)
        }
    }

    /// The overlay — FULL, FLOATING, or a HUD — rendered IN-DECK as ONE ALWAYS-PRESENT sibling of each
    /// session's `sessionDetail` ZStack, its content gated INSIDE the GeometryReader so the child count never
    /// changes (the constant-shape rule). All three share this one surface host, so `session.overlay.resize`
    /// switching full<->% only re-flows the frame and never re-parents the NSView (which would blank its
    /// Metal drawable). `OverlayPanelStyle` supplies every per-occupant parameter, so the chain below is the
    /// same chain whichever one is up.
    @ViewBuilder private func overlayPanel(session: Session, isActive: Bool) -> some View {
        let style = OverlayPanelStyle.resolve(session)
        // a HUD is passive: it neither takes first responder nor absorbs the clicks around it, so the panel
        // stays inert as a whole and the session underneath keeps both.
        let live = isActive && style.interactive
        GeometryReader { geo in
            ZStack {
                if session.overlayActive, deckHostsSurface(session: session, surface: .overlay) {
                    // absorbs clicks AROUND a floating panel so they can't reach the hit-testable panes and
                    // steal the overlay's first responder (the full variant hides the panes anyway), and
                    // carries the backdrop mute: a floating panel leaves the session live behind it, so the
                    // same wash `paneDim` puts on an inactive split pane marks it inactive here. Full stays
                    // clear — its panes are already hidden, and a wash would tint the window backing.
                    (style.backdrop ? washColor(for: session).opacity(muteWashOpacity) : Color.clear)
                        .contentShape(Rectangle())
                    // `viewOnly` is the NSView-level half of the same passivity, and the layer that OWNS it:
                    // `mouseDown` makes the surface first responder, which would swallow every keystroke the
                    // user meant for the session, and the dashboard learned that `.allowsHitTesting(false)`
                    // alone is not what stops AppKit routing a click there. `deckVisible: live` is deliberate
                    // too — a passive panel registers no drag types and writes no mouse cursor, so a file drop
                    // keeps reaching the pane behind it.
                    TerminalView(session: session, surfaceKeyPath: \.overlaySurface,
                                 makeSurface: { makeOverlaySurface($0, nil) },
                                 isActive: live, deckVisible: live, viewOnly: !style.interactive)
                        .frame(width: geo.size.width * style.widthFraction,
                               height: geo.size.height * style.heightFraction)
                        // floating = opaque backing + frame + shadow so it reads as a distinct window over the
                        // still-visible session; full = translucent and chromeless (libghostty draws only the
                        // terminal, so the window backing shows through); a HUD keeps the backing but drops
                        // the shadow for a stronger border, so it reads as part of the terminal. The CHAIN is
                        // constant across all three, only the parameters change.
                        .background(style.framed ? terminalColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: style.cornerRadius)
                                .strokeBorder(Color.white.opacity(style.borderOpacity), lineWidth: 1)
                        )
                        .shadow(radius: style.shadowRadius)
                        .offset(x: style.horizontalOffset(paneWidth: geo.size.width),
                                y: style.verticalOffset(paneHeight: geo.size.height))
                        // a replacement (HUD→HUD, HUD→program) keeps `overlayActive` true across the swap, so
                        // without the generation SwiftUI reuses the host: `makeNSView` never re-runs and
                        // `updateNSView` hits a torn-down view with `overlaySurface` nil.
                        .id("\(session.id.uuidString)-overlay-\(session.overlaySlotGeneration)")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // with no overlay up this is an empty full-frame GeometryReader; keep it inert so it never
        // intercepts clicks meant for the pane(s).
        .allowsHitTesting(live && session.overlayActive && deckHostsSurface(session: session, surface: .overlay))
    }

    /// ONE split pane's overlay, always FULL-PANE (no size percent, no framed chrome — a floating variant
    /// exists only at session scope). An ALWAYS-PRESENT sibling INSIDE that pane's ZStack, content gated in
    /// the GeometryReader, under the constant-shape rule `sessionDetail` states.
    ///
    /// `isActive` is the FOCUSED-pane gate (auto-focus, first responder), `deckVisible` the on-screen one
    /// (drag types, mouse cursor, clicks): an overlay on the unfocused pane stays visible and clickable —
    /// clicking it moves focus through the surface's own `onFocusChange` — without grabbing focus on open.
    /// It therefore carries `focused`'s `paneDim` too: the overlay replaces the pane the wash would have
    /// marked, so without it the unfocused side of a split reads as live.
    @ViewBuilder private func paneOverlayPanel(session: Session, pane: OverlayPane, focused: Bool, isActive: Bool,
                                               deckVisible: Bool) -> some View {
        let active = session.paneOverlay(pane) != nil
            && deckHostsSurface(session: session, surface: pane.zoomSurface)
        GeometryReader { geo in
            ZStack {
                if active {
                    // chromeless and translucent like the full session overlay: libghostty draws only the
                    // terminal, and the pane below is hidden so the window backing shows through.
                    TerminalView(session: session, surfaceKeyPath: pane.surfaceSlot,
                                 makeSurface: { makeOverlaySurface($0, pane) },
                                 isActive: isActive, deckVisible: deckVisible)
                        .overlay { paneDim(!focused, session: session, color: overlayWashColor(session, pane: pane)) }
                        .id("\(session.id.uuidString)-overlay-\(pane.rawValue)")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // inert while empty, like `overlayPanel`.
        .allowsHitTesting(deckVisible && active)
    }

    /// Mutes the inactive split pane — or the overlay covering it — by fading its TEXT without darkening the
    /// background: a translucent wash of the terminal background, so background pixels blend bg→bg and text
    /// pixels text→bg. Strength 0 renders nothing; clicks pass through, so it stays focusable. Suppressed
    /// while a floating panel washes the whole backdrop, which already covers this pane — the two would
    /// stack to a stronger mute here than on the pane beside it. `color` overrides the blend target for a
    /// surface that does not render the session's background; the pane itself takes the default.
    @ViewBuilder private func paneDim(_ dimmed: Bool, session: Session, color: Color? = nil) -> some View {
        if dimmed, muteWashOpacity > 0, !backdropWashActive(session: session) {
            (color ?? washColor(for: session)).opacity(muteWashOpacity).allowsHitTesting(false)
        }
    }

    /// The blend target for a PANE OVERLAY's wash: its own `--background-color` when it set one, else the
    /// theme. An overlay surface is sessionless and never inherits the session's background — only the
    /// scratch does, through `watermarkSession` — so `washColor(for:)` would blend bg→OTHER-bg and shift
    /// the background instead of fading the text. Gated on the renderer's own hex predicate, so the wash
    /// tracks exactly what `applyOverlayBackgroundColor` painted rather than a value it rejected.
    private func overlayWashColor(_ session: Session, pane: OverlayPane) -> Color {
        guard let hex = session.paneOverlay(pane)?.backgroundColor, WatermarkConfig.isValidColorHex(hex),
              let nsColor = NSColor(agtermHex: hex) else { return terminalColor }
        return Color(nsColor: nsColor)
    }

    /// Whether a floating panel is washing the whole backdrop of this session's detail pane. Reads the same
    /// `backdrop` flag `overlayPanel` paints from, so the wash and its `paneDim` suppression cannot disagree
    /// about a HUD, which paints none.
    private func backdropWashActive(session: Session) -> Bool {
        quickTerminal.isVisible || OverlayPanelStyle.resolve(session).backdrop
    }
}

/// The three deck-wide gates every pane of one session's entry renders under, computed once per entry:
/// `focusable` (may take first responder at all), `overlaid` (a session-wide cover is up), and `visible`
/// (this entry is the on-screen one). `deckPane` ANDs its own pane terms into them.
struct DeckPaneGates {
    let focusable: Bool
    let overlaid: Bool
    let visible: Bool

    /// Whether a session-wide cover is up: a caller's PROGRAM in the overlay slot, or the scratch. A HUD is
    /// exempt — it is a message, not a program, and the session under it must keep first responder and stay
    /// clickable, which is the whole difference between the two occupants of that slot.
    @MainActor static func coverActive(_ session: Session) -> Bool {
        session.programOverlayActive || session.scratchActive
    }
}

/// Every per-occupant parameter `overlayPanel` renders one session's overlay slot with — geometry, chrome,
/// backdrop, and interactivity — resolved from whether the slot holds a HUD, a floating program overlay, or
/// a full one. A value type so the deck flips PARAMETERS only and the modifier chain stays constant, per the
/// rule `sessionDetail` states.
struct OverlayPanelStyle: Equatable {
    /// pane fraction the panel occupies horizontally; 1 for a full overlay.
    let widthFraction: CGFloat
    /// pane fraction the panel occupies vertically. A program overlay takes the same value on both axes —
    /// it is a terminal, and a square-ish region is what it wants — while a HUD measures this one from its
    /// message alone, so a two-line panel is two lines tall however wide it had to be.
    let heightFraction: CGFloat
    /// opaque backing: both framed variants, never the chromeless full overlay.
    let framed: Bool
    let cornerRadius: CGFloat
    let borderOpacity: Double
    let shadowRadius: CGFloat
    /// whether the margin around the panel washes the session behind it and counts as a backdrop mute.
    let backdrop: Bool
    /// whether the panel takes clicks and first responder at all.
    let interactive: Bool
    /// which of the pane's nine anchors the panel sits on, read on both axes; program overlays are always
    /// centered.
    let position: HudPosition

    /// The floating program overlay's chrome: a window hovering over the session, so a wide radius and a
    /// shadow carry the separation and the border only edges it.
    private static let floatingCornerRadius: CGFloat = 12
    private static let floatingBorderOpacity = 0.18
    private static let floatingShadowRadius: CGFloat = 24

    /// A HUD keeps the opaque backing but drops the shadow for a stronger border and a tighter radius:
    /// neither a shadow nor a backdrop wash separates it from the text behind, so the border does that work
    /// alone and the panel reads as part of the terminal rather than a window hovering over it.
    private static let hudCornerRadius: CGFloat = 8
    private static let hudBorderOpacity = 0.30

    @MainActor static func resolve(_ session: Session) -> OverlayPanelStyle {
        let fraction = session.overlaySizePercent.map { CGFloat($0) / 100 } ?? 1
        guard session.hudActive else {
            // the full overlay is chromeless: no radius, no border, no shadow.
            let floating = session.overlaySizePercent != nil
            return OverlayPanelStyle(widthFraction: fraction, heightFraction: fraction, framed: floating,
                                     cornerRadius: floating ? floatingCornerRadius : 0,
                                     borderOpacity: floating ? floatingBorderOpacity : 0,
                                     shadowRadius: floating ? floatingShadowRadius : 0,
                                     backdrop: floating, interactive: true, position: .center)
        }
        // a HUD with no measured height has not been through `openHud` yet; falling back to the width would
        // put the square back for exactly the frame that would be seen first.
        let height = session.hudHeightPercent.map { CGFloat($0) / 100 }
            ?? CGFloat(HudLayout.minSizePercent) / 100
        return OverlayPanelStyle(widthFraction: fraction, heightFraction: height, framed: true,
                                 cornerRadius: hudCornerRadius, borderOpacity: hudBorderOpacity,
                                 shadowRadius: 0, backdrop: false, interactive: false,
                                 position: session.hudSpec?.position ?? .center)
    }

    /// The panel's offset from the pane's center, positive downward. A `top`/`bottom` anchor holds
    /// `HudPosition.edgeMarginPercent` of the pane clear at that edge. It is the HEIGHT that decides how far
    /// the panel can travel, and every height a HUD can reach fits that margin — `HudLayout.heightPercent`
    /// caps it at `maxSizePercent`, where two margins exactly fill the rest — so `max(0,` is defensive only,
    /// for a panel no supported path can produce. A message-sized panel leaves most of the pane free, so the
    /// edge anchors reach the edge instead of barely clearing center.
    func verticalOffset(paneHeight: CGFloat) -> CGFloat {
        Self.offset(along: paneHeight, fraction: heightFraction, band: position.verticalBand)
    }

    /// The same math across the pane's WIDTH, positive rightward, off the anchor's column. The invariant that
    /// makes the margin always fit holds identically here: `HudLayout.clampSizePercent` bounds every width,
    /// the caller's `--size-percent` included, at the same `maxSizePercent` two margins fill the rest of.
    func horizontalOffset(paneWidth: CGFloat) -> CGFloat {
        Self.offset(along: paneWidth, fraction: widthFraction, band: position.horizontalBand)
    }

    /// One axis' travel: half the free room left after the panel and its edge margin, signed by the band.
    private static func offset(along extent: CGFloat, fraction: CGFloat,
                               band: HudPosition.Band) -> CGFloat {
        let margin = CGFloat(HudPosition.edgeMarginPercent) / 100
        let free = max(0, extent * ((1 - fraction) / 2 - margin))
        switch band {
        case .middle: return 0
        case .leading: return -free
        case .trailing: return free
        }
    }
}

/// Hides ONE pane beneath its own full-pane overlay: that overlay is chromeless, so under window
/// translucency the pane below would show through it, and a hit-testable pane under it would steal the
/// overlay's first responder. Scoped to the covered pane alone — the sibling stays visible and interactive.
/// Applied INSIDE the arranged subview like `paneDim`, never on a wrapper.
private struct PaneOverlayCover: ViewModifier {
    let covered: Bool

    func body(content: Content) -> some View {
        content
            .opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
    }
}
