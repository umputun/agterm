import AppKit
import Foundation
import agtermCore

/// `ControlServer` window-command action arms — create, list, select, close, resize, move, zoom, rename and
/// delete on-screen windows via `WindowRegistry` + `WindowLibrary`. Split out for the swiftlint size limit.
extension ControlServer {
    /// Create a new window and open it through the action hub's opener (the `enqueueClaim` + `openWindow(id:)`
    /// path the menu uses); returns the new window id. `minimized` parks it in the Dock AFTER creating, so a
    /// script building project windows is left on one it can still see. Bounded-polls for the NSWindow to
    /// ATTACH before replying, so an immediately following `window.resize`/`move`/`zoom` finds it registered:
    /// the poll must gate on `WindowRegistry.isRegistered`, NOT `library.isOpen`, since `newWindow()` loads
    /// the store synchronously (so `isOpen` proves nothing) while the NSWindow attaches only after SwiftUI
    /// resolves the store and runs a second render pass. Fire-and-forget like the other polls — a window that
    /// never renders times out and the command still replies ok.
    func windowNew(name: String?, minimized: Bool) async -> ControlResponse {
        let info = library.newWindow(name: trimmed(name))
        actions.openWindow?(info.id)
        await pollUntil { WindowRegistry.shared.isRegistered(info.id) }
        if minimized { await park(info.id) }
        return ControlResponse(ok: true, result: ControlResult(id: info.id.uuidString))
    }

    /// Park a freshly created window: minimize it, wait out the animation, and hand frontmost back.
    /// The wait BEFORE minimizing is load-bearing: `WindowAccessor` presents the window on attach both
    /// synchronously and again on the next main-queue turn, and that second present deminiaturizes — the
    /// sleep yields the main actor long enough for the queued present to drain first. A window that never
    /// rendered arrives here unregistered (the attach poll is bounded and fire-and-forget) and `minimize`
    /// answers `.notOpen`; LOG that rather than swallow it — the window is then still on screen holding focus
    /// while the caller was told it was parked. Frontmost is handed off only when the park applied.
    private func park(_ id: WindowInfo.ID) async {
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard case .applied = WindowRegistry.shared.minimize(id, mode: .on) else {
            log("window.new --minimized: \(id) never attached in time, left presented")
            return
        }
        await pollUntil { WindowRegistry.shared.isMinimized(id) }
        handOffFrontmost(from: id)
    }

    /// Project the window library into `window.list`: every window with its open + frontmost (active) flags.
    func buildWindowList() -> [ControlWindowNode] {
        library.controlWindowNodes(geometry: { WindowRegistry.shared.geometry(for: $0) },
                                   flags: { WindowRegistry.shared.windowFlags(for: $0) })
    }

    func windowList() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(windows: buildWindowList()))
    }

    /// Resolve a window id and surface it: raise an already-open window, or open a closed one (the action
    /// hub's opener claims its id + spawns it). Returns the window id. Selecting also calls `takeFrontmost`
    /// EXPLICITLY — `raise` alone leaves `frontmostWindowID` stale, so a background `window select` would
    /// reply ok while untargeted commands kept routing into the previously-active window.
    /// Bounded-polls for BOTH the store and the NSWindow before replying, so a script can immediately target
    /// it (`tree --window <id>`, a frame command) without racing. `library.isOpen` alone reports only that the
    /// store loaded — what `tree --window` needs, so it stays — but flips a render pass before the NSWindow
    /// exists, so a frame command right after would hit `window not open`; an already-attached window
    /// satisfies both on the first iteration.
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

    /// Resolve a window id and close its on-screen window (the registry's `performClose` runs the standard
    /// teardown + `closeWindow` path, asynchronously). Bounded-polls for the library to mark it closed, so an
    /// immediate follow-up sees it closed. An already-closed window still reports ok. Returns the id.
    func windowClose(_ target: String?) async -> ControlResponse {
        switch resolver.resolveWindowID(target) {
        case .failure(let response): return response
        case .success(let id):
            // close the registered window (driving willClose teardown), then a fallback for one not yet
            // registered (window.close racing window.new) or an unflipped flag: drop the store to mark it closed.
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

    /// Bounded poll for an asynchronous window lifecycle transition: the SwiftUI scene opens/closes off this
    /// dispatch, so the library flag flips a beat later. 30 × 0.05 s (≈1.5 s) of `Task.sleep` yields the main
    /// actor between checks, never blocking the accept loop. Returns when `done()` holds or the budget is
    /// spent — the caller replies ok either way, so the poll only narrows the race.
    private func pollUntil(_ done: () -> Bool) async {
        for _ in 0..<30 {
            if done() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Resize the resolved window to `width` x `height` points (frame size). Open windows only; a closed one
    /// errors. Control-native — no GUI surface, the native title bar already drags-to-resize.
    func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse {
        return resolver.resolveWindowID(target) { id in
            guard WindowRegistry.shared.resize(id, width: width, height: height) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Move the resolved window's top-left corner to (`x`, `y`) points in the global top-left space (origin =
    /// the primary display's top-left, spanning all displays). Open only. Control-native (no GUI surface).
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

    /// Zoom (maximize-to-screen toggle) the resolved window; a closed one errors. The control half of the
    /// double-click-header gesture — a plain green-button click does native full screen, not zoom.
    func windowZoom(_ target: String?) -> ControlResponse {
        return resolver.resolveWindowID(target) { id in
            guard WindowRegistry.shared.zoom(id) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Toggle native macOS full screen on the resolved window; a closed one errors. The control half of
    /// ⌃⌘F, AppKit's own View ▸ Enter/Exit Full Screen item, and the green traffic-light button.
    func windowFullscreen(_ target: String?) -> ControlResponse {
        return resolver.resolveWindowID(target) { id in
            guard WindowRegistry.shared.fullscreen(id) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Minimize the resolved window to the Dock, or restore it, per the mode. A closed window errors, as does
    /// one in native full screen (AppKit no-ops `miniaturize` there, so ok would be a lie). The control half
    /// of ⌘M / the yellow traffic-light button / the Minimize title-bar double-click. Miniaturize and
    /// deminiaturize are ANIMATED, so `isMiniaturized` lags the call: without the settle poll the `defer`-ed
    /// window-cache refresh captures the OLD value and the next `window.list` reports the state the caller
    /// just changed away from.
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
    /// `activeWindowID` falls back only when the frontmost window's STORE is gone, and a minimized window
    /// keeps its store — so without this every untargeted command (`tree`, `session.new`, `quick`, the
    /// palette, the menu bar) keeps routing into a window sitting in the Dock. AppKit keys another window on
    /// a minimize only while the APP is active, so a script parking windows in the background never gets that
    /// handoff; when AppKit DID hand off, `reportFrontmost` already moved the id and the guard below skips.
    /// With every open window minimized there is nothing to hand to, so the pointer stays.
    private func handOffFrontmost(from id: WindowInfo.ID) {
        guard library.frontmostWindowID == id else { return }
        guard let next = library.openIDs().first(where: { $0 != id && !WindowRegistry.shared.isMinimized($0) })
        else { return }
        takeFrontmost(next)
    }

    /// Make `id` the logical frontmost window the way `WindowAccessor.reportFrontmost` does on the GUI path:
    /// record it, persist the index, reconcile the auto-hidden sidebars. Shared by every control path that
    /// presents a window — `window.select`, the minimize hand-off, `pick.open --follow`. The control channel
    /// needs its own path because `reportFrontmost` fires on `didBecomeKey`, which AppKit does not deliver
    /// while the app is inactive — exactly when a script is driving; without the reconcile the newly visible
    /// window keeps its sidebar collapsed until the user next activates agterm. Idempotent, and the reconcile
    /// resolves through `activeWindowID`, which returns the id assigned above.
    func takeFrontmost(_ id: WindowInfo.ID) {
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

    /// Resolve a window id and delete it, honoring keep-at-least-one (an error instead of the GUI confirm).
    /// Closes its on-screen window first if open. Returns the id.
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
