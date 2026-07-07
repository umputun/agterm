import agtermCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app-global window library, handed over once the scene appears so the delegate can
    /// flush every open window's state on terminate.
    var library: WindowLibrary?

    /// The control channel, handed over once the scene appears so the delegate can
    /// stop the listener and unlink the socket on terminate.
    var controlServer: ControlServer?

    /// The custom-command key-monitor runner, handed over once the scene appears so the delegate can
    /// remove its `NSEvent` monitor and observer on terminate.
    var customCommandRunner: CustomCommandRunner?

    /// The settings model, handed over once the scene appears so the delegate can flush its pending
    /// debounced `settings.json` writes (opacity/blur, theme preview) on terminate.
    var settingsModel: SettingsModel?

    private var restoreObserver: NSObjectProtocol?
    private var scheduledReconciliationReasons: Set<String> = []

    func applicationWillFinishLaunching(_: Notification) {
        // agterm has its own multi-window model and does NOT support native window tabs; disabling
        // automatic tabbing removes AppKit's injected "Show Tab Bar" / "Show All Tabs" / "Move Tab to
        // New Window" menu items and the tab affordances. Must be set before any window is created.
        NSWindow.allowsAutomaticWindowTabbing = false
        // NOTE: do NOT set NSApp.applicationIconImage. The app icon is the adaptive Icon Composer
        // `AppIcon.icon`, which the system renders LIVE in the Dock with the current appearance
        // (light/dark/clear/tinted, Liquid Glass). applicationIconImage takes a STATIC NSImage, so
        // setting it (even from the compiled asset) freezes the Dock to one flat rendering and defeats
        // the adaptive icon. Let LaunchServices render the bundle icon. (The Dock unseen-count badge is
        // the modern `UNUserNotificationCenter.setBadgeCount` — see `DockBadgeController` — which renders
        // over the live adaptive icon without touching `applicationIconImage`.)
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
        // AppKit auto-adds its own "Enter Full Screen" item (Globe+F / ⌃⌘F) to the View menu for any
        // fullscreen-capable window, and RE-INJECTS it each time the menu opens. agterm ships its OWN
        // rebindable "Toggle Full Screen" item (so full screen is drivable from the keymap, action palette,
        // and control channel), so leaving AppKit's item renders a duplicate. Strip the native one
        // just-in-time whenever a menu begins tracking (the point AppKit re-injects it); a launch-time
        // one-shot does NOT stick because of the re-injection.
        AppDelegate.removeNativeFullScreenMenuItem()
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @objc private func menuBeganTracking(_: Notification) {
        MainActor.assumeIsolated { AppDelegate.removeNativeFullScreenMenuItem() }
    }

    /// Remove AppKit's auto-injected fullscreen menu item — the one whose action is `toggleFullScreen:`.
    /// agterm's own item uses a SwiftUI closure action (a different selector), so only the native item
    /// matches and our "Toggle Full Screen" is left intact. Finds the owning submenu by content rather than
    /// by the localized "View" title.
    @MainActor
    private static func removeNativeFullScreenMenuItem() {
        let selector = #selector(NSWindow.toggleFullScreen(_:))
        for topItem in NSApp.mainMenu?.items ?? [] {
            guard let submenu = topItem.submenu else { continue }
            for item in submenu.items where item.action == selector {
                submenu.removeItem(item)
            }
        }
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
            && window.title == "Agterm"
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

    /// Confirm a quit (menu Quit / ⌘Q) before the app tears down its windows — closing them ends every
    /// session's running shell with no undo, the same loss the workspace/window delete actions confirm.
    /// Reports the open-window and session counts in the prompt; proceeds without asking when nothing is
    /// open (the auto-quit after the last window closed) or under an XCUITest launch (a modal would hang
    /// the test's terminate).
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !ContentView.isUITestLaunch, let library else { return .terminateNow }
        let counts = library.openCounts()
        guard counts.windows > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Agterm?"
        alert.informativeText = QuitPrompt.message(windows: counts.windows, sessions: counts.sessions)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_: Notification) {
        controlServer?.stop()
        customCommandRunner?.stop()
        // clear the OS-level Dock badge — it outlives the process, and unseenCount is ephemeral, so a quit
        // with unseen > 0 would leave a stale count pinned on the Dock icon (the willClose refresh() poke
        // can't: isTerminating below makes closeWindow no-op, so the total recomputes unchanged).
        DockBadgeController.shared.clear()
        // mark terminating so the per-window willClose close-reporting can't zero the open-set as each
        // window tears down during quit — the set must survive for the next launch's reopen-all.
        library?.isTerminating = true
        // restore-running-command: capture each pane's live foreground command into the session fields
        // BEFORE the snapshot save below, so a restored pane can re-run it. Only when the feature is on;
        // a force-quit/crash skips this (sessions + cwd still restore from the debounced snapshot).
        if settingsModel?.settings.restoreRunningCommand == true, let library {
            captureForegroundCommands(library: library)
        }
        // flush every open window's store (per-window cwd changes since the last structural mutation
        // aren't auto-persisted) and the index. replaces the single-store save.
        library?.saveAllOpen()
        library?.saveIndex()
        // flush the settings model's pending debounced writes (a keyboard-driven opacity/blur change
        // holds a ~0.3s deferred save that no drag-end commit fires) so they survive ⌘Q.
        settingsModel?.flushPendingSaves()
    }

    /// Capture every open pane's foreground command (main + split) into its `Session` fields, so the
    /// snapshot save persists them for the next launch's restore. `ForegroundProcess` returns nil for a
    /// pane sitting at its shell prompt, so plain shells stay plain on restore.
    @MainActor
    private func captureForegroundCommands(library: WindowLibrary) {
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        for session in library.allOpenSessions() {
            if let view = session.surface as? GhosttySurfaceView {
                session.foregroundCommand = ForegroundProcess.command(for: view, shellBasename: shellBasename)
            }
            // only a SHOWN split is recreated on restore (the factory runs when isSplit is true), so
            // capturing a HIDDEN split's command would leave it stale to fire on the next manual ⌘D.
            // Gate on isSplit so capture and restore agree.
            if session.isSplit, let split = session.splitSurface as? GhosttySurfaceView {
                session.splitForegroundCommand = ForegroundProcess.command(for: split, shellBasename: shellBasename)
            }
        }
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
