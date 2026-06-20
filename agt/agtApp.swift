import agtCore
import AppKit
import SwiftUI

@main
struct agtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @Environment(\.openWindow) private var openWindow

    @State private var library: WindowLibrary
    @State private var actions: AppActions
    @State private var palette = PaletteController()
    @State private var sessionSwitcher: SessionSwitcher
    @State private var settingsModel: SettingsModel
    @State private var controlServer: ControlServer

    /// The plain `WindowGroup`'s scene id, used by `openWindow(id:)` to spawn additional windows.
    private static let windowGroupID = "terminal"

    init() {
        let library = agtApp.restoredLibrary()
        _library = State(initialValue: library)
        let actions = AppActions(library: library)
        _actions = State(initialValue: actions)
        _controlServer = State(initialValue: ControlServer(library: library, actions: actions))
        _sessionSwitcher = State(initialValue: SessionSwitcher(library: library))
        // settings persist alongside the workspace snapshot (same AGT_STATE_DIR override).
        let settingsStore = ProcessInfo.processInfo.environment["AGT_STATE_DIR"]
            .map { SettingsStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? SettingsStore()
        _settingsModel = State(initialValue: SettingsModel(library: library, settingsStore: settingsStore))
    }

    var body: some Scene {
        // a plain WindowGroup: it auto-opens one window at launch and one per `openWindow(id:)`.
        // (A value-based `WindowGroup(for:)` does NOT auto-open at launch when SwiftUI window
        // restoration is off, so it can't bootstrap the first window.) `WindowLibrary` is the single
        // source of truth for the open-set: each appearing window claims the next open id from the
        // library's claim queue (Task 0 dedup-by-id); a window beyond the open set dismisses itself.
        WindowGroup(id: Self.windowGroupID) {
            ContentView(
                library: library,
                makeSurface: { Self.makeSurface(for: $0, store: $1, env: surfaceEnv(for: $0)) },
                makeSplitSurface: { Self.makeSplitSurface(for: $0, store: $1, env: surfaceEnv(for: $0)) },
                makeOverlaySurface: { Self.makeOverlaySurface(for: $0, store: $1, env: surfaceEnv(for: $0)) },
                quickTerminalEnv: { quickTerminalEnv(for: $0) },
                actions: actions,
                palette: palette,
                sessionSwitcher: sessionSwitcher
            )
                .frame(minWidth: 640, minHeight: 400)
                .task {
                    appDelegate.library = library
                    // give the action hub a window opener (the scene's `openWindow` is only reachable
                    // here) so the cross-window reveal can reopen a banner-clicked closed window, and a
                    // control-socket window.new/window.select can open one: raise it if it's already
                    // on-screen, else claim its id + spawn a new window. Installed BEFORE the control
                    // server starts so an early socket command never finds it nil (returns ok with no
                    // window opened).
                    actions.openWindow = { id in
                        if WindowRegistry.shared.raise(id) { return }
                        library.enqueueClaim(id)
                        openWindow(id: Self.windowGroupID)
                    }
                    // start the control channel (idempotent) and hand the delegate a
                    // reference so it can stop + unlink the socket on terminate.
                    appDelegate.controlServer = controlServer
                    controlServer.start()
                    // the quick terminal is per-window now: each WindowContentView owns its own
                    // controller and binds its own cwdProvider to that window's active session.
                    // install the Ctrl-Tab session-switcher key monitors (idempotent).
                    sessionSwitcher.start()
                    // register the notification delegate + request authorization (idempotent), and
                    // hand it the action hub + library so a banner click can navigate to the firing
                    // pane and the capture side can stamp the firing window id into the identity.
                    NotificationManager.shared.actions = actions
                    NotificationManager.shared.library = library
                    NotificationManager.shared.start()
                    // reopen every window that was open at quit. SwiftUI auto-opened one window
                    // (this one) at launch, which claimed the launch id; open one more per remaining
                    // open id. runs once (the .task fires per window) via the library latch.
                    reopenWindows()
                    appDelegate.scheduleRestoredWindowReconciliation(reason: "scene-task")
                }
        }
        // chromeless: no system title bar (the traffic lights float over our custom titlebar row in
        // ContentView), so there's no empty title-bar strip above our header.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            // File: replace the default "New" group with all of agt's creation/management actions,
            // grouped by entity into three sections — Window, then Workspace, then Session. The
            // system Close / Close All commands stay below in their own group.
            CommandGroup(replacing: .newItem) {
                // Window: create/open/rename/delete the top-level window bundles. Open Window lists
                // the library with a checkmark on already-open ones (picking a closed one opens it,
                // an open one raises it). Delete is disabled with one window left (keep-at-least-one).
                Button("New Window") { actions.newWindow() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Menu("Open Window") {
                    ForEach(library.windows) { window in
                        Button {
                            actions.openWindow(window.id)
                        } label: {
                            if library.isOpen(window.id) {
                                Label(window.name, systemImage: "checkmark")
                            } else {
                                Text(window.name)
                            }
                        }
                    }
                }
                Button("Rename Window…") { actions.renameActiveWindow() }
                Button("Delete Window") { actions.deleteActiveWindow() }
                    .disabled(!library.canRemoveWindow)

                Divider()
                // Workspace.
                Button("New Workspace") { actions.newWorkspace() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Rename Workspace") { actions.renameActiveWorkspace() }
                    .disabled(library.activeStore?.currentWorkspaceID == nil)
                Button("Delete Workspace") { actions.deleteActiveWorkspace() }
                    .disabled(library.activeStore?.canRemoveWorkspace != true)

                Divider()
                // Session. Open Directory… opens a new session rooted at a chosen folder; Close
                // Session is terminal-style ⌘W (closes the active session, or the window when none).
                Button("New Session") { actions.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Directory…") { actions.openDirectory() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Rename Session") { actions.renameActiveSession() }
                    .disabled(library.activeStore?.activeSession == nil)
                Button("Close Session") {
                    if library.activeStore?.activeSession != nil { actions.closeActiveSession() }
                    else { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            // View: font zoom (drives ghostty on the focused terminal), the status-bar toggle, and
            // split / quick terminal / palettes. The menu reserves an icon column because the system
            // "Enter Full Screen" item has an icon, so every custom item carries an SF Symbol too —
            // otherwise they render as blank, indented slots.
            CommandGroup(after: .toolbar) {
                Button { actions.increaseFontSize() } label: { Label("Increase Font Size", systemImage: "textformat.size.larger") }
                    .keyboardShortcut("+", modifiers: .command)
                Button { actions.decreaseFontSize() } label: { Label("Decrease Font Size", systemImage: "textformat.size.smaller") }
                    .keyboardShortcut("-", modifiers: .command)
                Button { actions.resetFontSize() } label: { Label("Actual Size", systemImage: "textformat.size") }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button { actions.toggleSplit() } label: {
                    Label(library.activeStore?.activeSession?.isSplit == true ? "Hide Split" : "Split Right", systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(library.activeStore?.activeSession == nil)
                Button { actions.toggleQuickTerminal() } label: { Label("Quick Terminal", systemImage: "terminal") }
                    .keyboardShortcut("`", modifiers: .control)
                Button { palette.toggle(.sessions) } label: { Label("Go to Session", systemImage: "rectangle.stack") }
                    .keyboardShortcut("p", modifiers: .control)
                Button { palette.toggle(.actions) } label: { Label("Command Palette", systemImage: "command") }
                    .keyboardShortcut("p", modifiers: [.control, .shift])
            }
        }

        Settings {
            SettingsView(model: settingsModel)
        }
    }

    /// Builds the app-global window library rooted at the state directory. The library's bootstrap
    /// runs migration/recovery (legacy `workspaces.json` → one window, else seed) so the resulting
    /// window set is always valid and non-empty. UI tests pass `AGT_STATE_DIR` to isolate persistence
    /// in a temp dir so a run never touches the user's real state.
    @MainActor
    private static func restoredLibrary() -> WindowLibrary {
        ProcessInfo.processInfo.environment["AGT_STATE_DIR"]
            .map { WindowLibrary(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? WindowLibrary()
    }

    /// Opens the additional windows that were open at quit. SwiftUI auto-opened one window at launch
    /// (it claimed the launch id), so this opens one more per remaining open id. Runs once via the
    /// library latch (`consumeReopen` seeds the claim queue and returns the extra-window count).
    @MainActor
    private func reopenWindows() {
        let extra = library.consumeReopen()
        for _ in 0..<extra { openWindow(id: Self.windowGroupID) }
    }

    /// Surface factory: creates a libghostty-backed view for the session, spawning
    /// a login shell in the session's initial working directory. On shell exit the
    /// view calls back to close the owning session in the store.
    @MainActor
    private static func makeSurface(for session: Session, store: AppStore, env: [String: String]) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: session.initialCwd, fontSize: session.fontSize.map(Float.init), env: env)
        view.session = session
        let sessionID = session.id
        view.onExit = { store.closeSession(sessionID) }
        view.onFocusChange = { focused in
            guard focused else { return }
            store.session(withID: sessionID)?.splitFocused = false
            // focusing a pane means you've seen the session: clear the badge and any delivered banners.
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        view.onFontSizeChange = { store.setFontSize(sessionID, $0) }
        return view
    }

    /// Split-pane surface factory: a second independent login shell in the session's
    /// current directory. Deliberately NOT wired to the session (no `view.session`) so its
    /// PWD reports don't clobber the session's cwd, and on shell exit it closes just
    /// the split (hide + teardown), not the whole session.
    @MainActor
    private static func makeSplitSurface(for session: Session, store: AppStore, env: [String: String]) -> GhosttySurfaceView {
        // seed the split from the session's font size so it matches the primary; its own
        // cmd +/- changes aren't persisted (the split re-spawns fresh on restore). It inherits the
        // parent session's window/workspace/session ids in the env.
        let view = GhosttySurfaceView(workingDirectory: session.effectiveCwd, fontSize: session.fontSize.map(Float.init), env: env)
        let sessionID = session.id
        view.onExit = { store.closeSplit(sessionID) }
        view.onFocusChange = { focused in
            guard focused else { return }
            store.session(withID: sessionID)?.splitFocused = true
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        return view
    }

    /// Overlay-terminal surface factory: an ephemeral surface running the session's `overlayCommand`
    /// as its process in `overlayCwd` (default the session's current dir). Like the split, it is NOT
    /// wired to the session (no `view.session`), so its PWD reports don't clobber the session's
    /// cwd. When the command exits, the surface's process-exit fires `onExit` → `closeOverlay`,
    /// which tears the surface down and hides the overlay — so the program's exit makes it vanish.
    @MainActor
    private static func makeOverlaySurface(for session: Session, store: AppStore, env: [String: String]) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: session.overlayCwd ?? session.effectiveCwd,
                                      fontSize: session.fontSize.map(Float.init), command: session.overlayCommand,
                                      waitAfterCommand: session.overlayWait, autoFocus: true, env: env)
        let sessionID = session.id
        view.onExit = { store.closeOverlay(sessionID) }
        return view
    }

    /// The `AGT_*` environment a tree surface (main / split / overlay) exposes to its spawned shell.
    /// The window id comes from the open store that owns the session (split/overlay inherit it via
    /// the same session); the workspace from the session's owning workspace; `AGT_SOCKET` is the path
    /// `ControlServer` will bind (resolved at init, so a launch-window shell that materializes before
    /// `start()` binds still sees it), honoring a test's `AGT_CONTROL_SOCKET` override.
    @MainActor
    private func surfaceEnv(for session: Session) -> [String: String] {
        var env = ["AGT_ENABLED": "1", "AGT_SESSION_ID": session.id.uuidString,
                   "AGT_SOCKET": controlServer.resolvedSocketPath]
        if let windowID = library.windowID(forSession: session.id) {
            env["AGT_WINDOW_ID"] = windowID.uuidString
            if let workspace = library.store(for: windowID)?.workspace(forSession: session.id) {
                env["AGT_WORKSPACE_ID"] = workspace.id.uuidString
            }
        }
        return env
    }

    /// The `AGT_*` environment a window's quick terminal exposes — scratch, not in the tree, so it
    /// carries only `AGT_ENABLED`, `AGT_WINDOW_ID`, and `AGT_SOCKET` (no workspace/session ids).
    @MainActor
    func quickTerminalEnv(for windowID: WindowInfo.ID) -> [String: String] {
        ["AGT_ENABLED": "1", "AGT_WINDOW_ID": windowID.uuidString,
         "AGT_SOCKET": controlServer.resolvedSocketPath]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app-global window library, handed over once the scene appears so the delegate can
    /// flush every open window's state on terminate.
    var library: WindowLibrary?

    /// The control channel, handed over once the scene appears so the delegate can
    /// stop the listener and unlink the socket on terminate.
    var controlServer: ControlServer?

    private var restoreObserver: NSObjectProtocol?
    private var scheduledReconciliationReasons: Set<String> = []

    func applicationWillFinishLaunching(_: Notification) {
        // a Debug app launched from DerivedData (ad-hoc signed) never hands the Dock a
        // non-default tile icon via the usual runtime path. set it explicitly. load the
        // artwork straight from the compiled asset catalog rather than via
        // NSWorkspace.icon(forFile:), whose Icon Services cache is keyed by bundle path
        // and the DerivedData path is reused across rebuilds, so it serves a stale tile.
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
        restoreObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishRestoringWindowsNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRestoredWindowReconciliation(reason: "did-finish-restoring")
            }
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        if ContentView.isUITestLaunch {
            scheduleUITestWindowActivationRetries()
        } else {
            NSApp.activate()
        }
        // Boot libghostty: init, config, app_new, 120fps tick.
        _ = GhosttyApp.shared
        scheduleRestoredWindowReconciliation(reason: "did-finish-launching")
    }

    func scheduleUITestWindowActivationRetries() {
        let delays: [TimeInterval] = [0, 0.1, 0.3, 0.6, 1.0, 1.5, 2.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.bringUITestWindowsForward()
            }
        }
    }

    /// On macOS 15+ a SwiftUI WindowGroup app launched by another process (XCUITest, launchd) often
    /// never auto-presents its window (FB11763863): the dock icon shows but no window appears and the
    /// scene's `.task`/`.onAppear` never fire. A reopen event — what a dock click sends — creates it.
    /// Fire that reopen once when no real window exists, then bring whatever windows appear forward.
    private func bringUITestWindowsForward() {
        if !didForceReopen, NSApp.windows.allSatisfy({ $0 is NSPanel }) {
            didForceReopen = true
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        // present the launch window ONCE (FB11763863), then latch off. The windows are
        // isRestorable=false so they won't re-minimize, and continuing to re-front every tick would
        // oscillate the key window and fight a deliberate window.select (which made multi-window control
        // tests flaky). A runtime window.new presents via its own per-window retry instead.
        guard !didPresentUITestWindow else { return }
        NSApp.activate()
        for window in NSApp.windows where window.canBecomeKey {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            didPresentUITestWindow = true
        }
    }

    /// One-shot latch: true once the launch UI-test window has been presented, so the activation retry
    /// schedule stops re-fronting (which would oscillate the key window).
    private var didPresentUITestWindow = false

    private var didForceReopen = false

    /// SwiftUI/AppKit can restore stale plain-WindowGroup windows before the app's own
    /// `WindowLibrary` reopen pass has finished. Closing them from inside the stray view races that
    /// restoration machinery, so reconcile after AppKit posts its restoration-complete notification
    /// and after the real windows have had time to register through `TitleProbeView`.
    func scheduleRestoredWindowReconciliation(reason: String) {
        guard scheduledReconciliationReasons.insert(reason).inserted else { return }
        for delay in [0, 0.05, 0.15, 0.35, 0.7, 1.2, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.closeExcessRestoredWindows(reason: reason)
                }
            }
        }
    }

    private func closeExcessRestoredWindows(reason: String) {
        guard let library else { return }
        let expected = library.openIDs().count
        guard expected > 0, WindowRegistry.shared.registeredCount >= expected else { return }

        let extras = NSApp.windows.filter { window in
            isTerminalWindowGroupWindow(window) && !WindowRegistry.shared.contains(window)
        }
        guard !extras.isEmpty else { return }

        NSLog("window reconcile: closing %d stale restored window(s) (expected %d, total %d, reason %@)",
              extras.count, expected, NSApp.windows.count, reason)
        for window in extras {
            closeRestoredStray(window)
        }
    }

    private func isTerminalWindowGroupWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue.hasPrefix("terminal-AppWindow-") == true { return true }

        let className = NSStringFromClass(type(of: window))
        return className.contains("SwiftUI")
            && window.title == "agt"
            && window.styleMask.contains(.titled)
            && window.canBecomeKey
    }

    private func closeRestoredStray(_ window: NSWindow) {
        window.isRestorable = false
        window.restorationClass = nil
        window.disableSnapshotRestoration()
        window.invalidateRestorableState()
        window.close()
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.orderOut(nil)
            window.close()
        }
    }

    func applicationWillTerminate(_: Notification) {
        controlServer?.stop()
        // mark terminating so the per-window willClose close-reporting can't zero the open-set as each
        // window tears down during quit — the set must survive for the next launch's reopen-all.
        library?.isTerminating = true
        // flush every open window's store (per-window cwd changes since the last structural mutation
        // aren't auto-persisted) and the index. replaces the single-store save.
        library?.saveAllOpen()
        library?.saveIndex()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // key termination off the model open-set, NOT AppKit's transient window count: closing one
        // window (or a re-render that briefly drops the surviving NSWindow) can leave a momentary
        // zero-window state while the library still has an open window, and quitting there would kill
        // the app (and the control server) mid-session. Quit only when no window is open in the model.
        guard let library else { return true }
        return library.openIDs().isEmpty
    }
}
