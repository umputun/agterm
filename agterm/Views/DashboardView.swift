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
    /// The themed terminal background — the OPAQUE per-cell backing, so a translucent terminal surface
    /// (window background-opacity < 1) still reads as a solid cell in the grid.
    let captionBackground: Color
    /// The caption pill's FILL — the theme's muted selection-background highlight (the same color the selected
    /// sidebar row draws), so the chip is a themed, muted accent rather than the loud foreground.
    let pillColor: Color
    /// The caption pill's TEXT — the theme's selection-foreground, readable over `pillColor`.
    let pillTextColor: Color
    /// Single click on a cell highlights it (keyboard is primary, mouse secondary).
    let onHighlight: (DashboardMember) -> Void
    /// Enter, or a double click on a cell, jumps into that session+pane (the wiring selects + closes + focuses).
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
        // NO darkening backdrop: a transparent fill, exactly like the quick terminal's margin, so the area
        // OUTSIDE the cells preserves the window's translucency + blur (the emptied deck slots already yield
        // Color.clear, revealing the translucent window backing). A black scrim here composited OVER that
        // backing and read as near-black — the cells already stand apart via their opaque backing + ring, so
        // no scrim is needed to make the grid a distinct modal.
        .background(Color.clear)
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
            // an opaque theme-background backing so a translucent terminal surface (window
            // background-opacity < 1) reads as an OPAQUE cell in the grid, not a see-through one.
            captionBackground
            memberTerminal(for: member, session: session)
                .allowsHitTesting(false)
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
        // the caption rides the cell's BOTTOM frame line: an overlay OUTSIDE the clip (so its lower half is
        // not clipped away) is bottom-aligned and nudged down, so the chip straddles the border stroke
        // instead of covering the terminal's last row. it is layered AFTER the border ring so the chip draws
        // ON TOP of the frame line (the line never crosses over the name), keeping it legible.
        .overlay(alignment: .bottom) {
            caption(for: member, session: session, isHighlighted: isHighlighted)
                .offset(y: Self.captionBottomOffset)
        }
    }

    /// Hosts the member's OWN pane surface as a view-only `TerminalView`: `.primary` → `\.surface` via
    /// `makeSurface`, `.split` → `\.splitSurface` via `makeSplitSurface`. The `.id` carries the hosted slot
    /// (`-dashboard-primary`/`-dashboard-split`) so a cell keyed to one pane never reuses the other pane's
    /// representable, PLUS the resolved surface's per-instance identity (`surfaceToken`) so a surface
    /// REPLACEMENT re-mounts the cell — see `surfaceToken`. `isActive`/`deckVisible`/`reportsFocusChange` are
    /// all off and `viewOnly` is on, so the cell auto-focuses nothing, is not a drop target, refuses first
    /// responder, and never mutates session focus state.
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
    /// (a DIFFERENT surface instance) and nils `splitSurface`; reconcile then drops the `.split` cell but
    /// keeps the `.primary` one. `TerminalView.updateNSView` never re-resolves `session[keyPath:]`, so without
    /// the surface identity in the id SwiftUI would keep hosting the torn-down old primary surface (a blank
    /// cell) while the live survivor stays unhosted. Folding `ObjectIdentifier` into the id changes it on a
    /// swap, forcing a re-mount → `makeNSView` re-resolves the slot → hosts the survivor. The token is STABLE
    /// across ordinary re-renders (same instance → same token → no spurious re-host, which would invalidate
    /// the Metal drawable and flicker), and changes ONLY on a genuine surface swap. `session.surface`/
    /// `splitSurface` are `@ObservationIgnored`, so the swap alone does not re-render — the reconcile-driven
    /// `controller.members` change is what re-renders the grid and re-reads the new slot surface. A nil slot
    /// keeps a stable `"none"` suffix.
    private func surfaceToken(for member: DashboardMember, session: Session) -> String {
        let surface = member.surface == .split ? session.splitSurface : session.surface
        guard let surface else { return "none" }
        return "\(ObjectIdentifier(surface as AnyObject))"
    }

    /// A small themed name chip riding the cell's bottom-RIGHT frame line. For a split session's two cells a
    /// subtle pane marker (`◀` primary / `▶` split) is appended so they read as the left/right pane of the
    /// same session; a non-split session's single cell shows just the name. The chip is a SOLID FILLED capsule
    /// in the theme's MUTED selection colors — `pillTextColor` (selection-foreground) text over a `pillColor`
    /// (selection-background) fill, the same muted highlight the selected sidebar row uses — so it reads as a
    /// clearly-filled, legible pill without the loud foreground. Non-interactive so it never blocks the hit
    /// target above it. Right-aligned via the leading `Spacer`, which also fixes the chip's width so a long name
    /// middle-truncates instead of overflowing the cell. On an unselected cell the label text is muted
    /// (`unselectedCaptionTextOpacity`) so the highlighted cell's name reads as the focused one.
    private func caption(for member: DashboardMember, session: Session, isHighlighted: Bool) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(session.displayName + paneIndicator(for: member, session: session))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(pillTextColor.opacity(isHighlighted ? 1 : Self.unselectedCaptionTextOpacity))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(pillColor, in: Capsule())
        }
        .padding(.horizontal, 6)
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
