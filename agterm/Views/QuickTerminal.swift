import agtermCore
import AppKit
import SwiftUI

/// The in-app quick terminal: a single scratch terminal shown as a centered overlay at 90% of
/// the window, on top of the sidebar and terminal. A toolbar button toggles it; clicking the
/// dimmed margin also hides it. Hiding keeps the shell alive — the surface is owned here, not by
/// the overlay view, so it survives the view being removed. Not persisted (fresh each launch).
///
/// Per window: each `WindowContentView` owns one and registers it in `QuickTerminalRegistry`
/// keyed by its window id, so the frontmost-window call sites (the menu/keybind, `AppActions`,
/// `ControlServer`) can reach the controller of the window the user is looking at. The owning view
/// binds `cwdProvider` so a freshly-spawned quick terminal opens in that window's active session's
/// directory (home when nothing is selected).
@MainActor @Observable
final class QuickTerminalController {
    /// Whether the overlay is shown. Observed, so `WindowContentView` shows/hides the overlay.
    private(set) var isVisible = false

    /// The long-lived quick-terminal surface, created lazily on first show and kept across
    /// hide/show so the shell survives. `@ObservationIgnored`: the overlay pulls it imperatively
    /// (like a session owns its surface), nothing in SwiftUI observes the view itself.
    @ObservationIgnored private var surfaceView: GhosttySurfaceView?

    /// The directory a freshly-created quick terminal spawns its shell in. Read once, when the
    /// surface is created, so the quick terminal keeps its own working directory afterwards.
    @ObservationIgnored var cwdProvider: () -> String = { FileManager.default.homeDirectoryForCurrentUser.path }

    /// The `AGTERM_*` environment a freshly-created quick terminal exposes to its shell (ENABLED +
    /// WINDOW_ID + SOCKET — scratch, so no workspace/session ids). Read once, when the surface is
    /// created. Set by the owning `WindowContentView` so the var carries this window's id.
    @ObservationIgnored var envProvider: () -> [String: String] = { [:] }

    /// Notes a keystroke in the quick terminal as user activity on the owning window's `AppStore`, so
    /// typing here resets that window's auto-follow idle timer (an idle fire must NOT change the selection
    /// behind the overlay while the user types). The controller is store-less, so `WindowContentView`
    /// supplies this; `surface()` forwards it to the surface's `onUserInput` (mirroring the overlay/scratch
    /// factories), which `destroySurface` nils on teardown.
    @ObservationIgnored var onUserInput: (() -> Void)?

    /// Toolbar-button action: show if hidden, hide if visible.
    func toggle() { isVisible.toggle() }

    func show() { isVisible = true }

    func hide() { isVisible = false }

    /// The existing quick-terminal surface, or nil — does NOT create one (unlike `surface()`), so
    /// a settings broadcast can reach it without spawning a shell.
    func currentSurface() -> GhosttySurfaceView? { surfaceView }

    /// The surface to render in the overlay, created on first use in the active cwd and reused
    /// afterwards. Recreated after the shell exits.
    func surface() -> GhosttySurfaceView {
        if let surfaceView { return surfaceView }
        let view = GhosttySurfaceView(workingDirectory: cwdProvider(), env: envProvider())
        view.onExit = { [weak self] in self?.handleShellExit() }
        view.onUserInput = onUserInput // note activity so typing here resets the window's auto-follow timer
        surfaceView = view
        return view
    }

    /// Re-assert first responder on the surface for a short window so focus lands once the
    /// overlay is on-window (a one-shot would race the overlay's layout).
    func focus(attempt: Int = 0) {
        if let surfaceView, let window = surfaceView.window {
            window.makeFirstResponder(surfaceView)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focus(attempt: attempt + 1)
        }
    }

    /// The quick-terminal shell exited: hide the overlay and tear down the surface so the next
    /// show spawns a fresh shell (the surface, not the overlay, owns the shell).
    private func handleShellExit() {
        isVisible = false
        surfaceView?.teardown()
        surfaceView = nil
    }
}

/// Hosts the quick-terminal surface in the overlay. Like `TerminalView`, it pulls the
/// long-lived surface from its owner (the per-window controller) rather than creating one, and
/// never frees it on dismantle — hiding the overlay must keep the shell alive.
struct QuickTerminalPane: NSViewRepresentable {
    let controller: QuickTerminalController

    func makeNSView(context _: Context) -> GhosttySurfaceView {
        let view = controller.surface()
        controller.focus()
        return view
    }

    func updateNSView(_: GhosttySurfaceView, context _: Context) {}

    static func dismantleNSView(_: GhosttySurfaceView, coordinator _: ()) {
        // no-op: the controller owns the surface so it survives hide/show.
    }
}

/// App-side bridge mapping a `WindowInfo.ID` to its window's `QuickTerminalController`. The
/// controller is a per-window instance owned by `WindowContentView` (which registers/unregisters
/// it on appear/close); the frontmost-window call sites resolve the controller to act on through
/// `controller(for: library.activeWindowID)`.
@MainActor
final class QuickTerminalRegistry {
    static let shared = QuickTerminalRegistry()
    private var controllers: [WindowInfo.ID: QuickTerminalController] = [:]

    private init() {}

    func register(_ id: WindowInfo.ID, controller: QuickTerminalController) {
        controllers[id] = controller
    }

    func unregister(_ id: WindowInfo.ID) {
        controllers[id] = nil
    }

    /// The quick-terminal controller for `id`, or nil when the window is closed/unknown.
    func controller(for id: WindowInfo.ID?) -> QuickTerminalController? {
        guard let id else { return nil }
        return controllers[id]
    }

    /// Every registered (open-window) controller — used by the settings broadcast to reach each
    /// window's quick-terminal surface.
    func allControllers() -> [QuickTerminalController] {
        Array(controllers.values)
    }
}
