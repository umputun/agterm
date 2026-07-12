import agtermCore
import AppKit
import SwiftUI

/// The dashboard grid overlay: a per-window modal that hosts up to `DashboardLayout.maxCells` live pane
/// cells in a `ceil(sqrt(n))`-wide grid, view-only. The cell unit is a session+pane (a `DashboardMember`),
/// so a split session shows as TWO cells (its primary + split panes). No cell takes keyboard or mouse
/// input — each pane surface is `.allowsHitTesting(false)` and never becomes first responder, so its cursor
/// draws hollow. An AppKit key-catcher owns first responder while open and swallows every key, walking a
/// keyboard highlight between cells; Enter jumps into the highlighted session AND focuses that exact pane,
/// Esc closes. A transparent hit target over each cell single-click-highlights and double-click-enters
/// (mouse is secondary).
///
/// The view is purely presentational and closure-driven: `WindowContentView` mounts it in
/// `windowOverlayLayer` while `controller.isOpen`, generalizes its deck to yield each member's surface into
/// a cell, and supplies the session lookup, surface factories, and enter/close side effects.
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
    /// Single click on a cell highlights it (keyboard is primary, mouse secondary).
    let onHighlight: (DashboardMember) -> Void
    /// Enter, or a double click on a cell, jumps into that session+pane (the wiring selects + closes + focuses).
    let onSelect: (DashboardMember) -> Void
    /// Esc, or the wiring's close path, dismisses the dashboard.
    let onClose: () -> Void

    private static let cellCornerRadius: CGFloat = 6
    private static let gridSpacing: CGFloat = 8
    private static let highlightLineWidth: CGFloat = 2

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
        // a moderate scrim so the grid reads as a distinct modal over whatever remains behind it.
        .background(Color.black.opacity(0.4))
        // the key-catcher sits behind the cells so it never intercepts their click hit targets; it owns
        // first responder and swallows every key while open.
        .background { DashboardKeyCatcher(onKey: handleKey) }
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
            memberTerminal(for: member, session: session)
                .allowsHitTesting(false)
            caption(for: member, session: session)
            // transparent hit target above the terminal: single click highlights, double click enters.
            // it carries the per-cell accessibility id (the Metal-backed surface is not in the a11y tree).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onSelect(member) }
                .onTapGesture(count: 1) { onHighlight(member) }
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
            // a thin, theme-tracking ring: the themed chrome foreground on the highlighted cell, the same
            // color at low opacity on the rest, so the border matches the active terminal theme (not the OS
            // accent) in both light and dark.
            RoundedRectangle(cornerRadius: Self.cellCornerRadius)
                .strokeBorder(isHighlighted ? highlightColor : highlightColor.opacity(0.12),
                              lineWidth: isHighlighted ? Self.highlightLineWidth : 1)
        }
    }

    /// Hosts the member's OWN pane surface as a view-only `TerminalView`: `.primary` → `\.surface` via
    /// `makeSurface`, `.split` → `\.splitSurface` via `makeSplitSurface`. The `.id` carries the hosted slot
    /// (`-dashboard-primary`/`-dashboard-split`) so a cell keyed to one pane never reuses the other pane's
    /// representable. `isActive`/`deckVisible`/`reportsFocusChange` are all off and `viewOnly` is on, so the
    /// cell auto-focuses nothing, is not a drop target, refuses first responder, and never mutates session
    /// focus state.
    @ViewBuilder
    private func memberTerminal(for member: DashboardMember, session: Session) -> some View {
        if member.surface == .split {
            TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                         isActive: false, deckVisible: false, reportsFocusChange: false, viewOnly: true)
                .id("\(session.id.uuidString)-dashboard-split")
        } else {
            TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                         isActive: false, deckVisible: false, reportsFocusChange: false, viewOnly: true)
                .id("\(session.id.uuidString)-dashboard-primary")
        }
    }

    /// A small dimmed name chip pinned to the cell's bottom-left. For a split session's two cells a subtle
    /// pane marker (`◀` primary / `▶` split) is appended so they read as the left/right pane of the same
    /// session; a non-split session's single cell shows just the name. `.ultraThinMaterial` keeps it legible
    /// over any terminal theme; non-interactive so it never blocks the hit target above it.
    private func caption(for member: DashboardMember, session: Session) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Text(session.displayName + paneIndicator(for: member, session: session))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(6)
        }
        .allowsHitTesting(false)
    }

    /// The pane marker suffix for the caption: `▶` for a split (right) pane cell, `◀` for the primary (left)
    /// pane cell of a SPLIT session (both cells present, so they need distinguishing), and nothing for a
    /// non-split session's single primary cell.
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

/// The keys the dashboard's AppKit key-catcher recognizes; every other key is swallowed.
private enum DashboardKey {
    case move(DashboardLayout.Direction)
    case select
    case close
}

/// A zero-content AppKit view that owns first responder while the dashboard is open and consumes EVERY
/// keyDown, so no keystroke reaches a background terminal surface (the cells are view-only). Arrows drive a
/// highlight move, Return/Enter selects, Escape closes, and all other keys are swallowed (never passed to
/// the next responder). Placed as a `.background` so it never intercepts the cells' click hit targets. Menu
/// key-equivalents (⌘Q, ⌘W, …) still reach the menu bar — those go through `performKeyEquivalent` before
/// keyDown, so the user is never trapped; only plain keystrokes to the terminal are blocked.
private struct DashboardKeyCatcher: NSViewRepresentable {
    let onKey: (DashboardKey) -> Void

    func makeNSView(context _: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context _: Context) {
        nsView.onKey = onKey
        // re-assert first responder on every render so a cell click (or any focus reshuffle) can't leave the
        // overlay without the keyboard while it is open.
        nsView.grabFocus()
    }

    final class KeyCatcherView: NSView {
        var onKey: ((DashboardKey) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            grabFocus()
        }

        /// Take first responder unless we already hold it (a redundant `makeFirstResponder` would churn).
        func grabFocus() {
            guard let window, window.firstResponder !== self else { return }
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
