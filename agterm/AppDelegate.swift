import agtermCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// App-global window library, set on scene appear; terminate flushes every window's state.
    var library: WindowLibrary?

    /// Control channel, set on scene appear; terminate stops the listener and unlinks the socket.
    var controlServer: ControlServer?

    /// Custom-command key-monitor runner, set on scene appear; terminate removes its monitor + observer.
    var customCommandRunner: CustomCommandRunner?

    /// Settings model, set on scene appear; terminate flushes its pending debounced `settings.json` writes.
    var settingsModel: SettingsModel?

    /// Action hub, set on scene appear so `application(_:open:)` can open a session at an `open -a` path.
    var actions: AppActions?

    /// Strongly retains the current Dock menu's target objects so nil-sender dispatch never depends on
    /// AppKit's target lifetime; replaced whenever the Dock asks for a fresh menu.
    var dockMenuActionTargets: [DockMenuActionTarget] = []

    /// Directories from `open -a agterm /path` not yet turned into sessions — queued until the frontmost
    /// store resolves, so the new session lands in the last-active window.
    private var pendingOpenDirectories: [String] = []

    private var restoreObserver: NSObjectProtocol?
    private var scheduledReconciliationReasons: Set<String> = []

    func applicationWillFinishLaunching(_: Notification) {
        // no native window tabs: this strips AppKit's injected "Show Tab Bar" / "Show All Tabs" / "Move Tab
        // to New Window" items and the tab affordances. Must be set before any window is created.
        NSWindow.allowsAutomaticWindowTabbing = false
        applyUITestAppearanceOverride()
        // do NOT set NSApp.applicationIconImage: the adaptive Icon Composer `AppIcon.icon` is rendered LIVE
        // per appearance (light/dark/clear/tinted, Liquid Glass), and a STATIC NSImage would freeze the Dock
        // to one flat rendering. The unseen badge draws over it via `UNUserNotificationCenter.setBadgeCount`.
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
        // libghostty is already booted: `SettingsModel.init` touches `GhosttyApp.shared` during App.init,
        // before NSApp exists. This keeps the dependency explicit ahead of the re-side below.
        _ = GhosttyApp.shared
        // then re-side the config to the launch appearance, while NSApp exists and no scene has mounted —
        // a dark launch otherwise strips the env, restore replay and command off every restored surface.
        GhosttyApp.shared.syncLaunchColorScheme()
        scheduleRestoredWindowReconciliation(reason: "did-finish-launching")
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        // SwiftUI defers its menu rebuild to the next app ACTIVATION, and that rebuild is what lets the
        // stock File ▸ Close claim ⌘W. Reconcile after it (async, once SwiftUI has rebuilt) and on every
        // keymap change, so a `keymap reload` takes effect on the chord immediately.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keymapChanged),
                                               name: .agtermKeymapChanged, object: nil)
        reconcileCloseSessionChord()
    }

    /// XCUITest-only seam: pin the LAUNCH appearance from `AGTERM_UITEST_FORCE_APPEARANCE` (`light`/`dark`).
    ///
    /// The dark-launch config re-siding (`GhosttyApp.syncLaunchColorScheme`) runs in
    /// `applicationDidFinishLaunching`, so a test covering it must decide the side before that — and
    /// XCUITest cannot: it inherits the machine's appearance, and `-AppleInterfaceStyle` would have to ride
    /// launch ARGUMENTS, which hit FB11763863 here. `NSApp.appearance` moves `effectiveAppearance`, which is
    /// what `currentIsDark()` reads. Ignored outside an isolated UI-test launch, like `debug.appearance`,
    /// and exempt from the control keep-in-sync for the same reason: it is test scaffolding, not a feature.
    private func applyUITestAppearanceOverride() {
        guard ContentView.isUITestLaunch,
              let side = ProcessInfo.processInfo.environment["AGTERM_UITEST_FORCE_APPEARANCE"],
              side == "light" || side == "dark" else { return }
        NSApp.appearance = NSAppearance(named: side == "dark" ? .darkAqua : .aqua)
    }

    @objc private func appDidBecomeActive(_: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.reconcileCloseSessionChord()
            }
        }
    }

    @objc private func keymapChanged(_: Notification) {
        MainActor.assumeIsolated { reconcileCloseSessionChord() }
    }

    @objc private func menuBeganTracking(_: Notification) {
        MainActor.assumeIsolated {
            reconcileCloseSessionChord()
        }
    }

    /// Keep ⌘W with agterm's File ▸ Close Session whenever the keymap says it owns that chord.
    ///
    /// SwiftUI hands the stock File ▸ Close (`performClose:`) a ⌘W equivalent the moment agterm's item
    /// vacates the chord, and putting `close_session` back does NOT reclaim it: SwiftUI drops the shortcut
    /// from its OWN item, leaving Close Session unbound and ⌘W closing the whole window until relaunch
    /// (issue #296). agterm asserts the split from the AppKit side — no SwiftUI API does either half.
    private func reconcileCloseSessionChord() {
        guard let keymap = settingsModel?.keymap else { return }
        AppDelegate.applyCloseSessionChord(keymap, in: NSApp.mainMenu)
    }

    /// Split ⌘W between agterm's Close Session item and the stock `performClose:` one, following `keymap`.
    /// Operates on whichever submenu holds `performClose:`; a menu without both items is left alone.
    ///
    /// The stock item may hold ⌘W only while NO built-in resolves to it — `close_session` alone is not
    /// enough, since another action can legitimately own ⌘W (`parseKeymap` rejects a chord only when two
    /// DISTINCT actions claim it), and arming the stock item there advertises the chord twice, letting
    /// SwiftUI's next rebuild unbind agterm's own item.
    ///
    /// agterm's item is a SwiftUI closure button with no distinguishing selector, so it is matched by title.
    static func applyCloseSessionChord(_ keymap: Keymap, in mainMenu: NSMenu?) {
        let closeSessionOwns = keymap.equivalent(for: .closeSession) == commandW
        let anyBuiltinOwns = BuiltinAction.allCases.contains { keymap.equivalent(for: $0) == commandW }
        let closeSelector = #selector(NSWindow.performClose(_:))
        for topItem in mainMenu?.items ?? [] {
            guard let submenu = topItem.submenu,
                  let stockClose = submenu.items.first(where: { $0.action == closeSelector }),
                  let ours = submenu.items.first(where: { $0.title == closeSessionItemTitle })
            else { continue }
            // clear a stale ⌘W on our item: SwiftUI defers its rebuild to the next activation, so right after
            // a reload that rebound close_session away ours still advertises the chord the stock item takes.
            if closeSessionOwns {
                ours.keyEquivalent = "w"
                ours.keyEquivalentModifierMask = .command
            } else if hasCommandW(ours) {
                ours.keyEquivalent = ""
                ours.keyEquivalentModifierMask = []
            }
            stockClose.keyEquivalent = anyBuiltinOwns ? "" : "w"
            stockClose.keyEquivalentModifierMask = anyBuiltinOwns ? [] : .command
        }
    }

    private static func hasCommandW(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent == "w" && item.keyEquivalentModifierMask == .command
    }

    /// The File-menu title of agterm's own close-the-session item, matched by `applyCloseSessionChord`.
    static let closeSessionItemTitle = "Close Session"
    private static let commandW = Chord(mods: [.command], key: "w")

    /// `open -a agterm /path` (the OS "open terminal here" integration): each URL resolves to a directory
    /// (folder → itself, file → its parent, via `OpenPathResolver`), queued and drained into a new session
    /// in the last-active window. WARM case only — a running instance already has a window to graft into.
    func application(_: NSApplication, open urls: [URL]) {
        let directories = urls.compactMap { OpenPathResolver.directory(for: $0) }
        guard !directories.isEmpty else { return }
        pendingOpenDirectories.append(contentsOf: directories)
        drainPendingOpenDirectories()
    }

    /// Turn every queued `open -a` directory into a new session in the last-active window, dropping an
    /// entry only once its session lands (a transient failure keeps it queued). Until the frontmost store
    /// resolves, retries every 0.1 s, bounded so a folder can't wedge a stuck timer.
    func drainPendingOpenDirectories(retry: Int = 0) {
        guard !pendingOpenDirectories.isEmpty else { return }
        guard let actions, library?.activeStore?.currentWorkspaceID != nil else {
            guard retry < 50 else { pendingOpenDirectories.removeAll(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.drainPendingOpenDirectories(retry: retry + 1)
            }
            return
        }
        NSApp.activate()
        let beforeCount = pendingOpenDirectories.count
        while let directory = pendingOpenDirectories.first, actions.openSession(atDirectory: directory) {
            pendingOpenDirectories.removeFirst()
        }
        // raise the window the session landed in: `NSApp.activate()` only fronts the app, so a minimized
        // last-active window would stay in the Dock. `raise` deminiaturizes + makes key, a frontmost no-op.
        if pendingOpenDirectories.count < beforeCount, let windowID = library?.activeWindowID {
            WindowRegistry.shared.raise(windowID)
        }
        if !pendingOpenDirectories.isEmpty, retry < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.drainPendingOpenDirectories(retry: retry + 1)
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

    /// On macOS 15+ a SwiftUI WindowGroup app launched by another process (XCUITest, launchd) often never
    /// auto-presents its window (FB11763863): dock icon shows, no window appears, and the scene's
    /// `.task`/`.onAppear` never fire. A reopen event (what a dock click sends) creates it — fire one once
    /// when no real window exists.
    private func bringUITestWindowsForward() {
        if !didForceReopen, NSApp.windows.allSatisfy({ $0 is NSPanel }) {
            didForceReopen = true
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        // present the launch window ONCE (FB11763863), then latch off: the windows are isRestorable=false so
        // they won't re-minimize, and re-fronting every tick oscillates the key window and fights a deliberate
        // window.select (which made multi-window control tests flaky). A runtime window.new has its own retry.
        guard !didPresentUITestWindow else { return }
        NSApp.activate()
        for window in NSApp.windows where window.canBecomeKey {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            didPresentUITestWindow = true
        }
    }

    /// One-shot latch: set once the launch UI-test window is presented, stopping the retry schedule.
    private var didPresentUITestWindow = false

    private var didForceReopen = false

    /// SwiftUI/AppKit can restore stale plain-WindowGroup windows before `WindowLibrary`'s reopen pass ends,
    /// and closing them from inside the stray view races that restoration machinery — so reconcile after
    /// AppKit's restoration-complete notification and after the real windows register via `TitleProbeView`.
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

    /// Confirm a user-initiated quit (menu Quit / ⌘Q) when windows are open. Skip system shutdown,
    /// restart, logout, XCUITest, auto-quit after the last window closes, or an unwired library.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard !ContentView.isUITestLaunch, let library else { return .terminateNow }
        if QuitReason.isSystemQuit(NSAppleEventManager.shared().currentAppleEvent) { return .terminateNow }
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
        // resolve in-memory picker state before closing the socket: a client already polling may observe
        // cancellation, but a later poll can still race socket teardown at process exit.
        actions?.cancelAllPendingPicks()
        controlServer?.stop()
        customCommandRunner?.stop()
        // clear the OS-level Dock badge — it outlives the process while unseenCount is ephemeral, so a quit
        // with unseen > 0 pins a stale count (the willClose refresh() can't: isTerminating no-ops closeWindow).
        DockBadgeController.shared.clear()
        // mark terminating so per-window willClose can't zero the open-set during quit — it must survive
        // for the next launch's reopen-all.
        library?.isTerminating = true
        // restore-running-command: capture each pane's live foreground command BEFORE the snapshot save so a
        // restored pane can re-run it. A force-quit/crash skips it (sessions + cwd still restore).
        if settingsModel?.settings.restoreRunningCommand == true, let library {
            Self.captureForegroundCommands(sessions: library.allOpenSessions())
        }
        library?.finalizeAllPendingCloses()
        // flush the stores + index: cwd changes since the last structural mutation aren't auto-persisted.
        library?.saveAllOpen()
        library?.saveIndex()
        // flush pending debounced settings writes (a keyboard-driven opacity/blur change holds a ~0.3s save
        // no drag-end commit fires) so they survive ⌘Q.
        settingsModel?.flushPendingSaves()
    }

    /// Capture the given panes' foreground commands (main + split) into their `Session` fields for the
    /// snapshot save. `ForegroundProcess` returns nil for a pane at its shell prompt, so plain shells stay
    /// plain. Two callers on different lifecycle edges: `applicationWillTerminate` passes every open
    /// session, `WindowAccessor`'s `willClose` passes one closing window's — on a close-the-last-window
    /// exit the quit-time capture runs after that teardown, too late to see any surface. Both sites and
    /// the launch-only replay gate are stated in `.claude/rules/settings.md`.
    @MainActor
    static func captureForegroundCommands(sessions: [Session]) {
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        for session in sessions {
            if let view = session.surface as? GhosttySurfaceView {
                session.foregroundCommand = ForegroundProcess.command(for: view, shellBasename: shellBasename)
            }
            // only a SHOWN split is recreated on restore, so gate on isSplit — a hidden split's captured
            // command would sit stale until the next ⌘D fires it.
            if session.isSplit, let split = session.splitSurface as? GhosttySurfaceView {
                session.splitForegroundCommand = ForegroundProcess.command(for: split, shellBasename: shellBasename)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // key termination off the model open-set, NOT AppKit's transient window count: a close or a re-render
        // that briefly drops the surviving NSWindow leaves a momentary zero-window state while the library
        // still has one open, and quitting there would kill the app and the control server mid-session.
        guard let library else { return true }
        return library.openIDs().isEmpty
    }
}
