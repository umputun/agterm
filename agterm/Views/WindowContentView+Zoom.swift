import agtermCore
import AppKit
import SwiftUI

extension WindowContentView {
    /// Restore keyboard ownership to whichever full-window cover was already present below a picker.
    /// The ordinary session focus helper intentionally refuses to cross these modal layers.
    func restoreFocusAfterPick() {
        if dashboard.isOpen {
            dashboard.requestFocus()
            return
        }
        // the quick terminal is a panel of its own, so a picker in THIS window never covered it and it
        // reclaims its own key; only this window's own covers are restored here.
        if case let .session(sessionID, surface) = terminalZoom.target {
            guard let session = store.session(withID: sessionID) else { return }
            focusZoomedSessionSurface(session: session, surface: surface)
            return
        }
        actions.focusActiveSession()
    }

    /// The chrome above the zoomed terminal: the exit-zoom row, or — in hidden toolbar mode — the same
    /// invisible ~3px drag strip `customTitlebar` degrades to (no row; zoom exit stays on the keybinding
    /// and the control command), so hidden mode keeps its full-bleed terminal while zoomed.
    @ViewBuilder var zoomTitlebar: some View {
        if toolbarMode == .hidden {
            Color.clear
                .frame(height: 3)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .background { WindowControlArea() }
        } else {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 78)
                    .allowsHitTesting(false)
                titleLabel
                    .padding(.leading, 8)
                    // falls through to the drag/zoom layer behind the bar, like the normal title.
                    .allowsHitTesting(false)
                Spacer(minLength: 12)
                Button {
                    terminalZoom.clear()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .help("Exit Terminal Zoom")
                .accessibilityLabel("Exit Terminal Zoom")
                .accessibilityIdentifier("terminal-zoom-exit")
                .padding(.trailing, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(chromeText)
            .imageScale(toolbarMode == .normal ? .large : .medium)
            .frame(height: titlebarHeight)
            .frame(maxWidth: .infinity)
            .background { WindowControlArea() }
        }
    }

    /// React to a zoom target change (the body's `.onChange(of: terminalZoom.target)`): entering zoom
    /// closes the window's transient chrome and focuses the zoomed surface; exiting returns focus.
    func handleZoomTargetChange(old: TerminalZoomTarget?, new: TerminalZoomTarget?) {
        if let new {
            // zoom closes this window's transient chrome: the palette and an open ⌘F search (else libghostty
            // stays in search mode with stale full-window highlights and no visible bar). The quick terminal
            // is NOT closed — it is a panel above every window, so a zoom inside one neither hosts nor hides
            // it; taking key back from the panel is what dismisses it.
            // The palette is app-global and renders in the FRONTMOST window, so only that window's zoom may
            // close it — a control-driven zoom of a background window must not kill the user's palette.
            if library.activeWindowID == windowID { palette.close() }
            if let session = store.activeSession, session.searchActive {
                (session.searchSurface as? GhosttySurfaceView)?.endSearch()
            }
            if case let .session(sessionID, surface) = new {
                if let session = store.session(withID: sessionID) {
                    // an explicit control target can zoom a BACKGROUND session's surface without
                    // selecting it: end THAT session's search too (the active-session clear above
                    // misses it), or its libghostty match highlights render zoomed with no bar.
                    if session.searchActive, session.id != store.selectedSessionID {
                        (session.searchSurface as? GhosttySurfaceView)?.endSearch()
                    }
                    // focus the zoomed surface on every target change — entering zoom AND retargeting
                    // while already zoomed (`surface zoom show --target <other>`), which no `.onAppear`
                    // can cover (the layer's structural identity doesn't change on a retarget).
                    focusZoomedSessionSurface(session: session, surface: surface)
                }
            }
        }
        if let old, new == nil, case .session = old {
            // scoped to THIS window, like the palette close above: `focusActiveSession` targets the
            // FRONTMOST window, so a background window's zoom exit must not grab first responder there
            // — e.g. out of an open ⌘F search field the user is typing into.
            if library.activeWindowID == windowID { actions.focusActiveSession() }
        }
    }

    /// Whether the eager deck (not the zoom layer or a dashboard cell) hosts this session-surface slot. False
    /// for the one surface zoom owns AND for any surface an open dashboard reparented into a grid cell —
    /// either renders the `Color.clear` placeholder in `sessionDetail` (an NSView lives in one host at a
    /// time) while every other slot stays mounted, keeping the deck entry's shape constant and its surfaces
    /// realizing behind the modal layer. The two exclusions are mutually exclusive, so at most one is active.
    func deckHostsSurface(session: Session, surface: TerminalZoomSurface) -> Bool {
        if dashboardHostsSurface(session: session, surface: surface) { return false }
        guard case let .session(sessionID, zoomSurface) = terminalZoom.target else { return true }
        return sessionID != session.id || zoomSurface != surface
    }

    @ViewBuilder func terminalZoomLayer(_ target: TerminalZoomTarget) -> some View {
        // `.quick` is never a window's target (the panel is app-level), so `isTargetValid` rejects it and the
        // stale value clears here rather than needing a case of its own.
        if TerminalZoomController.isTargetValid(target, in: store),
           case let .session(sessionID, surface) = target, let session = store.session(withID: sessionID) {
            // focus is driven by the body's `.onChange(of: terminalZoom.target)` — see
            // `handleZoomTargetChange` for why no `.onAppear` here.
            zoomTerminalHost {
                zoomedSessionTerminal(session: session, surface: surface)
            }
        } else {
            Color.clear.onAppear { terminalZoom.clear() }
        }
    }

    @ViewBuilder func zoomTerminalHost<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: titlebarHeight)
                .allowsHitTesting(false)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // no opaque backing: the deck behind is already at opacity 0, so the window backing shows through
        // and zoom keeps the terminal's translucency (an opaque color flipped a translucent window solid).
        .accessibilityIdentifier("terminal-zoom")
    }

    @ViewBuilder func zoomedSessionTerminal(session: Session, surface: TerminalZoomSurface) -> some View {
        switch surface {
        case .primary:
            TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(primarySurfaceID(session))-zoom")
        case .split:
            TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(session.id.uuidString)-zoom-split")
        case .scratch:
            TerminalView(session: session, surfaceKeyPath: \.scratchSurface, makeSurface: makeScratchSurface,
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(session.id.uuidString)-zoom-scratch")
        case .overlay:
            TerminalView(session: session, surfaceKeyPath: \.overlaySurface,
                         makeSurface: { makeOverlaySurface($0, nil) },
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(session.id.uuidString)-zoom-overlay")
        case .overlayLeft:
            TerminalView(session: session, surfaceKeyPath: \.leftOverlaySurface,
                         makeSurface: { makeOverlaySurface($0, .left) },
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(session.id.uuidString)-zoom-overlay-left")
        case .overlayRight:
            TerminalView(session: session, surfaceKeyPath: \.rightOverlaySurface,
                         makeSurface: { makeOverlaySurface($0, .right) },
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(session.id.uuidString)-zoom-overlay-right")
        }
    }

    /// Focus the zoomed surface once it exists, then hand off to `focusAfterReparent()` — the shared bounded
    /// reparent-focus retry (conditional grab, stops once focus sticks) — so zoom grows no copy of that
    /// machinery. The outer retry here only waits for a surface the zoom layer's `TerminalView` hasn't
    /// realized yet (e.g. zooming a never-shown scratch), and dies as soon as the zoom target changes.
    func focusZoomedSessionSurface(session: Session, surface: TerminalZoomSurface, attempt: Int = 0) {
        guard pick.pending == nil else { return }
        let expectedTarget = TerminalZoomTarget.session(session.id, surface)
        guard terminalZoom.target == expectedTarget else { return }
        if let view = surface.surface(in: session) as? GhosttySurfaceView {
            // suppress the focus report BEFORE the first grab: this runs from the target onChange, which can
            // land before the zoom layer's TerminalView has mounted and flipped the flag, and an unsuppressed
            // makeFirstResponder on the still-deck-hosted surface fires onFocusChange(true) and mutates
            // splitFocused — the exact write zoom must not make. The deck TerminalView resets it on exit.
            view.suppressFocusChange = true
            view.focusAfterReparent()
            return
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            focusZoomedSessionSurface(session: session, surface: surface, attempt: attempt + 1)
        }
    }
}
