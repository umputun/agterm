import agtermCore
import AppKit
import SwiftUI

extension WindowContentView {
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
            // zoom closes this window's transient chrome, uniformly: the palette, an open ⌘F search
            // (otherwise libghostty stays in search mode with stale full-window highlights and no
            // visible bar), and — for a session-surface zoom — a visible quick terminal (the zoom
            // layer replaces its host, which would strand `isVisible` true with nothing on screen).
            // A `.quick` zoom keeps the quick terminal: the zoom layer hosts it. The palette is
            // app-global and renders in the FRONTMOST window, so only that window's zoom may close
            // it — a control-driven zoom of a background window must not kill the user's palette.
            if library.activeWindowID == windowID { palette.close() }
            if let session = store.activeSession, session.searchActive {
                (session.searchSurface as? GhosttySurfaceView)?.endSearch()
            }
            if case let .session(sessionID, surface) = new {
                if quickTerminal.isVisible { quickTerminal.hide() }
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
        if let old, new == nil {
            switch old {
            case .quick:
                // the un-zoomed quick terminal may have been hidden in the same step (`quick hide`
                // un-zooms then hides): only refocus it while it is still on screen — its own
                // isVisible onChange handles the focus return otherwise.
                if quickTerminal.isVisible { quickTerminal.focus() }
            case .session:
                // scoped to THIS window, like the palette close above: `focusActiveSession` targets the
                // FRONTMOST window, so a background window's zoom exit (its zoomed overlay/scratch
                // exiting on its own, or a control-driven `surface zoom hide --window`) must not grab
                // first responder there — e.g. out of an open ⌘F search field the user is typing into.
                if library.activeWindowID == windowID { actions.focusActiveSession() }
            }
        }
    }

    /// Whether the eager deck (not the zoom layer OR a dashboard cell) hosts this session-surface slot.
    /// False for the one surface terminal zoom currently owns AND for any surface an open dashboard has
    /// reparented into a grid cell — either renders the `Color.clear` placeholder in `sessionDetail` (an
    /// NSView can live in one host at a time) while every other slot stays mounted, keeping the deck entry's
    /// shape constant and its surfaces realizing behind the modal layer. The dashboard exclusion is the
    /// union partner of the zoom exclusion (both are mutually exclusive, so at most one is ever active).
    func deckHostsSurface(session: Session, surface: TerminalZoomSurface) -> Bool {
        if dashboardHostsSurface(session: session, surface: surface) { return false }
        guard case let .session(sessionID, zoomSurface) = terminalZoom.target else { return true }
        return sessionID != session.id || zoomSurface != surface
    }

    @ViewBuilder func terminalZoomLayer(_ target: TerminalZoomTarget) -> some View {
        if TerminalZoomController.isTargetValid(target, in: store, quickTerminalVisible: quickTerminal.isVisible) {
            switch target {
            case .quick:
                zoomTerminalHost {
                    QuickTerminalPane(controller: quickTerminal)
                }
            case let .session(sessionID, surface):
                // focus is driven by the body's `.onChange(of: terminalZoom.target)`, not an
                // `.onAppear` here: a retarget while already zoomed keeps this branch's structural
                // identity, so `.onAppear` would fire only for the first target.
                if let session = store.session(withID: sessionID) {
                    zoomTerminalHost {
                        zoomedSessionTerminal(session: session, surface: surface)
                    }
                } else {
                    Color.clear.onAppear { terminalZoom.clear() }
                }
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
        // no opaque backing: the deck behind is already at opacity 0, so the window backing shows
        // through and zoom keeps the un-zoomed terminal's translucency (an opaque color here flipped
        // a translucent window solid on zoom and back).
        .accessibilityIdentifier("terminal-zoom")
    }

    @ViewBuilder func zoomedSessionTerminal(session: Session, surface: TerminalZoomSurface) -> some View {
        switch surface {
        case .primary:
            TerminalView(session: session, surfaceKeyPath: \.surface, makeSurface: makeSurface,
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(session.id.uuidString)-zoom-primary")
        case .split:
            TerminalView(session: session, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface,
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(session.id.uuidString)-zoom-split")
        case .scratch:
            TerminalView(session: session, surfaceKeyPath: \.scratchSurface, makeSurface: makeScratchSurface,
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(session.id.uuidString)-zoom-scratch")
        case .overlay:
            TerminalView(session: session, surfaceKeyPath: \.overlaySurface, makeSurface: makeOverlaySurface,
                         isActive: true, deckVisible: true, reportsFocusChange: false)
                .id("\(session.id.uuidString)-zoom-overlay")
        }
    }

    /// Focus the zoomed surface once it exists, then hand off to `focusAfterReparent()` — the shared
    /// bounded reparent-focus retry (conditional grab, stops once focus has stuck) — so zoom doesn't
    /// grow its own copy of that machinery. The outer retry here only waits for a surface the zoom
    /// layer's `TerminalView` hasn't realized yet (e.g. zooming a scratch that was never shown); it
    /// dies as soon as the zoom target changes.
    func focusZoomedSessionSurface(session: Session, surface: TerminalZoomSurface, attempt: Int = 0) {
        let expectedTarget = TerminalZoomTarget.session(session.id, surface)
        guard terminalZoom.target == expectedTarget else { return }
        let target: (any TerminalSurface)? = switch surface {
        case .primary: session.surface
        case .split: session.splitSurface
        case .scratch: session.scratchSurface
        case .overlay: session.overlaySurface
        }
        if let view = target as? GhosttySurfaceView {
            // suppress the focus report BEFORE the first grab: this runs from the target onChange, which
            // can land before the zoom layer's TerminalView has mounted and flipped the flag — an
            // unsuppressed makeFirstResponder on the still-deck-hosted surface would fire
            // onFocusChange(true) and mutate splitFocused, the exact write zoom must not make. The deck
            // TerminalView resets the flag when it remounts the surface on zoom exit.
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
