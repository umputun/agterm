import AppKit
import Foundation
import agtermCore

/// `ControlServer` window-command action arms — create, list, select, close, resize, move, zoom, rename,
/// and delete on-screen windows via `WindowRegistry` + the `WindowLibrary`. Split out of
/// `ControlServer.swift` for the swiftlint size limit.
extension ControlServer {
    /// Create a new window (library) and open its on-screen window via the action hub's window opener
    /// (the same `enqueueClaim` + `openWindow(id:)` path the menu uses). Returns the new window id.
    ///
    /// Bounded-polls for the NSWindow to ATTACH before replying, so `window.new` followed immediately by
    /// `window.resize`/`move`/`zoom` works — those need a registered window and would otherwise fail. The
    /// poll must gate on `WindowRegistry.isRegistered`, NOT `library.isOpen`: `newWindow()` loads the store
    /// synchronously, so `isOpen` is already true and would prove nothing, while the NSWindow only attaches
    /// after SwiftUI resolves the store and runs a second render pass. Fire-and-forget like the other
    /// polls — a window that never renders times out and the command still replies ok.
    ///
    /// `minimized` creates the window and THEN parks it in the Dock, so a script can build a set of
    /// project windows and be left on one it can still see.
    func windowNew(name: String?, minimized: Bool) async -> ControlResponse {
        let info = library.newWindow(name: trimmed(name))
        actions.openWindow?(info.id)
        await pollUntil { WindowRegistry.shared.isRegistered(info.id) }
        if minimized { await park(info.id) }
        return ControlResponse(ok: true, result: ControlResult(id: info.id.uuidString))
    }

    /// Park a freshly created window: minimize it, wait out the animation, and hand frontmost back.
    ///
    /// The wait before minimizing is load-bearing. `WindowAccessor` presents the window on attach BOTH
    /// synchronously and again on the next main-queue turn, and that second present deminiaturizes — so
    /// minimizing the instant registration lands would simply be undone. One poll tick yields the main
    /// actor long enough for the queued present to drain first.
    ///
    /// The attach poll above is bounded and fire-and-forget, so a window that never rendered reaches here
    /// unregistered and `minimize` answers `.notOpen`. LOG that rather than swallowing it: the window is
    /// then still on screen holding focus while the caller was told it was parked. Frontmost is handed off
    /// only when the park actually applied — an unparked window is visible, so nothing is owed.
    private func park(_ id: WindowInfo.ID) async {
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard case .applied = WindowRegistry.shared.minimize(id, mode: .on) else {
            log("window.new --minimized: \(id) never attached in time, left presented")
            return
        }
        await pollUntil { WindowRegistry.shared.isMinimized(id) }
        handOffFrontmost(from: id)
    }

    /// Project the window library into the `window.list` response: every window with its open flag and
    /// whether it is the frontmost (active) window.
    func buildWindowList() -> [ControlWindowNode] {
        library.controlWindowNodes(geometry: { WindowRegistry.shared.geometry(for: $0) },
                                   flags: { WindowRegistry.shared.windowFlags(for: $0) })
    }

    func windowList() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(windows: buildWindowList()))
    }

    /// Resolve a window id and surface it: raise an already-open window, or open a closed one (the
    /// action hub's opener claims its id + spawns the window). This bounded-polls for the NSWindow to
    /// ATTACH before replying — a script can then immediately target it (`tree --window <id>`, or a
    /// frame command) without racing the window appearing. Returns the window id.
    ///
    /// The poll waits for BOTH the store and the NSWindow. `library.isOpen` alone only reports that the
    /// store loaded — which is what `tree --window` needs, so it stays — but it flips a render pass before
    /// the NSWindow exists, so a frame command issued right after would still hit `window not open`. An
    /// already-open, already-attached window satisfies both on the first iteration.
    ///
    /// Selecting also takes frontmost EXPLICITLY. `raise` makes the window key, but `frontmostWindowID` is
    /// only updated by `WindowAccessor.reportFrontmost` on `didBecomeKey`, which AppKit does not deliver
    /// while the app is inactive — so a background `window select` used to reply ok while every untargeted
    /// command kept routing into the previously-active window. Same asymmetry `handOffFrontmost` fixes on
    /// the minimize path, and the same reconcile is owed.
    func windowSelect(_ target: String?) async -> ControlResponse {
        switch resolver.resolveWindowID(target) {
        case .failure(let response): return response
        case .success(let id):
            actions.openWindow?(id)
            await pollUntil { self.library.isOpen(id) && WindowRegistry.shared.isRegistered(id) }
            takeFrontmost(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window id and close its on-screen window (the registry's `performClose` runs the
    /// standard teardown + `closeWindow` path, which fires asynchronously). Bounded-polls for the
    /// library to mark it closed before replying, so an immediate follow-up command sees it closed. A
    /// no-op for an already-closed window still reports ok with the id. Returns the window id.
    func windowClose(_ target: String?) async -> ControlResponse {
        switch resolver.resolveWindowID(target) {
        case .failure(let response): return response
        case .success(let id):
            // close the on-screen window if it's registered (drives the willClose teardown), then a
            // semantic fallback: if it isn't registered yet (window.close racing window.new before the
            // NSWindow attaches) or willClose hasn't flipped the flag, drop the store directly so the
            // window is reliably marked closed regardless of the attach timing.
            let hadWindow = WindowRegistry.shared.close(id)
            if hadWindow {
                await pollUntil { !self.library.isOpen(id) }
            }
            if library.isOpen(id) {
                library.closeWindow(id)
            }
            // dropping a store is unobserved, so poke the Dock badge to drop this window's unseen total.
            DockBadgeController.shared.refresh()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Bounded poll for an asynchronous window lifecycle transition (open after `window.select`, closed
    /// after `window.close`): the SwiftUI scene opens/closes the window off this dispatch, so the
    /// library flag flips a beat later. 30 × 0.05 s (≈1.5 s) of `Task.sleep` yields the main actor
    /// between checks — it never blocks the accept loop. Returns when `done()` holds or the budget is
    /// spent (the caller replies ok regardless: fire-and-forget, the poll only narrows the race).
    private func pollUntil(_ done: () -> Bool) async {
        for _ in 0..<30 {
            if done() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Resolve a window id and resize its on-screen window to `width` x `height` points (frame size).
    /// The window must be open; a closed window errors (resize it after `window.select`). Control-native
    /// (no GUI surface — the native title bar already drags-to-resize).
    func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse {
        return resolver.resolveWindowID(target) { id in
            guard WindowRegistry.shared.resize(id, width: width, height: height) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window id and move its on-screen window so its top-left corner is at (`x`, `y`) points in
    /// the global top-left space (origin = the primary display's top-left, spanning all displays). The
    /// window must be open; a closed window errors. Control-native (no GUI surface).
    func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse {
        if let display, display < 0 || display >= NSScreen.screens.count {
            return ControlResponse(ok: false, error: "display \(display) out of range (have \(NSScreen.screens.count))")
        }
        return resolver.resolveWindowID(target) { id in
            guard WindowRegistry.shared.move(id, x: x, y: y, display: display) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window id and zoom (maximize-to-screen toggle) its on-screen window. The window must be
    /// open; a closed window errors. The control half of the double-click-header gesture (a plain green-button
    /// click does native full screen, not zoom) — drives the same `NSWindow.zoom` as `WindowRegistry.zoom`.
    func windowZoom(_ target: String?) -> ControlResponse {
        return resolver.resolveWindowID(target) { id in
            guard WindowRegistry.shared.zoom(id) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window id and toggle native macOS full screen on its on-screen window. The window must be
    /// open; a closed window errors. The control half of the View ▸ Toggle Full Screen menu item / the green
    /// traffic-light button — drives the same `NSWindow.toggleFullScreen` as `WindowRegistry.fullscreen`.
    func windowFullscreen(_ target: String?) -> ControlResponse {
        return resolver.resolveWindowID(target) { id in
            guard WindowRegistry.shared.fullscreen(id) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window id and minimize it to the Dock, or restore it, per the mode. The window must be
    /// open; a closed window errors, as does one in native full screen (AppKit no-ops `miniaturize` there,
    /// so reporting ok would be a lie). The control half of ⌘M / the yellow traffic-light button / the
    /// Minimize title-bar double-click action.
    ///
    /// Miniaturize and deminiaturize are ANIMATED, so `isMiniaturized` lags the call — without the settle
    /// poll the `defer`-ed window-cache refresh would capture the OLD value and the very next
    /// `window.list` would report the state the caller just changed away from.
    func windowMinimize(_ target: String?, mode: ControlToggleMode) async -> ControlResponse {
        switch resolver.resolveWindowID(target) {
        case .failure(let response): return response
        case .success(let id):
            switch WindowRegistry.shared.minimize(id, mode: mode) {
            case .notOpen:
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            case .fullScreen:
                return ControlResponse(ok: false,
                                       error: "cannot minimize a full-screen window — window.fullscreen it first")
            case .applied(let desired):
                await pollUntil { WindowRegistry.shared.isMinimized(id) == desired }
                if desired { handOffFrontmost(from: id) }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
        }
    }

    /// After parking the FRONTMOST window, point `frontmostWindowID` at a window the user can still see.
    ///
    /// `activeWindowID` only falls back when the frontmost window's STORE is gone (i.e. closed), and a
    /// minimized window keeps its store — so without this every untargeted command (`tree`, `session.new`,
    /// `quick`, the palette, the menu bar) keeps routing into a window sitting in the Dock. AppKit keys
    /// another window on a minimize only while the APP is active, so a script parking windows in the
    /// background never gets that handoff; when AppKit DID hand off, `reportFrontmost` already moved the
    /// id and the guard below skips. With every open window minimized there is nothing to hand to, so the
    /// pointer stays put rather than being cleared.
    private func handOffFrontmost(from id: WindowInfo.ID) {
        guard library.frontmostWindowID == id else { return }
        guard let next = library.openIDs().first(where: { $0 != id && !WindowRegistry.shared.isMinimized($0) })
        else { return }
        takeFrontmost(next)
    }

    /// Make `id` the logical frontmost window, the way `WindowAccessor.reportFrontmost` does on the GUI
    /// path: record it, persist the index, and reconcile the auto-hidden sidebars.
    ///
    /// The control channel needs its own path because `reportFrontmost` fires on `didBecomeKey`, which
    /// AppKit does not deliver while the app is inactive — exactly when a script is driving. Without the
    /// reconcile the window that just became visible keeps its sidebar collapsed until the user next
    /// activates agterm. Idempotent, and the reconcile resolves through `activeWindowID`, which returns
    /// the id assigned just above.
    private func takeFrontmost(_ id: WindowInfo.ID) {
        guard library.frontmostWindowID != id else { return }
        library.frontmostWindowID = id
        library.saveIndex()
        if GhosttyApp.shared.autoHideSidebarInactiveWindows { library.applyInactiveWindowSidebarHiding() }
    }

    /// Resolve a window id and rename it (the name lives in the index). Requires a name. Returns the id.
    func windowRename(_ target: String?, name: String) -> ControlResponse {
        return resolver.resolveWindowID(target) { id in
            library.renameWindow(id, to: name)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Resolve a window id and delete it, honoring keep-at-least-one (an error instead of the GUI
    /// confirm). Closes its on-screen window first if open. Returns the id.
    func windowDelete(_ target: String?) -> ControlResponse {
        return resolver.resolveWindowID(target) { id in
            guard library.canRemoveWindow else {
                return ControlResponse(ok: false, error: "cannot delete last window")
            }
            WindowRegistry.shared.close(id)
            library.removeWindow(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
