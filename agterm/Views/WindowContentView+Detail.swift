import agtermCore
import AppKit
import SwiftUI

/// `WindowContentView`'s detail deck: every session's terminal content — panes, split, scratch, and both
/// overlay kinds — plus the inactive-pane mute. Split out of the main file for the source-length limit.
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

    /// One session's terminal content: the primary pane, a side-by-side split (`HSplitView`), or the
    /// maximized hidden-split pane, plus any overlay. `isActive` gates which pane auto-grabs focus — the
    /// visible deck entry, and within a split the focused pane.
    ///
    /// While zoom hosts one of these surfaces the entry stays MOUNTED at the SAME shape, only the zoom-owned
    /// slot swapping to a placeholder (an NSView lives in one host at a time), so a control-opened
    /// split/scratch/overlay still runs behind it; swapping the entry out would re-host the NSSplitView
    /// (the titlebar-overrun rule) and orphan those surfaces until zoom exits.
    @ViewBuilder private func sessionDetail(_ session: Session, isActive: Bool) -> some View {
        // a FULL overlay (no size) hides the panes and draws translucent; a FLOATING one leaves them VISIBLE
        // under a smaller opaque framed panel. Either way the pane(s) stay non-interactive while one is up.
        let fullOverlay = session.fullOverlayActive
        // while zoomed OR the dashboard is open (mutually exclusive) the deck stays mounted only to realize
        // surfaces: no focus, no drag targets, no focusable controls behind the full-window modal layer.
        let deckInteractive = terminalZoom.target == nil && !dashboard.isOpen
        // the scratch is full-coverage too, so `hideForOverlay` hides the panes like a FULL overlay and
        // `overlaid` (any overlay OR scratch) gates their `isActive`. It stays false for a FLOATING overlay:
        // this subtree's shape and hit-testing must not change when one opens (NSSplitView overrun).
        let hideForOverlay = fullOverlay || session.scratchActive
        let overlaid = session.overlayActive || session.scratchActive
        // on-screen = selected, not hidden by a full overlay/scratch, not covered by the quick terminal.
        // Shared by BOTH split panes (unlike focus-gated `isActive`), it gates drag-type (un)registration and
        // mouse-cursor tracking (the `deckVisible` note in libghostty.md). Without the quick-terminal term a
        // covered pane races it for the cursor and fans mouse-motion into the covered TUI (issue #225).
        let visible = deckInteractive && isActive && !hideForOverlay && !quickTerminal.isVisible
        // focus gate: a visible quick terminal OWNS first responder, so no deck surface may be `isActive`
        // behind it — `updateNSView` would grab focus and send keystrokes to a covered session. Every
        // automatic reselection (`reselectIfSelectionHidden`, auto-follow) reaches this, not just a click.
        let focusable = deckInteractive && isActive && !quickTerminal.isVisible
        // a pane overlay may claim first responder only where its pane could: the visible deck entry with no
        // session-wide cover above it, AND only for the FOCUSED pane — one opening on the other pane must not
        // pull focus away from the live one. Each site ANDs its pane's focus term in.
        let paneOverlayFocus = focusable && !overlaid
        // a pane hidden under its OWN overlay is not on screen: it registers no drag types and sets no mouse
        // cursor (the `deckVisible` note in libghostty.md, issue #225 class), and never takes first responder.
        let leftCovered = session.leftOverlay != nil
        let rightCovered = session.rightOverlay != nil
        ZStack {
            // the pane(s) stay MOUNTED while an overlay is up so their shells stay alive; a FULL overlay
            // hides them (opacity 0) so its translucency reveals the window backing, not the session.
            Group {
                if session.isSplit {
                    HSplitView {
                        // a STABLE ZStack wrapper whose CONTENT swaps between the live TerminalView and the
                        // zoom placeholder: swapping the arranged subview itself makes NSSplitView re-layout
                        // and normalize the divider on every zoom toggle, with no stored ratio to restore.
                        ZStack {
                            if deckHostsSurface(session: session, surface: .primary) {
                                TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                                             isActive: focusable && !session.splitFocused && !overlaid && !leftCovered,
                                             deckVisible: visible && !leftCovered)
                                    .overlay { paneDim(session.splitFocused, session: session) }
                                    .modifier(PaneOverlayCover(covered: leftCovered))
                                    .id(primarySurfaceID(session))
                            } else {
                                Color.clear
                                    .id("\(session.id.uuidString)-primary-placeholder")
                            }
                            paneOverlayPanel(session: session, pane: .left,
                                             isActive: paneOverlayFocus && !session.splitFocused, deckVisible: visible)
                        }
                        // persists/restores the divider ratio and clips the NSSplitView out of the titlebar
                        // strip; a background on the stable wrapper (not a third pane, not inside the swapped
                        // content), so ONE probe survives zoom and suspend/resume flips in place.
                        .background { SplitRatioAccessor(session: session, titlebarHeight: titlebarHeight, suspended: !deckInteractive, onPersist: { store.save() }) }
                        ZStack {
                            if deckHostsSurface(session: session, surface: .split) {
                                TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                                             isActive: focusable && session.splitFocused && !overlaid && !rightCovered,
                                             deckVisible: visible && !rightCovered)
                                    .overlay { paneDim(!session.splitFocused, session: session) }
                                    .modifier(PaneOverlayCover(covered: rightCovered))
                                    .id("\(session.id.uuidString)-split")
                            } else {
                                Color.clear
                                    .id("\(session.id.uuidString)-split-placeholder")
                            }
                            paneOverlayPanel(session: session, pane: .right,
                                             isActive: paneOverlayFocus && session.splitFocused, deckVisible: visible)
                        }
                    }
                    // per-session identity: without it SwiftUI reuses one NSSplitView across session
                    // switches and the divider (and arranged subviews) leak between sessions.
                    .id("\(session.id.uuidString)-hsplit")
                } else if session.splitFocused, session.splitSurface != nil {
                    // split hidden while the right pane had focus: show that pane maximized. The ZStack is
                    // this site's home for the always-present pane-overlay sibling, matching the split sites.
                    ZStack {
                        if deckHostsSurface(session: session, surface: .split) {
                            TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                                         isActive: focusable && !overlaid && !rightCovered,
                                         deckVisible: visible && !rightCovered)
                                .modifier(PaneOverlayCover(covered: rightCovered))
                                .id("\(session.id.uuidString)-split")
                        } else {
                            Color.clear
                                .id("\(session.id.uuidString)-split-placeholder")
                        }
                        paneOverlayPanel(session: session, pane: .right, isActive: paneOverlayFocus, deckVisible: visible)
                    }
                } else {
                    ZStack {
                        if deckHostsSurface(session: session, surface: .primary) {
                            TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                                         isActive: focusable && !overlaid && !leftCovered,
                                         deckVisible: visible && !leftCovered)
                                .modifier(PaneOverlayCover(covered: leftCovered))
                                .id(primarySurfaceID(session))
                        } else {
                            Color.clear
                                .id("\(session.id.uuidString)-primary-placeholder")
                        }
                        paneOverlayPanel(session: session, pane: .left, isActive: paneOverlayFocus, deckVisible: visible)
                    }
                }
            }
            .opacity(hideForOverlay ? 0 : 1)
            // gate on `hideForOverlay`, NOT `session.overlayActive`: this modifier must not change when a
            // floating overlay opens, or the NSSplitView re-lays-out and overruns into the titlebar (same
            // perturbation class as adding a sibling). Floating leaves the panes hit-testable;
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
                             isActive: focusable && !session.overlayActive,
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
        // on overlay close refocus the topmost remaining surface via `topmostSurface` — never a pane hidden
        // under the scratch. One makeFirstResponder loses the race with the overlay's teardown/re-host, so
        // drive the bounded retry the split-collapse survivor uses; only the visible session reclaims focus.
        .onChange(of: session.overlayActive) { _, isOpen in
            if !isOpen, deckInteractive, isActive, !quickTerminal.isVisible {
                (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
            }
        }
        // show AND hide both need the bounded focus retry: the surface is kept alive across hides, so a
        // re-show remounts it and `autoFocus`'s one-shot latch won't re-fire (same remount race as the
        // split-collapse survivor). `topmostSurface` routes either way — the scratch (or a still-open overlay
        // above it) on show, the overlay-if-up else the pane on hide.
        .onChange(of: session.scratchActive) { _, _ in
            // the quick terminal owns focus while it covers the window; its own hide re-grabs the scratch.
            guard deckInteractive, isActive, !quickTerminal.isVisible else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
        // a closing pane overlay un-hides its pane the same way, and its teardown loses the same race, so
        // drive the same bounded retry — `topmostSurface` picks the remaining cover or the focused pane.
        .onChange(of: session.openPaneOverlays) { before, after in
            guard after.count < before.count, deckInteractive, isActive, !quickTerminal.isVisible else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
    }

    /// The overlay — FULL or FLOATING — rendered IN-DECK as ONE ALWAYS-PRESENT sibling of each session's
    /// `sessionDetail` ZStack, its content gated INSIDE the GeometryReader so the child count never changes
    /// (constant shape = no NSSplitView re-host = no titlebar overrun). Both variants share this one surface
    /// host, so `session.overlay.resize` switching full<->% only re-flows the frame and never re-parents the
    /// NSView (which would blank its Metal drawable).
    @ViewBuilder private func overlayPanel(session: Session, isActive: Bool) -> some View {
        GeometryReader { geo in
            ZStack {
                if session.overlayActive, deckHostsSurface(session: session, surface: .overlay) {
                    let floating = session.overlaySizePercent != nil
                    let fraction = session.overlaySizePercent.map { CGFloat($0) / 100 } ?? 1
                    // absorbs clicks AROUND a floating panel so they can't reach the hit-testable panes and
                    // steal the overlay's first responder (the full variant hides the panes anyway), and
                    // carries the backdrop mute: a floating panel leaves the session live behind it, so the
                    // same wash `paneDim` puts on an inactive split pane marks it inactive here. Full stays
                    // clear — its panes are already hidden, and a wash would tint the window backing.
                    (floating ? washColor(for: session).opacity(muteWashOpacity) : Color.clear)
                        .contentShape(Rectangle())
                    TerminalView(session: session, surfaceKeyPath: \.overlaySurface,
                                 makeSurface: { makeOverlaySurface($0, nil) },
                                 isActive: isActive, deckVisible: isActive)
                        .frame(width: geo.size.width * fraction, height: geo.size.height * fraction)
                        // floating = opaque backing + frame + shadow so it reads as a distinct window over the
                        // still-visible session; full = translucent and chromeless (libghostty draws only the
                        // terminal, so the window backing shows through). The CHAIN is constant across both,
                        // only the parameters going inert for full.
                        .background(floating ? terminalColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: floating ? 12 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: floating ? 12 : 0)
                                .strokeBorder(floating ? Color.white.opacity(0.18) : Color.clear, lineWidth: 1)
                        )
                        .shadow(radius: floating ? 24 : 0)
                        .id("\(session.id.uuidString)-overlay")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // with no overlay up this is an empty full-frame GeometryReader; keep it inert so it never
        // intercepts clicks meant for the pane(s).
        .allowsHitTesting(isActive && session.overlayActive && deckHostsSurface(session: session, surface: .overlay))
    }

    /// ONE split pane's overlay, always FULL-PANE (no size percent, no framed chrome — a floating variant
    /// exists only at session scope). Rendered as an ALWAYS-PRESENT sibling INSIDE that pane's ZStack, with
    /// its content gated inside the GeometryReader so the ZStack's child count never changes. Everything
    /// stays within the NSSplitView's arranged subview: a modifier WRAPPING the split re-lays it out and
    /// overruns the titlebar even on a value change (see the boundary note in `sessionDetail`).
    ///
    /// `isActive` is the FOCUSED-pane gate (auto-focus, first responder), `deckVisible` the on-screen one
    /// (drag types, mouse cursor, clicks): an overlay on the unfocused pane stays visible and clickable —
    /// clicking it moves focus through the surface's own `onFocusChange` — without grabbing focus on open.
    @ViewBuilder private func paneOverlayPanel(session: Session, pane: OverlayPane, isActive: Bool,
                                               deckVisible: Bool) -> some View {
        let active = session.paneOverlay(pane) != nil
        let keyPath: ReferenceWritableKeyPath<Session, (any TerminalSurface)?> =
            pane == .left ? \.leftOverlaySurface : \.rightOverlaySurface
        GeometryReader { geo in
            ZStack {
                if active {
                    // chromeless and translucent like the full session overlay: libghostty draws only the
                    // terminal, and the pane below is hidden so the window backing shows through.
                    TerminalView(session: session, surfaceKeyPath: keyPath,
                                 makeSurface: { makeOverlaySurface($0, pane) },
                                 isActive: isActive, deckVisible: deckVisible)
                        .id("\(session.id.uuidString)-overlay-\(pane.rawValue)")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // with no overlay up this is an empty full-frame GeometryReader; keep it inert so it never
        // intercepts clicks meant for the pane it sits on.
        .allowsHitTesting(deckVisible && active)
    }

    /// Mutes the inactive split pane's TEXT without darkening the background: a translucent wash of the
    /// terminal background, so background pixels blend bg→bg and text pixels text→bg. Strength 0 renders
    /// nothing; clicks pass through, so it stays focusable. Suppressed while a floating panel washes the
    /// whole backdrop, which already covers this pane — the two would stack to a stronger mute here than on
    /// the pane beside it.
    @ViewBuilder private func paneDim(_ dimmed: Bool, session: Session) -> some View {
        if dimmed, muteWashOpacity > 0, !backdropWashActive(session: session) {
            washColor(for: session).opacity(muteWashOpacity).allowsHitTesting(false)
        }
    }

    /// Whether a floating panel is washing the whole backdrop of this session's detail pane.
    private func backdropWashActive(session: Session) -> Bool {
        quickTerminal.isVisible || (session.overlayActive && session.overlaySizePercent != nil)
    }
}

/// Hides ONE pane beneath its own full-pane overlay: that overlay is chromeless, so under window
/// translucency the pane below would show through it, and a hit-testable pane under it would steal the
/// overlay's first responder. Scoped to the covered pane alone — the sibling stays visible and interactive.
///
/// Applied INSIDE the arranged subview, never on a wrapper: the chain is constant and only its values
/// change, matching `paneDim`, so the NSSplitView is never perturbed.
private struct PaneOverlayCover: ViewModifier {
    let covered: Bool

    func body(content: Content) -> some View {
        content
            .opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
    }
}
