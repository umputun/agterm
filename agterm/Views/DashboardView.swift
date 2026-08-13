import agtermCore
import AppKit
import SwiftUI

/// The dashboard grid overlay: a per-window, view-only modal hosting up to `DashboardLayout.maxCells` live
/// pane cells in a `ceil(sqrt(n))`-wide grid. The cell unit is a session+pane (a `DashboardMember`), so a
/// split session shows as TWO cells (its primary + split panes). No pane SURFACE takes input — each is
/// `.allowsHitTesting(false)` and never becomes first responder, so its cursor draws hollow; an AppKit
/// key-catcher owns first responder while open, walking a highlight between cells.
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
    /// The themed chrome foreground for the highlight ring, so it tracks the terminal theme, not the OS accent.
    let highlightColor: Color
    /// The themed terminal background — the OPAQUE backing for BOTH the whole grid and each cell, so a
    /// translucent terminal surface (window background-opacity < 1) still reads as a solid grid.
    let captionBackground: Color
    /// The IDLE caption pill's FILL — the theme's muted selection-background (the selected sidebar row's
    /// color), so an idle chip is a muted themed accent rather than the loud foreground.
    let pillColor: Color
    /// The IDLE caption pill's TEXT — the theme's selection-foreground, readable over `pillColor`.
    let pillTextColor: Color
    /// False while a control picker is above the dashboard, so its key catcher cannot steal focus.
    let focusAllowed: Bool
    /// Whether to restore the title-bar hairline the opaque backdrop covers. False in hidden toolbar mode,
    /// which draws no such line and insets the overlay by nothing, so it would sit on the window's top edge.
    let showsTopHairline: Bool
    /// A single click on a cell: the wiring flashes the active frame, then enters after a brief delay, so the
    /// click is visibly acknowledged before the grid closes.
    let onClick: (DashboardMember) -> Void
    /// Enter jumps into the highlighted session+pane immediately (select + close + focus). No click-flash
    /// delay — the keyboard highlight is already visible.
    let onSelect: (DashboardMember) -> Void
    /// Esc, or the wiring's close path, dismisses the dashboard.
    let onClose: () -> Void

    private static let cellCornerRadius: CGFloat = 6
    /// inter-cell (and outer) gap, kept WIDER than `captionBottomOffset` so the overhanging chip clears the
    /// cell below.
    private static let gridSpacing: CGFloat = 12
    private static let highlightLineWidth: CGFloat = 1.5
    /// nudge below the cell's bottom edge so the chip straddles the frame line instead of the last row.
    private static let captionBottomOffset: CGFloat = 8
    /// caption text opacity on an UNSELECTED cell, so the highlighted cell's name stands out.
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
        // an OPAQUE themed backdrop: the layer beneath (sidebar, add-buttons, deck) must not bleed through
        // the margins, deliberately dropping window translucency/blur. Not a black scrim — over the
        // translucent backing that read as near-black.
        .background(captionBackground)
        // restores the hairline the opaque backdrop covers, matching `WindowContentView.titlebarHairline`,
        // which likewise draws nothing in hidden toolbar mode.
        .overlay(alignment: .top) {
            if showsTopHairline { Rectangle().fill(highlightColor.opacity(0.1)).frame(height: 1) }
        }
        // behind the cells so it never intercepts their click hit targets.
        .background {
            DashboardKeyCatcher(
                focusRevision: controller.focusRevision,
                focusAllowed: focusAllowed,
                onKey: handleKey
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard")
        // no implicit animation on grid geometry or highlight — a modal reparent overlay applies its
        // @Observable-driven changes instantly, never as a transition.
        .transaction { $0.animation = nil }
    }

    /// One grid position: the member pane cell when `index` resolves, else a clear filler keeping every real
    /// cell the size of the full rows above (the ragged last row, and a session/pane that vanished mid-frame).
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
            // transparent hit target above the terminal: a lone count:1 tap registers immediately, while a
            // count:2 + count:1 pair delayed every click by the double-click timeout. Carries the per-cell
            // a11y id — the Metal-backed surface is not in the tree.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onClick(member) }
                .accessibilityElement()
                .accessibilityIdentifier("dashboard-cell")
            if isHighlighted {
                // a zero-content marker the e2e queries: it fills the cell, so its frame locates the highlight.
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityIdentifier("dashboard-highlighted")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Self.cellCornerRadius))
        .overlay {
            // the chrome foreground on the highlighted cell, the same color at low opacity on the rest.
            RoundedRectangle(cornerRadius: Self.cellCornerRadius)
                .strokeBorder(isHighlighted ? highlightColor : highlightColor.opacity(0.12),
                              lineWidth: isHighlighted ? Self.highlightLineWidth : 1)
        }
        // the caption rides the cell's BOTTOM frame line: an overlay OUTSIDE the clip, so its lower half
        // survives. Layered after the ring, and the pill paints its own opaque backing — ordering alone
        // leaves the ring showing through a translucent fill.
        .overlay(alignment: .bottom) {
            caption(for: member, session: session, isHighlighted: isHighlighted)
                .offset(y: Self.captionBottomOffset)
        }
    }

    /// Hosts the member's OWN pane surface as a view-only `TerminalView`. The `.id` carries the hosted slot
    /// (`-dashboard-primary`/`-dashboard-split`), so a cell keyed to one pane never reuses the other's
    /// representable, plus `surfaceToken` so a REPLACEMENT re-mounts the cell.
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

    /// A per-instance identity token for the member's resolved slot surface, folded into the cell `.id`; a
    /// nil slot keeps a stable `"none"` suffix. When a shown session's PRIMARY shell exits,
    /// `AppStore.closePrimaryPane` PROMOTES the split survivor into `session.surface` (a DIFFERENT instance)
    /// and nils `splitSurface`. The surviving cell is `.primary` either way — reconcile drops a `.split`
    /// cell that sits beside one, and `DashboardController.promoteSplitMember` rewrites a lone `.split`
    /// cell (a grid built from `<id>:right`) into it rather than letting it be pruned;
    /// `TerminalView.updateNSView` never re-resolves `session[keyPath:]`, so without the surface identity in
    /// the id SwiftUI keeps hosting the torn-down old primary (a blank cell) while the live survivor stays
    /// unhosted. `ObjectIdentifier` changes ONLY on a genuine swap, forcing a re-mount whose `makeNSView`
    /// re-resolves the slot; it is STABLE across ordinary re-renders, so no spurious re-host invalidates the
    /// Metal drawable and flickers. The slots are `@ObservationIgnored`, so the swap alone does not
    /// re-render — the reconcile-driven `controller.members` change does.
    private func surfaceToken(for member: DashboardMember, session: Session) -> String {
        let surface = member.surface == .split ? session.splitSurface : session.surface
        guard let surface else { return "none" }
        return "\(ObjectIdentifier(surface as AnyObject))"
    }

    /// A small name chip on the cell's bottom-RIGHT frame line, with a pane marker for a split session's two
    /// cells. `DashboardCaptionPill` owns fill, contrast and blink; this only right-aligns it via the leading
    /// `Spacer` (which also fixes the width, so a long name middle-truncates) and blocks no hit target.
    private func caption(for member: DashboardMember, session: Session, isHighlighted: Bool) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            DashboardCaptionPill(text: session.displayName + paneIndicator(for: member, session: session),
                                 indicator: session.agentIndicator, isHighlighted: isHighlighted,
                                 idleFill: pillColor, idleText: pillTextColor,
                                 unselectedTextOpacity: Self.unselectedCaptionTextOpacity,
                                 backing: captionBackground)
        }
        .padding(.horizontal, 6)
        .allowsHitTesting(false)
    }

    /// The caption's pane marker follows the session axis: right/left arrows or bottom/top arrows, and
    /// nothing for a non-split session. It marks which pane the cell hosts, not that its sibling is on the
    /// grid: a `<id>:left` request puts a lone `◀` cell up, which still says the session has another pane
    /// you are not watching.
    private func paneIndicator(for member: DashboardMember, session: Session) -> String {
        if member.surface == .split { return session.splitAxis == .topBottom ? " ▼" : " ▶" }
        guard session.hasSplit else { return "" }
        return session.splitAxis == .topBottom ? " ▲" : " ◀"
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
/// theme-selection pill (`idleText` over an `idleFill` capsule); NON-IDLE fills it with the agent-status
/// color and draws the name in luminance-contrasting black/white, readable over ANY color including an
/// arbitrary `session.status --color` override. Blinking keeps the capsule fully OPAQUE and pulses a color
/// WASH on top, NOT an opacity fade — fading let the cell's bright frame ring bleed through and read broken.
private struct DashboardCaptionPill: View {
    let text: String
    let indicator: AgentIndicator
    let isHighlighted: Bool
    let idleFill: Color
    let idleText: Color
    let unselectedTextOpacity: Double
    /// The opaque backing painted under the fill — the cell's own background, so a translucent fill never
    /// lets the cell frame line show through the capsule.
    let backing: Color

    /// peak opacity of the pulsing wash. Deep on purpose: on a large opaque capsule a shallow value reads as
    /// faint dimming rather than a blink (the small sidebar glyph needs less).
    private static let washPeakOpacity: Double = 0.75
    private static let pulseDuration: Double = 0.45

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsed = false

    private var isStatus: Bool { indicator.status != .idle }
    /// the resolved status tint (per-call `--color` override else Settings), computed once so fill and text agree.
    private var statusColor: NSColor { GhosttyApp.shared.statusColor(for: indicator.status, override: indicator.color) }
    /// black/white by the fill's luminance so the name is readable over any status color.
    private var textNSColor: NSColor { GhosttyApp.contrastingText(for: statusColor) }
    private var fill: Color { isStatus ? Color(nsColor: statusColor) : idleFill }
    private var textColor: Color { isStatus ? Color(nsColor: textNSColor) : idleText }
    /// wash toward the OPPOSITE of the text — white over a black-text (light) fill, black over a white-text
    /// (dark) one — so the pulse pushes the fill away from the contrast crossover, readable at the peak.
    private var washColor: Color { textNSColor == .black ? .white : .black }
    /// full opacity on a status pill and on the highlighted cell; muted only for an idle, unselected cell.
    private var textOpacity: Double { isStatus || isHighlighted ? 1 : unselectedTextOpacity }
    private var shouldPulse: Bool { isStatus && indicator.blink }
    /// Status color/text stay the durable signal, but the indefinite wash animation is suppressed under
    /// macOS Reduce Motion (SwiftUI refreshes the environment value live).
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
                // `backing` under the fill: the idle fill falls back to a translucent wash on themes with no
                // selection color, and the pill overhangs the cell's frame line, so a bare fill lets the
                // highlight ring read through the capsule and cross the name.
                Capsule()
                    .fill(backing)
                    .overlay {
                        Capsule().fill(fill)
                    }
                    .overlay {
                        Capsule().fill(washColor)
                            .opacity(shouldAnimatePulse && pulsed ? Self.washPeakOpacity : 0)
                    }
            }
            // deeper in the tree than the grid's `.transaction { animation = nil }` (later-in-tree wins), so
            // the pulse returns for this pill without re-animating the grid reparent; only the wash keys off it.
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
/// keyDown, so no keystroke reaches a background terminal surface. Menu key-equivalents (⌘Q, ⌘W, …) still
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
        // re-assert first responder each render so a click or focus reshuffle can't leave the overlay keyless.
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
            // the rest are swallowed by NOT calling super, so nothing (and no beep) leaks to the terminal behind.
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
