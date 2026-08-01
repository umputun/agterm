import agtermCore
import Foundation
import SwiftUI

@main
struct agtermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @Environment(\.openWindow) private var openWindow

    @State var library: WindowLibrary
    @State var actions: AppActions
    @State var palette = PaletteController()
    @State private var sessionSwitcher: SessionSwitcher
    @State private var paneShortcuts: PaneShortcuts
    @State private var undoCloseShortcut: UndoCloseShortcut
    @State var settingsModel: SettingsModel
    @State private var controlServer: ControlServer
    @State private var customCommandRunner: CustomCommandRunner
    @State private var appearanceObserver: SystemAppearanceObserver
    @State private var accessibilityObserver: SystemAccessibilityObserver

    /// The plain `WindowGroup`'s scene id, used by `openWindow(id:)` to spawn additional windows.
    private static let windowGroupID = "terminal"

    /// The version paired with agterm's `TERM_PROGRAM` identity in every spawned terminal.
    private static let terminalProgramVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

    /// Hosted XCTest loads the real executable before `setUp`, so its scheme sets isolated state/socket paths
    /// plus this sentinel pre-`init()`; the scene then mounts a placeholder — no surfaces, no server.
    static var isHostedUnitTest: Bool {
        ProcessInfo.processInfo.environment["AGTERM_HOSTED_TESTS"] == "1"
    }

    init() {
        let library = agtermApp.restoredLibrary()
        _library = State(initialValue: library)
        let actions = AppActions(library: library)
        _actions = State(initialValue: actions)
        // settings persist alongside the workspace snapshot (same AGTERM_STATE_DIR override); built before the
        // control server so it can drive `keymap.reload`, safe since both need only the library.
        let settingsStore = ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]
            .map { SettingsStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? SettingsStore()
        let settingsModel = SettingsModel(library: library, settingsStore: settingsStore)
        _settingsModel = State(initialValue: settingsModel)
        let controlServer = ControlServer(library: library, actions: actions, settingsModel: settingsModel)
        _controlServer = State(initialValue: controlServer)
        _sessionSwitcher = State(initialValue: SessionSwitcher(library: library, canSwitch: { actions.uiActionsEnabled }))
        _paneShortcuts = State(initialValue: PaneShortcuts(library: library, actions: actions))
        _undoCloseShortcut = State(initialValue: UndoCloseShortcut(actions: actions))
        // built last: needs the keymap (settings) and the control server's bound socket path for `{AGT_SOCKET}`.
        _customCommandRunner = State(initialValue: CustomCommandRunner(
            library: library, settings: settingsModel,
            socketProvider: { controlServer.resolvedSocketPath }))
        // follows macOS light/dark via KVO on NSApp.effectiveAppearance; dependency-free, started in `.task`.
        _appearanceObserver = State(initialValue: SystemAppearanceObserver())
        // follows Reduce Motion / Reduce Transparency via NSWorkspace's accessibility-display notification,
        // fanning live changes to AppKit consumers; SwiftUI ones use Environment.
        _accessibilityObserver = State(initialValue: SystemAccessibilityObserver())
    }

    var body: some Scene {
        // a plain WindowGroup auto-opens one window at launch plus one per `openWindow(id:)`; value-based
        // `WindowGroup(for:)` can't bootstrap the first (no auto-open with SwiftUI restoration off). windows
        // claim the next open id off `WindowLibrary`'s claim queue (dedup-by-id); one past the set dismisses itself.
        WindowGroup(id: Self.windowGroupID) {
            if Self.isHostedUnitTest {
                Color.clear
            } else {
                ContentView(
                    library: library,
                    makeSurface: {
                        Self.makeSurface(for: $0, store: $1,
                                         env: surfaceEnv(for: $0, pane: .left), library: library)
                    },
                    makeSplitSurface: {
                        Self.makeSplitSurface(for: $0, store: $1,
                                              env: surfaceEnv(for: $0, pane: .right), library: library)
                    },
                    makeOverlaySurface: { Self.makeOverlaySurface(for: $0, store: $1, env: surfaceEnv(for: $0)) },
                    makeScratchSurface: { session, store in
                        // suppress the scratch's creation autoFocus when a full overlay or this window's quick
                        // terminal is up — each renders above it and owns focus.
                        let qtVisible = library.windowID(forSession: session.id)
                            .flatMap { QuickTerminalRegistry.shared.controller(for: $0) }?.isVisible ?? false
                        return Self.makeScratchSurface(for: session, store: store,
                                                       env: surfaceEnv(for: session, pane: .scratch),
                                                       suppressAutoFocus: session.overlayActive || qtVisible,
                                                       library: library)
                    },
                    quickTerminalEnv: { quickTerminalEnv(for: $0) },
                    actions: actions,
                    palette: palette,
                    sessionSwitcher: sessionSwitcher
                )
                    .frame(minWidth: 640, minHeight: 400)
                    .task {
                        appDelegate.library = library
                        // `openWindow` lives only in the scene: hand it to the action hub for cross-window
                        // reveal and `window.new`/`window.select` (raise if on-screen, else claim + spawn).
                        // MUST precede `controlServer.start()`, or an early command finds it nil: ok, no window.
                        actions.openWindow = { id in
                            if WindowRegistry.shared.raise(id) { return }
                            library.enqueueClaim(id)
                            openWindow(id: Self.windowGroupID)
                        }
                        // start the control channel (idempotent); the delegate reference stops it + unlinks the
                        // socket on terminate.
                        appDelegate.controlServer = controlServer
                        controlServer.start()
                        // Ctrl-Tab session-switcher key monitors (idempotent).
                        sessionSwitcher.start()
                        // Ctrl-1/Ctrl-2 direct pane-focus key monitor (idempotent).
                        paneShortcuts.start()
                        // undo-close shortcut (idempotent); passes through text fields so native undo wins there.
                        undoCloseShortcut.start()
                        // custom-command key monitor (idempotent): rebuilds its matcher from the keymap on
                        // `.agtermKeymapChanged`, removed on terminate via the delegate reference.
                        appDelegate.customCommandRunner = customCommandRunner
                        appDelegate.settingsModel = settingsModel
                        // hand the delegate the action hub and drain folders `open -a agterm /path` queued
                        // before the window store resolved.
                        appDelegate.actions = actions
                        appDelegate.drainPendingOpenDirectories()
                        customCommandRunner.start()
                        // wire the keymap + runner into the action hub for the command palette's custom
                        // commands; both are built after `actions`, so not in `init`.
                        actions.settingsModel = settingsModel
                        // seed auto-follow into every open store now the model is wired: idempotent and
                        // order-independent of resolveStore/onAppear (later windows seed in resolveStore).
                        settingsModel.applyAutoFollowToAllWindows()
                        actions.customCommandRunner = customCommandRunner
                        // the action hub opens the .themes palette for the "Select Theme…" launcher + menu.
                        actions.palette = palette
                        // register the notification delegate + request authorization (idempotent); the hub +
                        // library let a banner click reach the firing pane and stamp its window id in.
                        NotificationManager.shared.actions = actions
                        NotificationManager.shared.library = library
                        NotificationManager.shared.start()
                        // drive the Dock badge (via UNUserNotifications) from the app-wide unseen total — the
                        // sidebar pills' Session.unseenCount summed across windows.
                        DockBadgeController.shared.library = library
                        DockBadgeController.shared.start()
                        // keymap parse errors / conflicts from SettingsModel init — too early to post then,
                        // before registration. launch window only: `hasReopened` is false until `reopenWindows()`.
                        if !library.hasReopened, !settingsModel.keymapDiagnostics.isEmpty {
                            NotificationManager.shared.notifyKeymapDiagnostics(count: settingsModel.keymapDiagnostics.count)
                        }
                        // same for ghostty config diagnostics, recorded at boot by GhosttyApp.loadConfig
                        // (applicationDidFinishLaunching, before registration): same `hasReopened` gate.
                        if !library.hasReopened, GhosttyApp.shared.lastConfigDiagnosticsCount > 0 {
                            NotificationManager.shared.notifyConfigDiagnostics(count: GhosttyApp.shared.lastConfigDiagnosticsCount)
                        }
                        // runs once via the library latch — the .task fires per window.
                        reopenWindows()
                        appDelegate.scheduleRestoredWindowReconciliation(reason: "scene-task")
                        // start appearance following last: `[.initial]` seeds the launch side once the
                        // eager-deck surfaces exist; idempotent, so per-window `.task` re-entry is safe.
                        appearanceObserver.start()
                        // consumers read current accessibility values at first render; this handles live flips.
                        accessibilityObserver.start()
                    }
            }
        }
        // chromeless: traffic lights float over ContentView's custom titlebar row, so no empty strip above it.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .commands { appCommands }

        Settings {
            SettingsView(model: settingsModel)
        }
    }

    /// Builds the app-global window library at the state directory — `AGTERM_STATE_DIR`, a temp dir under UI test.
    /// Bootstrap migrates/recovers (legacy `workspaces.json` → one window, else seed): always valid, non-empty.
    @MainActor
    private static func restoredLibrary() -> WindowLibrary {
        ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]
            .map { WindowLibrary(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? WindowLibrary()
    }

    /// Opens the windows open at quit beyond the one SwiftUI auto-opened at launch (which claimed the launch
    /// id). Runs once via the library latch: `consumeReopen` seeds the claim queue, returning the extra count.
    @MainActor
    private func reopenWindows() {
        let extra = library.consumeReopen()
        for _ in 0..<extra { openWindow(id: Self.windowGroupID) }
    }

    /// Surface factory: a libghostty-backed view for the session, spawning a login shell in its initial working
    /// directory. On shell exit the view calls back to close the owning session in the store.
    @MainActor
    private static func makeSurface(for session: Session, store: AppStore, env: [String: String],
                                    library: WindowLibrary) -> GhosttySurfaceView {
        // `initialCommand` (`session.new --command`) replaces the login shell and closes the session on its exit
        // (like kitty); it is the durable creation identity, re-emitted by every `snapshot()`. `foregroundCommand`,
        // a distinct child captured at quit, is consumed run-once; an exec-replacing command has a nil libghostty
        // foreground pid, so it is never captured and restores via the exec `command` path, keeping close-on-exit.
        // Precedence is host-free `CommandRestore.restorePlan`: fresh always runs, restored honors the toggle, a
        // captured foreground preempts `initialCommand` even when denylist-suppressed. A `session.restore` override
        // beats both, from the TRANSIENT pending slot (only an app-bootstrap restore seeds it) not the sticky
        // persisted field; taking it clears it, so this pane's next surface is a plain shell.
        let hadForeground = session.foregroundCommand != nil
        let restoreInput = Self.restoreInitialInput(session.foregroundCommand)
        session.foregroundCommand = nil
        let inputs = CommandRestore.RestoreInputs(wasRestored: session.wasRestored,
                                                  restoreEnabled: GhosttyApp.shared.restoreRunningCommand,
                                                  hadForeground: hadForeground, foregroundInput: restoreInput,
                                                  initialCommand: session.initialCommand,
                                                  restoreOverride: session.takePendingRestoreOverride(pane: .left))
        let plan = CommandRestore.restorePlan(inputs)
        let view = GhosttySurfaceView(workingDirectory: session.initialCwd, fontSize: session.fontSize.map(Float.init),
                                      command: plan.command, initialInput: plan.initialInput,
                                      waitAfterCommand: session.commandWait, env: env)
        view.session = session
        let sessionID = session.id
        view.onExit = { [weak view] in
            guard let view else { return }
            Self.handlePaneExit(view, store: store, sessionID: sessionID, library: library)
        }
        view.onFocusChange = { focused in
            guard focused else { return }
            store.session(withID: sessionID)?.splitFocused = false
            // focusing a pane means you've seen the session: clear the badge and any delivered banners.
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        // focus-free half of the clear above: zoom hosting suppresses the focus report though the refocused
        // user is looking right at this surface.
        view.onClearUnseen = {
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        Self.wireStatusClear(view, store: store, sessionID: sessionID)
        view.onUserInput = { store.noteUserActivity() }
        view.onFontSizeChange = { store.setFontSize(sessionID, $0) }
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, library: library)
        return view
    }

    /// Shell-exit handler for BOTH pane factories, dispatched on the surface's CURRENT role, not the factory that
    /// built it (role-aware like `onFocusChange`): a promoted split survivor (main slot, `isSplitPane` cleared) must
    /// run `closePrimaryPane`, or a re-split then a main-pane exit fires the stale `closeSplitPane` — its guard now
    /// passes with both slots live — tearing down the fresh right pane, stranding the session on the dead left.
    @MainActor
    private static func handlePaneExit(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID,
                                       library: WindowLibrary) {
        if view.isSplitPane {
            store.closeSplitPane(sessionID)
        } else {
            store.closePrimaryPane(sessionID)
            // makeSplitSurface omits onFontSizeChange, but a promoted survivor is the sole pane and must persist
            // its own cmd +/-. no-op when the session closed instead (`surface` nil).
            if let promoted = store.session(withID: sessionID)?.surface as? GhosttySurfaceView {
                promoted.onFontSizeChange = { store.setFontSize(sessionID, $0) }
                // the same "session survived ⇒ its split was promoted" test, for a dashboard holding this
                // session by `<id>:right`. synchronous, so it lands before the reconcile onChange prunes the
                // cell; this is the only place that can tell promotion from the split's own shell exiting.
                library.windowID(for: store)
                    .flatMap { DashboardControllerRegistry.shared.controller(for: $0) }?
                    .promoteSplitMember(session: sessionID)
            }
        }
        // focus the surviving (now maximized) pane, else the session reselected to; the collapse/switch re-hosts
        // the target, hence the retry. `topmostSurface` prefers an overlay/scratch cover over the pane it hides.
        let target = store.session(withID: sessionID)?.topmostSurface ?? store.activeSession?.topmostSurface
        (target as? GhosttySurfaceView)?.focusAfterReparent()
    }

    /// The `initial_input` for a restored pane: the captured foreground argv re-rendered as a shell command
    /// line + newline, or nil when the restore-running-command flag is off or the basename is in the user's
    /// `restore-denylist.conf` (→ plain shell), parsed at launch into `GhosttyApp.shared.restoreDenylist`.
    @MainActor
    private static func restoreInitialInput(_ argv: [String]?) -> String? {
        guard GhosttyApp.shared.restoreRunningCommand, let argv,
              CommandRestore.shouldRestore(argv: argv, denylist: GhosttyApp.shared.restoreDenylist) else { return nil }
        return CommandRestore.shellQuotedLine(argv) + "\n"
    }

    /// Wires the four `onSearch*` callbacks to the owning session's search fields, resolved live via `sessionID`.
    /// START toggles: with the bar open it sends `end_search` (the ⌘F-again close), letting the resulting END
    /// clear; else it opens the bar (seeding any returned needle) and pins THIS surface as `searchSurface`, the
    /// owner the bar's needle/navigate/close drive. END is the single clear point — fields, owner, bar, and first
    /// responder back to the visible terminal. TOTAL/SELECTED carry the count/index; both factories share it, so
    /// GUI and control pin the owner alike.
    @MainActor
    private static func wireSearchCallbacks(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID,
                                            library: WindowLibrary) {
        view.isSearchable = true
        view.onSearchStart = { [weak view] needle in
            guard let session = store.session(withID: sessionID) else { return }
            if session.searchActive {
                // ⌘F-again close: end search on the PINNED owner, not the just-fired `view`, so a second ⌘F on
                // the OTHER split pane closes the original owner instead of stranding it in libghostty search.
                (session.searchSurface as? GhosttySurfaceView)?.endSearch()
                return
            }
            session.searchActive = true
            session.searchSurface = view
            if let needle, !needle.isEmpty { session.searchNeedle = needle }
        }
        view.onSearchEnd = {
            guard let session = store.session(withID: sessionID) else { return }
            session.searchActive = false
            session.searchNeedle = ""
            session.searchTotal = nil
            session.searchSelected = nil
            session.searchSurface = nil
            // refocus ONLY while this is still the selected session and no cover is up: `session.search --close
            // --target <background>` would otherwise make a hidden, opacity-0 surface first responder and steal
            // input from the visible session (hidden views CAN), and a cover owns focus. `topmostSurface` catches
            // the in-deck overlay/scratch (overlay > scratch > active pane) but not the window-level quick
            // terminal, so bail while that is up — it refocuses on hide; the retry outlasts the SwiftUI teardown.
            guard store.selectedSessionID == sessionID else { return }
            let windowID = library.windowID(forSession: sessionID)
            let quickTerminalVisible = windowID
                .flatMap { QuickTerminalRegistry.shared.controller(for: $0) }?.isVisible ?? false
            guard !quickTerminalVisible else { return }
            // terminal zoom owns focus above the deck and zoom-enter ends an open search; this END lands a tick
            // later, so refocusing would steal first responder back from the zoomed terminal.
            guard windowID.flatMap({ TerminalZoomRegistry.shared.controller(for: $0) })?.target == nil else { return }
            // a control picker is the topmost modal: `session.search --to close` stays valid cleanup while one
            // is pending, but its async END must not return focus behind it.
            guard PickRegistry.shared.controller(for: windowID)?.pending == nil else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
        view.onSearchTotal = { total in store.session(withID: sessionID)?.searchTotal = total }
        view.onSearchSelected = { selected in store.session(withID: sessionID)?.searchSelected = selected }
    }

    /// Wires the pane-scoped keystroke-clear: `keyDown` fires `onUserInputClearsStatus` unconditionally, and this
    /// closure clears to idle only when host-free `AgentIndicator.clearedBy(pane:isInterrupt:)` says the keystroke's
    /// OWN pane owns the status, so a block set from a background pane survives typing elsewhere. Main/split read
    /// the LIVE `isSplitPane` at keystroke time, so a promoted survivor clears as `.left`, matching its migrated
    /// status identity and `tree` addressing; a captured `.right` would clear the wrong pane and leave both panes
    /// `.right`-wired after a re-split. The scratch passes `fixedPane: .scratch`: never promoted, no `view.session`.
    @MainActor
    private static func wireStatusClear(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID,
                                        fixedPane: StatusPane? = nil) {
        view.onUserInputClearsStatus = { [weak view] isInterrupt in
            let pane = fixedPane ?? ((view?.isSplitPane ?? false) ? .right : .left)
            if store.session(withID: sessionID)?.agentIndicator.clearedBy(pane: pane, isInterrupt: isInterrupt) == true {
                store.setAgentIndicator(AgentIndicator(), forSession: sessionID)
            }
        }
    }

    /// Split-pane surface factory: a second independent login shell in the session's current directory, wired as
    /// `isSplitPane` so its PWD/title reports go to `session.splitCwd`/`splitTitle` and its shell exit closes
    /// just the split (hide + teardown), not the session.
    @MainActor
    private static func makeSplitSurface(for session: Session, store: AppStore, env: [String: String],
                                         library: WindowLibrary) -> GhosttySurfaceView {
        // cwd is the persisted `initialSplitCwd` (a restored split keeps its own directory), else the session's
        // effectiveCwd. Font size matches the primary; the split's own cmd +/- is not persisted. Env inherits the
        // parent's window/workspace/session ids. The captured foreground command re-runs via initial_input
        // (run-once); splits never carry an `initialCommand`, so there is no mutual-exclusion guard and no
        // `restorePlan` — `restoreInput` alone decides. A `session.restore` override wins over the capture, from
        // the TRANSIENT pending slot (seeded only by an app-bootstrap restore whose split was shown) not the
        // sticky persisted field; taking it clears it, so a fresh ⌘D split after a split shell exits is a shell.
        let capturedInput = Self.restoreInitialInput(session.splitForegroundCommand)
        session.splitForegroundCommand = nil
        let restoreInput = CommandRestore.restoreInput(restoreEnabled: GhosttyApp.shared.restoreRunningCommand,
                                                       restoreOverride: session.takePendingRestoreOverride(pane: .right),
                                                       capturedInput: capturedInput)
        let view = GhosttySurfaceView(workingDirectory: session.initialSplitCwd ?? session.effectiveCwd,
                                      fontSize: session.fontSize.map(Float.init), initialInput: restoreInput, env: env)
        view.session = session
        view.isSplitPane = true
        let sessionID = session.id
        view.onExit = { [weak view] in
            guard let view else { return }
            Self.handlePaneExit(view, store: store, sessionID: sessionID, library: library)
        }
        view.onFocusChange = { [weak view] focused in
            guard focused else { return }
            // a promoted survivor keeps this closure with `isSplitPane` cleared: as the main pane it must not
            // re-raise `splitFocused`, which masks its migrated title and mis-routes focus after a re-split.
            store.session(withID: sessionID)?.splitFocused = view?.isSplitPane ?? false
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        // the focus-free half of the clear above, for the zoom-hosted case (see makeSurface).
        view.onClearUnseen = {
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        Self.wireStatusClear(view, store: store, sessionID: sessionID)
        view.onUserInput = { store.noteUserActivity() }
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, library: library)
        return view
    }

    /// The fixed wrapper running the overlay command and recording its exit status to a temp file. stdout/stderr
    /// are NOT redirected (so a TUI renders normally); only the status is captured.
    private static let overlayExitWrapper = "sh -c '\(OverlayCapture.shellLine)'"

    /// Overlay-terminal surface factory: an ephemeral surface running the session's `overlayCommand` in
    /// `overlayCwd` (default the session's current dir). NOT wired to the session (no `view.session`), so its
    /// PWD reports don't clobber the session cwd; on exit `onExit` → `closeOverlay` tears it down and hides it.
    @MainActor
    private static func makeOverlaySurface(for session: Session, store: AppStore, env: [String: String]) -> GhosttySurfaceView {
        let sessionID = session.id
        let codeFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-ovl-\(UUID().uuidString).code")
        var overlayEnv = env
        overlayEnv[OverlayCapture.cmdEnvKey] = session.overlayCommand ?? ""
        overlayEnv[OverlayCapture.codeEnvKey] = codeFile
        let view = GhosttySurfaceView(workingDirectory: session.overlayCwd ?? session.effectiveCwd,
                                      fontSize: session.fontSize.map(Float.init), command: overlayExitWrapper,
                                      waitAfterCommand: session.overlayWait, autoFocus: true, env: overlayEnv)
        view.overlayCodeFile = codeFile
        // the overlay's own background color (`session.overlay.open --background-color`), applied in
        // createSurface — the overlay is sessionless, so it can't read it off the session there.
        view.overlayBackgroundColorHex = session.overlayBackgroundColor
        // record the exit status on teardown (always via destroySurface), so it survives a `session.overlay.close`
        // that bypasses onExit; a force-close removes the session first and no-ops here, where it is unqueryable.
        view.onExitCodeCaptured = { store.recordOverlayExit(sessionID, code: $0) }
        view.onExit = { store.closeOverlay(sessionID) }
        // typing is user activity: resets the auto-follow idle timer so an idle fire can't change the selection
        // (vanishing the overlay) mid-typing. destroySurface nils this, breaking the store->surface->closure cycle.
        view.onUserInput = { store.noteUserActivity() }
        return view
    }

    /// Scratch-terminal surface factory: a third per-session shell, full-overlay rendered. Like the overlay it is
    /// NOT operationally wired to the session (no `view.session`/`isSplitPane`), so its PWD/title never clobber
    /// the sidebar name, but it keeps a weak visual-config link for the watermark and — unlike the overlay —
    /// stays alive when hidden. Runs a login shell, or `session.scratchCommand` (`session.scratch --command`)
    /// RUN-ONCE. `autoFocus` grabs first responder on show (winning the SwiftUI/AppKit responder race); the
    /// shell's `exit` runs `closeScratch`, hiding + tearing down so the next show is fresh.
    @MainActor
    private static func makeScratchSurface(for session: Session, store: AppStore, env: [String: String],
                                           suppressAutoFocus: Bool, library: WindowLibrary) -> GhosttySurfaceView {
        // re-shows are focused via the `scratchActive` onChange (which also defers to those covers).
        // scratchCommand is run-once: read it for this spawn, then clear so a post-exit respawn is a shell.
        let command = session.scratchCommand
        session.scratchCommand = nil
        let view = GhosttySurfaceView(workingDirectory: session.effectiveCwd,
                                      fontSize: session.fontSize.map(Float.init),
                                      command: command,
                                      autoFocus: !suppressAutoFocus, env: env)
        view.watermarkSession = session
        let sessionID = session.id
        view.onExit = { store.closeScratch(sessionID) }
        Self.wireStatusClear(view, store: store, sessionID: sessionID, fixedPane: .scratch)
        // same idle-timer reset as the overlay: an idle auto-follow fire must not hide the scratch mid-typing.
        view.onUserInput = { store.noteUserActivity() }
        // the scratch is searchable (⌘F), pinned to the same session as the panes: unlike the overlay/quick
        // terminal it stays alive across hides, so a bar over it is safe.
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, library: library)
        return view
    }

    /// The environment a tree surface (main / split / overlay / scratch) exposes to its shell: the `AGTERM_*`
    /// session facts plus agterm's identity (`TERM_PROGRAM`/`TERM_PROGRAM_VERSION`). The window id comes from the
    /// open store owning the session (split/overlay/scratch inherit it), the workspace from the session's owner.
    /// `AGTERM_SOCKET` is the path `ControlServer` will bind, resolved at init so a launch-window shell
    /// materializing before `start()` still sees it, honoring a test's `AGTERM_CONTROL_SOCKET` override. `pane`
    /// injects `AGTERM_PANE` (`left`=main, `right`=split, `scratch`) so the hook wrapper forwards `--pane` and a
    /// background-pane status records which surface blocked; the overlay passes nil.
    @MainActor
    private func surfaceEnv(for session: Session, pane: StatusPane? = nil) -> [String: String] {
        var windowID: WindowInfo.ID?
        var workspaceID: UUID?
        if let resolvedWindowID = library.windowID(forSession: session.id) {
            windowID = resolvedWindowID
            if let workspace = library.store(for: resolvedWindowID)?.workspace(forSession: session.id) {
                workspaceID = workspace.id
            }
        }
        // a session-owned pane bakes a fresh stable AGTERM_PANE_ID, so the hook forwards --pane-id and the
        // status handler resolves the surface's LIVE slot, not the baked role (#199); the overlay needs none.
        return SurfaceEnvironment.session(sessionID: session.id, windowID: windowID,
                                          workspaceID: workspaceID, socketPath: controlServer.resolvedSocketPath,
                                          programVersion: Self.terminalProgramVersion,
                                          pane: pane, paneToken: pane == nil ? nil : UUID().uuidString)
    }

    /// The environment a window's quick terminal exposes — scratch, not in the tree, so its `AGTERM_*`
    /// values carry only enabled, window, and socket facts (no workspace/session ids), plus app identity.
    @MainActor
    func quickTerminalEnv(for windowID: WindowInfo.ID) -> [String: String] {
        SurfaceEnvironment.quickTerminal(windowID: windowID, socketPath: controlServer.resolvedSocketPath,
                                         programVersion: Self.terminalProgramVersion)
    }
}
