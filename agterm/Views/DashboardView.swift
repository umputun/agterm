import agtermCore
import AppKit
import SwiftUI

/// The dashboard grid overlay: a per-window, view-only modal hosting up to `DashboardLayout.maxCells` live
/// pane cells in a `ceil(sqrt(n))`-wide grid. The cell unit is a session+pane (a `DashboardMember`), so a
/// split session shows as TWO cells (its primary + split panes). No pane SURFACE takes input — each is
/// `.allowsHitTesting(false)` and never becomes first responder, so its cursor draws hollow; an AppKit
/// key-catcher owns first responder while open and swallows every key, walking a highlight between cells
/// (Enter enters the highlighted session AND focuses that exact pane, Esc closes). A transparent hit target
/// over each cell flashes the active frame before entering, since an instant jump with no flash is confusing.
///
/// Purely presentational and closure-driven: `WindowContentView` mounts it in `windowOverlayLayer` while
/// `controller.isOpen`, generalizes its deck to yield each member's surface into a cell, and supplies the
/// session lookup, surface factories, and enter/close side effects.
struct DashboardView: View {
    let controller: DashboardController
    /// Resolves a member's session UUID to its live `Session` (the window's `AppStore`), mirroring `SessionSwitcherOverlay`.
    let store: AppStore
    /// The primary surface factory — used for a `.primary` pane cell (`session.surface`).
    let makeSurface: (Session) -> GhosttySurfaceView
    /// The split surface factory — used for a `.split` pane cell (`session.splitSurface`).
    let makeSplitSurface: (Session) -> GhosttySurfaceView
    /// The themed chrome foreground (the terminal theme's foreground), used for the highlight ring so it
    /// tracks the active terminal theme rather than the OS accent.
    let highlightColor: Color
    /// The themed terminal background — the OPAQUE backing for BOTH the whole grid and each cell, so a
    /// translucent terminal surface (window background-opacity < 1) still reads as a solid grid, and the
    /// regular layer beneath the overlay (sidebar, add-buttons, deck) doesn't bleed through the margins.
    let captionBackground: Color
    /// The IDLE caption pill's FILL — the theme's muted selection-background highlight (the same color the
    /// selected sidebar row draws), so an idle chip is a themed, muted accent rather than the loud foreground.
    /// A non-idle session overrides this with its agent-status color (see `DashboardCaptionPill`).
    let pillColor: Color
    /// The IDLE caption pill's TEXT — the theme's selection-foreground, readable over `pillColor`. A non-idle
    /// pill uses a luminance-contrasting black/white instead.
    let pillTextColor: Color
    /// False while a control picker is above the dashboard, so its key catcher cannot steal focus.
    let focusAllowed: Bool
    /// A single mouse click on a cell: the wiring flashes the active frame on it, then enters it after a brief
    /// delay, so the click is visibly acknowledged before the grid closes.
    let onClick: (DashboardMember) -> Void
    /// Enter on the keyboard highlight jumps into that session+pane immediately (the wiring selects + closes +
    /// focuses). No click-flash delay on this path — the keyboard highlight is already visible.
    let onSelect: (DashboardMember) -> Void
    /// Esc, or the wiring's close path, dismisses the dashboard.
    let onClose: () -> Void

    private static let cellCornerRadius: CGFloat = 6
    /// inter-cell (and outer) gap. Kept a few points WIDER than `captionBottomOffset` so the caption chip,
    /// which overhangs the cell's bottom edge by that offset, clears the cell below instead of touching it.
    private static let gridSpacing: CGFloat = 12
    private static let highlightLineWidth: CGFloat = 1.5
    /// how far the caption chip is nudged below the cell's bottom edge so it straddles the frame line
    /// instead of covering the terminal's last row.
    private static let captionBottomOffset: CGFloat = 8
    /// caption text opacity on an UNSELECTED (non-highlighted) cell — the label font reads muted there so
    /// the highlighted cell's name stands out; the highlighted cell keeps full-opacity text.
    private static let unselectedCaptionTextOpacity: Double = 0.55

    var body: some View {
        let members = controller.members
        let (cols, rows) = DashboardLayout.grid(count: members.count)
        VStack(spacing: Self.gridSpacing) {
            ForEach(Array(0..<rows), id: \.self) { row in
                HStack(spacing: Self.gridSpacing) {
                    ForEach(Array(0..<cols), id: \.self) { col in
                        cellSlot(index: row * cols + col, members: members)
                    }
                }
            }
        }
        .padding(Self.gridSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // an OPAQUE themed backdrop so the grid reads as a SOLID modal instead of letting the layer beneath
        // (sidebar, add-buttons, deck) bleed through the margins — deliberately dropping window
        // translucency/blur here. Not a black scrim: over the translucent backing that read as near-black.
        .background(captionBackground)
        // restores the hairline the opaque backdrop would cover — the SAME 1px themed line `detailColumn`
        // draws under the title bar (`highlightColor` is the chrome foreground).
        .overlay(alignment: .top) { Rectangle().fill(highlightColor.opacity(0.1)).frame(height: 1) }
        // the key-catcher sits behind the cells so it never intercepts their click hit targets; it owns
        // first responder and swallows every key while open.
        .background {
            DashboardKeyCatcher(
                focusRevision: controller.focusRevision,
                focusAllowed: focusAllowed,
                onKey: handleKey
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard")
        // no implicit animation on the grid geometry / highlight — a modal reparent overlay applies its
        // @Observable-driven changes instantly, never as an animated transition.
        .transaction { $0.animation = nil }
    }

    /// One grid position: the member pane cell when `index` is in range and its session/pane still resolves,
    /// else a clear filler that keeps every real cell the same size as the full rows above it (the ragged
    /// last-row case, and the stale-member guard for a session/pane that vanished mid-frame).
    @ViewBuilder
    private func cellSlot(index: Int, members: [DashboardMember]) -> some View {
        if index < members.count, let session = store.session(withID: members[index].session) {
            cell(for: members[index], session: session)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cell(for member: DashboardMember, session: Session) -> some View {
        let isHighlighted = controller.highlighted == member
        return ZStack {
            captionBackground
            memberTerminal(for: member, session: session)
                .allowsHitTesting(false)
            // transparent hit target above the terminal: a lone count:1 tap has no double-click interval to
            // wait out, so the click registers immediately — a count:2 + count:1 pair delayed every click by
            // the system timeout. Carries the per-cell a11y id (the Metal-backed surface is not in the tree).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onClick(member) }
                .accessibilityElement()
                .accessibilityIdentifier("dashboard-cell")
            if isHighlighted {
                // a zero-content marker the e2e queries to locate the highlighted cell; it fills the cell,
                // so its frame identifies which cell holds the highlight.
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityIdentifier("dashboard-highlighted")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Self.cellCornerRadius))
        .overlay {
            // a thin ring tracking the terminal theme, not the OS accent, in both light and dark: the chrome
            // foreground on the highlighted cell, the same color at low opacity on the rest.
            RoundedRectangle(cornerRadius: Self.cellCornerRadius)
                .strokeBorder(isHighlighted ? highlightColor : highlightColor.opacity(0.12),
                              lineWidth: isHighlighted ? Self.highlightLineWidth : 1)
        }
        // the caption rides the cell's BOTTOM frame line: an overlay OUTSIDE the clip (so its lower half
        // survives), bottom-aligned and nudged down, so the chip straddles the stroke instead of covering
        // the terminal's last row. Layered AFTER the ring so the frame line never crosses the name.
        .overlay(alignment: .bottom) {
            caption(for: member, session: session, isHighlighted: isHighlighted)
                .offset(y: Self.captionBottomOffset)
        }
    }

    /// Hosts the member's OWN pane surface as a view-only `TerminalView`: `.primary` → `\.surface` via
    /// `makeSurface`, `.split` → `\.splitSurface` via `makeSplitSurface`. The `.id` carries the hosted slot
    /// (`-dashboard-primary`/`-dashboard-split`), so a cell keyed to one pane never reuses the other's
    /// representable, plus the surface's per-instance `surfaceToken` so a REPLACEMENT re-mounts the cell.
    /// `isActive`/`deckVisible`/`reportsFocusChange` off and `viewOnly` on: the cell auto-focuses nothing,
    /// is not a drop target, refuses first responder, and never mutates session focus state.
    @ViewBuilder
    private func memberTerminal(for member: DashboardMember, session: Session) -> some View {
        if member.surface == .split {
            TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                         isActive: false, deckVisible: false, reportsFocusChange: false, viewOnly: true)
                .id("\(session.id.uuidString)-dashboard-split-\(surfaceToken(for: member, session: session))")
        } else {
            TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                         isActive: false, deckVisible: false, reportsFocusChange: false, viewOnly: true)
                .id("\(session.id.uuidString)-dashboard-primary-\(surfaceToken(for: member, session: session))")
        }
    }

    /// A per-instance identity token for the member's currently-resolved slot surface (`.split` →
    /// `session.splitSurface`, else `session.surface`), folded into the cell `.id`. When a shown session's
    /// PRIMARY shell exits, `AppStore.closePrimaryPane` PROMOTES the split survivor into `session.surface`
    /// (a DIFFERENT instance) and nils `splitSurface`, and reconcile drops the `.split` cell but keeps
    /// `.primary`; `TerminalView.updateNSView` never re-resolves `session[keyPath:]`, so without the surface
    /// identity in the id SwiftUI keeps hosting the torn-down old primary (a blank cell) while the live
    /// survivor stays unhosted. `ObjectIdentifier` changes the id ONLY on a genuine swap, forcing a re-mount
    /// → `makeNSView` re-resolves the slot → hosts the survivor; it is STABLE across ordinary re-renders, so
    /// no spurious re-host invalidates the Metal drawable and flickers. `session.surface`/`splitSurface` are
    /// `@ObservationIgnored`, so the swap alone does not re-render — the reconcile-driven `controller.members`
    /// change re-renders the grid and re-reads the new slot surface. A nil slot keeps a stable `"none"` suffix.
    private func surfaceToken(for member: DashboardMember, session: Session) -> String {
        let surface = member.surface == .split ? session.splitSurface : session.surface
        guard let surface else { return "none" }
        return "\(ObjectIdentifier(surface as AnyObject))"
    }

    /// A small name chip riding the cell's bottom-RIGHT frame line, with a pane marker (`◀` primary / `▶`
    /// split) appended for a split session's two cells so they read as its left/right panes. The fill DOUBLES
    /// as the agent-status light: a non-idle `agentIndicator` colors it (pulsing while `--blink` is set), an
    /// idle session keeps the muted theme-selection pill. `DashboardCaptionPill` owns fill, contrast and
    /// blink; this only right-aligns it via the leading `Spacer` (which also fixes the width, so a long name
    /// middle-truncates instead of overflowing) and makes it non-interactive so it never blocks the hit target.
    private func caption(for member: DashboardMember, session: Session, isHighlighted: Bool) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            DashboardCaptionPill(text: session.displayName + paneIndicator(for: member, session: session),
                                 indicator: session.agentIndicator, isHighlighted: isHighlighted,
                                 idleFill: pillColor, idleText: pillTextColor,
                                 unselectedTextOpacity: Self.unselectedCaptionTextOpacity)
        }
        .padding(.horizontal, 6)
        .allowsHitTesting(false)
    }

    /// The caption's pane marker: `▶` for a split (right) pane cell, `◀` for the primary (left) cell of a
    /// SPLIT session (both cells present, so they need distinguishing), nothing for a non-split session.
    private func paneIndicator(for member: DashboardMember, session: Session) -> String {
        if member.surface == .split { return " ▶" }
        return session.hasSplit ? " ◀" : ""
    }

    private func handleKey(_ key: DashboardKey) {
        switch key {
        case let .move(direction):
            controller.move(direction)
        case .select:
            if let highlighted = controller.highlighted { onSelect(highlighted) }
        case .close:
            onClose()
        }
    }
}

/// The dashboard cell's name chip, which also carries the session's agent status. IDLE draws the muted
/// theme-selection pill — `idleText` (selection-foreground) over an `idleFill` (selection-background)
/// capsule, the label muted (`unselectedTextOpacity`) on an unselected cell so the highlighted cell's name
/// stands out. NON-IDLE fills the capsule with the agent-status color
/// (`GhosttyApp.statusColor(for:override:)`, honoring a `session.status --color` override) and draws the
/// name in luminance-contrasting black/white (`GhosttyApp.contrastingText`), readable over ANY status color
/// including an arbitrary override. Blinking keeps the capsule fully OPAQUE and pulses a color WASH on top
/// (brighten a light fill / darken a dark one), NOT an opacity fade — fading let the highlighted cell's
/// bright frame ring bleed through the chip and read as broken.
private struct DashboardCaptionPill: View {
    let text: String
    let indicator: AgentIndicator
    let isHighlighted: Bool
    let idleFill: Color
    let idleText: Color
    let unselectedTextOpacity: Double

    /// peak opacity of the pulsing color wash. Deep on purpose: the wash rides a large opaque capsule, so a
    /// shallow value reads as faint dimming rather than a blink (the small sidebar glyph needs less).
    private static let washPeakOpacity: Double = 0.75
    private static let pulseDuration: Double = 0.45

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsed = false

    private var isStatus: Bool { indicator.status != .idle }
    /// the resolved status tint (per-call `--color` override else the Settings color); computed once so the
    /// fill and its contrasting text agree.
    private var statusColor: NSColor { GhosttyApp.shared.statusColor(for: indicator.status, override: indicator.color) }
    /// black/white by the fill's luminance so the name is readable over any status color.
    private var textNSColor: NSColor { GhosttyApp.contrastingText(for: statusColor) }
    private var fill: Color { isStatus ? Color(nsColor: statusColor) : idleFill }
    private var textColor: Color { isStatus ? Color(nsColor: textNSColor) : idleText }
    /// wash toward the OPPOSITE of the text — white over a black-text (light) fill, black over a white-text
    /// (dark) one — so the pulse pushes the fill away from the contrast crossover, readable at the peak.
    private var washColor: Color { textNSColor == .black ? .white : .black }
    /// full-opacity text on a status pill and on the highlighted cell; muted only for an idle, unselected cell
    /// so the highlighted name reads as the focused one.
    private var textOpacity: Double { isStatus || isHighlighted ? 1 : unselectedTextOpacity }
    private var shouldPulse: Bool { isStatus && indicator.blink }
    /// Keep status color/text as the durable signal, but suppress the indefinite wash animation when
    /// macOS Reduce Motion is enabled. SwiftUI refreshes this environment value live.
    private var shouldAnimatePulse: Bool { shouldPulse && !reduceMotion }

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(textColor.opacity(textOpacity))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule()
                    .fill(fill)
                    // the blink: the opaque fill keeps covering the cell's frame ring while this wash capsule
                    // pulses its opacity on top, so nothing behind the chip ever shows through.
                    .overlay {
                        Capsule().fill(washColor)
                            .opacity(shouldAnimatePulse && pulsed ? Self.washPeakOpacity : 0)
                    }
            }
            // a pill-level implicit animation on `pulsed` — deeper in the tree than the grid's
            // `.transaction { animation = nil }`, so it re-enables the pulse for this pill WITHOUT re-animating
            // the grid's reparent (later-in-tree wins). Only the wash opacity keys off `pulsed`.
            .animation(shouldAnimatePulse
                ? .easeInOut(duration: Self.pulseDuration).repeatForever(autoreverses: true)
                : nil,
                       value: pulsed)
            .onAppear { pulsed = shouldAnimatePulse }
            .onChange(of: shouldAnimatePulse) { _, now in pulsed = now }
    }
}

/// The keys the dashboard's AppKit key-catcher recognizes; every other key is swallowed.
private enum DashboardKey {
    case move(DashboardLayout.Direction)
    case select
    case close
}

/// A zero-content AppKit view that owns first responder while the dashboard is open and consumes EVERY
/// keyDown, so no keystroke reaches a background terminal surface. Arrows move the highlight, Return/Enter
/// selects, Escape closes, everything else is swallowed (never passed to the next responder). Placed as a
/// `.background` so it never intercepts the cells' click hit targets. Menu key-equivalents (⌘Q, ⌘W, …) still
/// reach the menu bar via `performKeyEquivalent`, which runs before keyDown, so the user is never trapped.
private struct DashboardKeyCatcher: NSViewRepresentable {
    let focusRevision: Int
    let focusAllowed: Bool
    let onKey: (DashboardKey) -> Void

    func makeNSView(context _: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.focusAllowed = focusAllowed
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context _: Context) {
        _ = focusRevision
        nsView.focusAllowed = focusAllowed
        nsView.onKey = onKey
        // re-assert first responder on every render so a cell click (or any focus reshuffle) can't leave the
        // overlay without the keyboard while it is open.
        if focusAllowed { nsView.grabFocus() }
    }

    final class KeyCatcherView: NSView {
        var focusAllowed = true
        var onKey: ((DashboardKey) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            grabFocus()
        }

        /// Take first responder unless we already hold it (a redundant `makeFirstResponder` would churn).
        func grabFocus() {
            guard focusAllowed, let window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            // consume EVERY key: recognized keys drive the dashboard, the rest are swallowed by NOT calling
            // super, so nothing (and no beep) leaks to a terminal behind the overlay.
            switch event.keyCode {
            case 123: onKey?(.move(.left)) // left arrow
            case 124: onKey?(.move(.right)) // right arrow
            case 125: onKey?(.move(.down)) // down arrow
            case 126: onKey?(.move(.up)) // up arrow
            case 36, 76: onKey?(.select) // return, keypad enter
            case 53: onKey?(.close) // escape
            default: break // swallowed
            }
        }
    }
}
