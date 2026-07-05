import AppKit
import Foundation
import agtermCore

/// `ControlServer` window-command action arms — create, list, select, close, resize, move, zoom, rename,
/// and delete on-screen windows via `WindowRegistry` + the `WindowLibrary`. Split out of
/// `ControlServer.swift` for the swiftlint size limit.
extension ControlServer {
    /// Create a new window (library) and open its on-screen window via the action hub's window opener
    /// (the same `enqueueClaim` + `openWindow(id:)` path the menu uses). Returns the new window id.
    func windowNew(name: String?) -> ControlResponse {
        let info = library.newWindow(name: trimmed(name))
        actions.openWindow?(info.id)
        return ControlResponse(ok: true, result: ControlResult(id: info.id.uuidString))
    }

    /// Project the window library into the `window.list` response: every window with its open flag and
    /// whether it is the frontmost (active) window.
    func buildWindowList() -> [ControlWindowNode] {
        library.controlWindowNodes()
    }

    func windowList() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(windows: buildWindowList()))
    }

    /// Resolve a window id and surface it: raise an already-open window, or open a closed one (the
    /// action hub's opener claims its id + spawns the window). A closed window's store loads only when
    /// its SwiftUI window appears, so this bounded-polls for it to open before replying — a script can
    /// then immediately target it (`tree --window <id>`) without racing the window appearing. Returns
    /// the window id.
    func windowSelect(_ target: String?) async -> ControlResponse {
        switch resolver.resolveWindowID(target) {
        case .failure(let response): return response
        case .success(let id):
            actions.openWindow?(id)
            await pollUntil { self.library.isOpen(id) }
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
    /// open; a closed window errors. The control half of the double-click-header gesture / the green zoom
    /// button — drives the same `NSWindow.zoom` as `WindowRegistry.zoom`.
    func windowZoom(_ target: String?) -> ControlResponse {
        return resolver.resolveWindowID(target) { id in
            guard WindowRegistry.shared.zoom(id) else {
                return ControlResponse(ok: false, error: "window not open — window.select it first")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
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
