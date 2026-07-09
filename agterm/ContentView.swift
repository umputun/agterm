import agtermCore
import AppKit
import SwiftUI

/// Top-level per-window entry point: resolves this window's `AppStore` from the
/// `WindowLibrary` claim queue on appear, then hands off to `WindowContentView`
/// for the actual layout (a stray restored window with no id closes itself via
/// `StrayWindowCloser`).
///
/// The detail pane (in `WindowContentView`) is an EAGER deck — every session's
/// `TerminalView` is mounted at once and switching flips visibility/`isActive`,
/// never an `.id(session.id)` re-host (which would invalidate the Metal drawable
/// and flicker), so the session-owned surfaces survive switching. The sidebar is
/// an AppKit `NSOutlineView` (`WorkspaceSidebar`) for native cross-workspace
/// drag-and-drop; the bottom bar holds a workspace button and a session menu
/// (New Session / Open Directory…).
struct ContentView: View {
    let library: WindowLibrary
    let makeSurface: (Session, AppStore) -> GhosttySurfaceView
    let makeSplitSurface: (Session, AppStore) -> GhosttySurfaceView
    let makeOverlaySurface: (Session, AppStore) -> GhosttySurfaceView
    let makeScratchSurface: (Session, AppStore) -> GhosttySurfaceView
    /// The `AGTERM_*` environment a window's quick terminal exposes (ENABLED + WINDOW_ID + SOCKET),
    /// resolved per window id. Threaded down so `WindowContentView` can bind its quick terminal's
    /// `envProvider` with its own window id.
    let quickTerminalEnv: (WindowInfo.ID) -> [String: String]
    let actions: AppActions
    let palette: PaletteController
    let sessionSwitcher: SessionSwitcher

    /// The resolved per-window store (lazy-loaded / created on appear). `nil` until resolved, or for
    /// a stray restored id with no library entry.
    @State private var store: AppStore?
    /// The id this window settled on (created for a nil `windowID`), used for frontmost/close
    /// reporting and the frame autosave name.
    @State private var resolvedID: WindowInfo.ID?

    /// Set when this window is a SwiftUI-restored stray with no library id to claim. The stray branch
    /// then closes the NSWindow via AppKit — SwiftUI's `@Environment(\.dismiss)` is unreliable for
    /// restored WindowGroup windows (they linger on screen as empty windows).
    @State private var isStray = false

    /// True when running under an isolated XCUITest (`AGTERM_STATE_DIR` set AND the
    /// `AGTERM_UITEST_FORCE_SIDEBAR_VISIBLE` env sentinel present). Gates the FB11763863 window-present
    /// workaround. The custom sidebar is always visible, so this no longer forces sidebar state; the
    /// env var keeps its historical name.
    static var isUITestLaunch: Bool {
        let process = ProcessInfo.processInfo
        // the sentinel rides launch ENVIRONMENT, not launch arguments: a process-launched SwiftUI
        // WindowGroup app fails to present its window under some launch-arg patterns on macOS 15+
        // (FB11763863). Env sidesteps that.
        return process.environment["AGTERM_STATE_DIR"] != nil
            && process.environment["AGTERM_UITEST_FORCE_SIDEBAR_VISIBLE"] != nil
    }

    /// Close confirmation is normally suppressed in UI tests so unrelated close flows cannot hang on a
    /// modal alert. One focused regression test opts back in without disabling the other UI-test guards.
    static var shouldBypassCloseConfirmation: Bool {
        isUITestLaunch && ProcessInfo.processInfo.environment["AGTERM_UITEST_ALLOW_CLOSE_CONFIRMATION"] == nil
    }

    var body: some View {
        Group {
            if let store, let resolvedID {
                WindowContentView(
                    windowID: resolvedID,
                    store: store,
                    library: library,
                    makeSurface: { makeSurface($0, store) },
                    makeSplitSurface: { makeSplitSurface($0, store) },
                    makeOverlaySurface: { makeOverlaySurface($0, store) },
                    makeScratchSurface: { makeScratchSurface($0, store) },
                    quickTerminalEnv: quickTerminalEnv,
                    actions: actions,
                    palette: palette,
                    sessionSwitcher: sessionSwitcher
                )
            } else if isStray {
                // a SwiftUI-restored stray beyond the app's open set: close its NSWindow via AppKit.
                Color.clear.background(StrayWindowCloser())
            } else {
                // transient: resolveStore hasn't run yet (or is still resolving).
                Color.clear
            }
        }
        .onAppear(perform: resolveStore)
    }

    /// Resolves the window's store once on appear by claiming the next open window id from the
    /// library's queue (the scene is a plain `WindowGroup`, so a window has no presented id). The
    /// launch window claims the launch id, additional `openWindow()`-opened windows claim the rest in
    /// order. A window beyond the open set — a SwiftUI-restored extra (Task 0 dedup-by-id) — gets no
    /// id and dismisses itself, so stale restoration state can't pile up windows. Idempotent —
    /// re-running with an already-resolved store is a no-op.
    private func resolveStore() {
        guard store == nil, !isStray else { return }
        guard let id = claimWindowID(),
              let resolved = library.store(for: id) ?? library.loadStore(for: id) else {
            isStray = true
            return
        }
        store = resolved
        resolvedID = id
        // seed this freshly resolved store with the current auto-follow setting: the store is built
        // host-free in WindowLibrary and can't read SettingsModel, so the app target pushes it in here.
        actions.settingsModel?.applyAutoFollow(to: resolved)
        // reopening a window loads an @ObservationIgnored store, which the Dock badge's observation can't
        // see (symmetric to the willClose close poke) — recompute so a reopened window's unseen total counts.
        DockBadgeController.shared.refresh()
    }

    /// The window id this view adopts: normally the next id in the library's claim queue. If the
    /// queue is empty before the launch reopen-all has seeded it (the scene `.task` may not have run
    /// `consumeReopen()` when this `.onAppear` fires), adopt the launch id rather than dismissing the
    /// launch window — `adoptLaunchWindowID()` records it so the later `consumeReopen()` excludes it
    /// from the seeded queue (no second window claims it). Once the queue has been seeded
    /// (`hasReopened`), an empty queue genuinely means this is a SwiftUI-restored stray, so return nil
    /// and let the caller dismiss it.
    private func claimWindowID() -> WindowInfo.ID? {
        if let id = library.claimNextWindowID() { return id }
        return library.hasReopened ? nil : library.adoptLaunchWindowID()
    }
}

/// Closes a SwiftUI-restored stray `WindowGroup` window via AppKit. SwiftUI's `@Environment(\.dismiss)`
/// is unreliable for restored windows — they linger on screen as empty windows — so this reaches the
/// backing `NSWindow` and `close()`s it directly. It also clears `isRestorable` so SwiftUI stops
/// persisting + re-restoring this stray on the next launch.
private struct StrayWindowCloser: NSViewRepresentable {
    func makeNSView(context _: Context) -> ClosingView { ClosingView() }
    func updateNSView(_ view: ClosingView, context _: Context) { view.closeIfNeeded() }

    final class ClosingView: NSView {
        private weak var closingWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closeIfNeeded()
        }

        func closeIfNeeded() {
            guard let window, closingWindow !== window else { return }
            closingWindow = window
            window.isRestorable = false
            window.restorationClass = nil
            window.disableSnapshotRestoration()
            window.invalidateRestorableState()
            // defer past the current presentation/attach pass so the close lands cleanly.
            DispatchQueue.main.async { [weak window] in
                window?.close()
                DispatchQueue.main.async { [weak window] in
                    window?.orderOut(nil)
                    window?.close()
                }
            }
        }
    }
}
