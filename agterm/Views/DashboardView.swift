import agtermCore
import AppKit
import SwiftUI

/// The dashboard grid overlay: a per-window modal that hosts up to `DashboardLayout.maxCells` live member
/// terminal surfaces in a `ceil(sqrt(n))`-wide grid, view-only. No cell takes keyboard or mouse input —
/// each member surface is `.allowsHitTesting(false)` and never becomes first responder, so its cursor
/// draws hollow. An AppKit key-catcher owns first responder while open and swallows every key, walking a
/// keyboard highlight between cells; Enter jumps into the highlighted session, Esc closes. A transparent
/// hit target over each cell single-click-highlights and double-click-enters (mouse is secondary).
///
/// The view is purely presentational and closure-driven: `WindowContentView` mounts it in
/// `windowOverlayLayer` while `controller.isOpen`, generalizes its deck to yield each member's surface into
/// a cell, and supplies the session lookup, surface factories, and enter/close side effects.
struct DashboardView: View {
    let controller: DashboardController
    /// Resolves a member UUID to its live `Session` (the window's `AppStore`), mirroring `SessionSwitcherOverlay`.
    let store: AppStore
    /// The primary surface factory — used for a member whose `session.surface` slot is live.
    let makeSurface: (Session) -> GhosttySurfaceView
    /// The split surface factory — the defensive `.split` branch, used only for a genuine split-only survivor
    /// (`session.surface == nil` while `splitSurface` is live), so the dashboard hosts its `addressableSurface`
    /// rather than spawning a new shell. A promoted survivor no longer reaches here: `closePrimaryPane` moves
    /// it INTO `surface`, so it hosts via the primary factory.
    let makeSplitSurface: (Session) -> GhosttySurfaceView
    /// Single click on a cell highlights it (keyboard is primary, mouse secondary).
    let onHighlight: (UUID) -> Void
    /// Enter, or a double click on a cell, jumps into that session (the wiring selects + closes + focuses).
    let onSelect: (UUID) -> Void
    /// Esc, or the wiring's close path, dismisses the dashboard.
    let onClose: () -> Void

    private static let cellCornerRadius: CGFloat = 6
    private static let gridSpacing: CGFloat = 8

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

    /// One grid position: the member cell when `index` is in range, else a clear filler that keeps every
    /// real cell the same size as the full rows above it (the ragged last-row case).
    @ViewBuilder
    private func cellSlot(index: Int, members: [UUID]) -> some View {
        if index < members.count, let session = store.session(withID: members[index]) {
            cell(for: session)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cell(for session: Session) -> some View {
        let isHighlighted = controller.highlighted == session.id
        return ZStack {
            memberTerminal(for: session)
                .allowsHitTesting(false)
            caption(for: session)
            // transparent hit target above the terminal: single click highlights, double click enters.
            // it carries the per-cell accessibility id (the Metal-backed surface is not in the a11y tree).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onSelect(session.id) }
                .onTapGesture(count: 1) { onHighlight(session.id) }
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
            RoundedRectangle(cornerRadius: Self.cellCornerRadius)
                .strokeBorder(isHighlighted ? Color.accentColor : Color.white.opacity(0.08),
                              lineWidth: isHighlighted ? 3 : 1)
        }
    }

    /// Hosts the member's resolved `addressableSurface` slot as a view-only `TerminalView`: `\.surface`
    /// when the primary shell is live or the member is not yet realized, else `\.splitSurface` for a genuine
    /// split-only survivor — never `\.splitSurface` blindly (that would spawn a stray right-pane shell). The
    /// `.id` carries the hosted slot (`-dashboard-primary`/`-dashboard-split`) so a kind flip rebuilds the
    /// representable against the matching key path instead of reusing the stale one. `isActive`/`deckVisible`/
    /// `reportsFocusChange` are all off so the cell auto-focuses nothing, is not a drop target, and never
    /// mutates session focus state.
    @ViewBuilder
    private func memberTerminal(for session: Session) -> some View {
        if session.addressableSurfaceKind == .primary {
            TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                         isActive: false, deckVisible: false, reportsFocusChange: false, viewOnly: true)
                .id("\(session.id.uuidString)-dashboard-primary")
        } else {
            TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                         isActive: false, deckVisible: false, reportsFocusChange: false, viewOnly: true)
                .id("\(session.id.uuidString)-dashboard-split")
        }
    }

    /// A small dimmed name chip pinned to the cell's bottom-left. `.ultraThinMaterial` keeps it legible over
    /// any terminal theme; non-interactive so it never blocks the hit target above it.
    private func caption(for session: Session) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Text(session.displayName)
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
