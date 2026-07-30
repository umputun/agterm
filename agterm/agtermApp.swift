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
    /// plus this sentinel pre-`init()`; the scene then mounts a shell-free placeholder — no surfaces, no server.
    static var isHostedUnitTest: Bool {
        ProcessInfo.processInfo.environment["AGTERM_HOSTED_TESTS"] == "1"
    }

    init() {
        let library = agtermApp.restoredLibrary()
        _library = State(initialValue: library)
        let actions = AppActions(library: library)
        _actions = State(initialValue: actions)
        // settings persist alongside the workspace snapshot (same AGTERM_STATE_DIR override), built before
        // the control server so it can drive `keymap.reload` — both depend only on the library, so safe.
        let settingsStore = ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]
            .map { SettingsStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? SettingsStore()
        let settingsModel = SettingsModel(library: library, settingsStore: settingsStore)
        _settingsModel = State(initialValue: settingsModel)
        let controlServer = ControlServer(library: library, actions: actions, settingsModel: settingsModel)
        _controlServer = State(initialValue: controlServer)
        _sessionSwitcher = State(initialValue: SessionSwitcher(library: library, canSwitch: { actions.uiActionsEnabled }))
        _paneShortcuts = State(initialValue: PaneShortcuts(library: library, actions: actions))
        _undoCloseShortcut = State(initialValue: UndoCloseShortcut(actions: actions))
        // the custom-command runner needs the keymap (settings) and the bound socket path (control
        // server) for the `{AGT_SOCKET}` token; built last so both are available.
        _customCommandRunner = State(initialValue: CustomCommandRunner(
            library: library, settings: settingsModel,
            socketProvider: { controlServer.resolvedSocketPath }))
        // follows the macOS light/dark appearance via an app-level KVO observer on NSApp.effectiveAppearance;
        // no dependencies, started in `.task`.
        _appearanceObserver = State(initialValue: SystemAppearanceObserver())
        // follows Reduce Motion / Reduce Transparency through NSWorkspace's accessibility display
        // notification and fans live changes out to AppKit consumers. SwiftUI consumers use Environment.
        _accessibilityObserver = State(initialValue: SystemAccessibilityObserver())
    }

    var body: some Scene {
        // a plain WindowGroup auto-opens one window at launch plus one per `openWindow(id:)`; a value-based
        // `WindowGroup(for:)` does NOT auto-open at launch with SwiftUI restoration off, so it can't
        // bootstrap the first window. `WindowLibrary` owns the open-set: each appearing window claims the
        // next open id from its claim queue (dedup-by-id), and a window beyond the open set dismisses itself.
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
                        // suppress the scratch's creation autoFocus when a full overlay OR this window's quick
                        // terminal is already up — each renders above the scratch and owns focus.
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
                        // the scene's `openWindow` is reachable only here, so hand it to the action hub — a
                        // cross-window reveal reopens a banner-clicked closed window, `window.new`/`window.select`
                        // open one (raise if on-screen, else claim the id + spawn). Installed BEFORE the control
                        // server starts, or an early socket command finds it nil and returns ok with no window.
                        actions.openWindow = { id in
                            if WindowRegistry.shared.raise(id) { return }
                            library.enqueueClaim(id)
                            openWindow(id: Self.windowGroupID)
                        }
                        // start the control channel (idempotent); the delegate reference lets it stop + unlink
                        // the socket on terminate.
                        appDelegate.controlServer = controlServer
                        controlServer.start()
                        // install the Ctrl-Tab session-switcher key monitors (idempotent).
                        sessionSwitcher.start()
                        // install the Ctrl-1/Ctrl-2 direct pane-focus key monitor (idempotent).
                        paneShortcuts.start()
                        // install the undo-close shortcut (idempotent); it passes through text fields so
                        // native edit undo still wins there.
                        undoCloseShortcut.start()
                        // install the custom-command key monitor (idempotent); it rebuilds its matcher from the
                        // keymap on `.agtermKeymapChanged`, and the delegate reference removes it on terminate.
                        appDelegate.customCommandRunner = customCommandRunner
                        appDelegate.settingsModel = settingsModel
                        // hand the delegate the action hub and drain any folders an `open -a agterm /path`
                        // queued before the window store resolved.
                        appDelegate.actions = actions
                        appDelegate.drainPendingOpenDirectories()
                        customCommandRunner.start()
                        // wire the keymap + runner into the action hub so the command palette can list and run
                        // custom commands; both are built after `actions`, so they're set here, not in `init`.
                        actions.settingsModel = settingsModel
                        // seed auto-follow into every open window's store now the model is wired: idempotent and
                        // order-independent of resolveStore/onAppear (windows opened later seed in resolveStore).
                        settingsModel.applyAutoFollowToAllWindows()
                        actions.customCommandRunner = customCommandRunner
                        // the action hub opens the .themes palette for the "Select Theme…" launcher + menu.
                        actions.palette = palette
                        // register the notification delegate + request authorization (idempotent); the hub +
                        // library let a banner click reach the firing pane and stamp its window id into the identity.
                        NotificationManager.shared.actions = actions
                        NotificationManager.shared.library = library
                        NotificationManager.shared.start()
                        // drive the Dock icon's count badge (via UNUserNotifications) from the app-wide unseen
                        // total (the same Session.unseenCount the sidebar pills track, summed across windows).
                        DockBadgeController.shared.library = library
                        DockBadgeController.shared.start()
                        // surface keymap parse errors / conflicts loaded at SettingsModel init — too early to post
                        // then, before the notification registration above. Launch window only: `hasReopened` is
                        // still false in the first window's `.task` (`reopenWindows()` flips it), so no reposts.
                        if !library.hasReopened, !settingsModel.keymapDiagnostics.isEmpty {
                            NotificationManager.shared.notifyKeymapDiagnostics(count: settingsModel.keymapDiagnostics.count)
                        }
                        // same for ghostty config diagnostics, recorded by GhosttyApp.loadConfig at boot
                        // (applicationDidFinishLaunching, before notification registration): same `hasReopened` gate.
                        if !library.hasReopened, GhosttyApp.shared.lastConfigDiagnosticsCount > 0 {
                            NotificationManager.shared.notifyConfigDiagnostics(count: GhosttyApp.shared.lastConfigDiagnosticsCount)
                        }
                        // runs once via the library latch — the .task fires per window.
                        reopenWindows()
                        appDelegate.scheduleRestoredWindowReconciliation(reason: "scene-task")
                        // start following the macOS appearance last: `[.initial]` seeds the launch side once
                        // the eager-deck surfaces exist (idempotent, so per-window `.task` re-entry is safe).
                        appearanceObserver.start()
                        // consumers read current accessibility values at first render; this handles live flips.
                        accessibilityObserver.start()
                    }
            }
        }
        // chromeless: no system title bar (the traffic lights float over our custom titlebar row in
        // ContentView), so there's no empty title-bar strip above our header.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .commands { appCommands }

        Settings {
            SettingsView(model: settingsModel)
        }
    }

    /// Builds the app-global window library rooted at the state directory. Its bootstrap runs
    /// migration/recovery (legacy `workspaces.json` → one window, else seed), so the window set is always
    /// valid and non-empty. UI tests set `AGTERM_STATE_DIR` to a temp dir, never touching the real state.
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

    /// Surface factory: a libghostty-backed view for the session, spawning a login shell in its initial
    /// working directory. On shell exit the view calls back to close the owning session in the store.
    @MainActor
    private static func makeSurface(for session: Session, store: AppStore, env: [String: String],
                                    library: WindowLibrary) -> GhosttySurfaceView {
        // `initialCommand` (`session.new --command`) runs as the surface's process instead of the login shell;
        // `onExit` below then closes the single session on its exit, like kitty. It is the durable creation
        // identity, re-emitted by every `snapshot()`, while `foregroundCommand` — a distinct child captured at
        // quit — is consumed run-once here. A command that exec-replaces the shell is invisible to libghostty's
        // foreground pid (nil), so it is never captured and restores via the exec `command` path, keeping
        // close-on-exit. Precedence (fresh always runs, restored honors the toggle, a captured foreground
        // preempts `initialCommand` even when denylist-suppressed) is the host-free `CommandRestore.restorePlan`.
        // A `session.restore` override beats both: taken from the TRANSIENT pending slot (seeded only by an
        // app-bootstrap restore), never the sticky persisted field, and taking it clears it so a second surface
        // for this pane runs a plain shell.
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
            Self.handlePaneExit(view, store: store, sessionID: sessionID)
        }
        view.onFocusChange = { focused in
            guard focused else { return }
            store.session(withID: sessionID)?.splitFocused = false
            // focusing a pane means you've seen the session: clear the badge and any delivered banners.
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        // the focus-free half of the clear above, for the zoom-hosted case where the focus report is
        // suppressed but the refocused user is looking at exactly this surface.
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

    /// Shell-exit handler for BOTH pane factories, dispatched on the surface's CURRENT role rather than the
    /// factory that built it: a promoted split survivor (built by `makeSplitSurface`, moved into the main slot
    /// with `isSplitPane` cleared) must run `closePrimaryPane` on its own exit, or a re-split then a main-pane
    /// exit fires the stale `closeSplitPane`, whose guard now passes (both slots live), tearing down the fresh
    /// right pane and stranding the session on the dead left one. Role-aware like `onFocusChange`.
    @MainActor
    private static func handlePaneExit(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID) {
        if view.isSplitPane {
            store.closeSplitPane(sessionID)
        } else {
            store.closePrimaryPane(sessionID)
            // makeSplitSurface omits onFontSizeChange, but a promoted survivor is now the sole pane and must
            // persist its own cmd +/- like a primary. no-op when the session closed instead (`surface` nil).
            if let promoted = store.session(withID: sessionID)?.surface as? GhosttySurfaceView {
                promoted.onFontSizeChange = { store.setFontSize(sessionID, $0) }
            }
        }
        // focus the surviving (now maximized) pane, else the session reselected to when the whole session
        // closed; the collapse/switch re-hosts the target, hence the retry. `topmostSurface` hands focus to
        // an overlay/scratch cover rather than to the pane it hides.
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

    /// Wires the four `onSearch*` callbacks to the owning session's search fields, resolved live via
    /// `sessionID`. START toggles: with the bar already open it sends `end_search` (the ⌘F-again close) and
    /// lets the resulting END clear; else it opens the bar (`searchActive = true`, seeding any returned needle)
    /// and pins THIS surface as `searchSurface`, the owner the bar's needle/navigate/close drive. END is the
    /// single clear point — fields, owner, bar, and first responder back to the session's visible terminal.
    /// TOTAL/SELECTED carry the match count/index. Shared by both factories, so the GUI and control channel
    /// pin the owner identically.
    @MainActor
    private static func wireSearchCallbacks(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID,
                                            library: WindowLibrary) {
        view.isSearchable = true
        view.onSearchStart = { [weak view] needle in
            guard let session = store.session(withID: sessionID) else { return }
            if session.searchActive {
                // ⌘F-again close: end search on the PINNED owner (the surface START first fired on), not the
                // just-fired `view`, so a second ⌘F on the OTHER split pane closes the original owner instead
                // of stranding it in libghostty search mode. the resulting END clears the fields and refocuses.
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
            // refocus the terminal ONLY while this is still the selected session and no cover is up: a
            // `session.search --close --target <background>` closes a hidden, opacity-0 surface whose first
            // responder would steal input from the visible session (hidden views CAN become first responder),
            // and a cover owns focus itself. `topmostSurface` catches the in-deck overlay/scratch (overlay >
            // scratch > active pane); the window-level quick terminal does not, so bail while it is up — it
            // restores the session on its own hide. the bounded retry re-asserts past the SwiftUI teardown.
            guard store.selectedSessionID == sessionID else { return }
            let windowID = library.windowID(forSession: sessionID)
            let quickTerminalVisible = windowID
                .flatMap { QuickTerminalRegistry.shared.controller(for: $0) }?.isVisible ?? false
            guard !quickTerminalVisible else { return }
            // terminal zoom owns focus above the deck, and zoom-enter itself ends an open search — this END
            // lands a tick later, so refocusing here would steal first responder back from the zoomed terminal.
            guard windowID.flatMap({ TerminalZoomRegistry.shared.controller(for: $0) })?.target == nil else { return }
            // a control picker is the topmost modal: `session.search --to close` stays valid cleanup while one
            // is pending, but its asynchronous END must not return focus behind the picker.
            guard PickRegistry.shared.controller(for: windowID)?.pending == nil else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
        view.onSearchTotal = { total in store.session(withID: sessionID)?.searchTotal = total }
        view.onSearchSelected = { selected in store.session(withID: sessionID)?.searchSelected = selected }
    }

    /// Wires the pane-scoped keystroke-clear: `keyDown` fires `onUserInputClearsStatus` unconditionally, and
    /// this closure resets the status to idle only when the host-free `AgentIndicator.clearedBy(pane:isInterrupt:)`
    /// says the keystroke's OWN pane owns it, so a block set from a background pane survives typing elsewhere.
    /// Main/split resolve the pane from the surface's LIVE `isSplitPane` at keystroke time, not statically: a
    /// promoted split survivor then clears as `.left`, matching its migrated status identity and `tree`
    /// addressing, where a captured `.right` would clear the wrong pane and a re-split would leave both panes
    /// `.right`-wired. The scratch passes `fixedPane: .scratch` — never promoted, and it has no `view.session`.
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

    /// Split-pane surface factory: a second independent login shell in the session's current directory. Wired
    /// as `isSplitPane`, so its PWD/title reports go to `session.splitCwd`/`splitTitle` instead of the
    /// primary's, and on shell exit it closes just the split (hide + teardown), not the whole session.
    @MainActor
    private static func makeSplitSurface(for session: Session, store: AppStore, env: [String: String],
                                         library: WindowLibrary) -> GhosttySurfaceView {
        // cwd from the persisted `initialSplitCwd`, so a restored split keeps its own directory, else the
        // session's effectiveCwd for a fresh one. Font size matches the primary; its own cmd +/- is not
        // persisted. Env inherits the parent's window/workspace/session ids. The captured foreground command
        // re-runs via initial_input (consumed run-once); splits never carry an `initialCommand`, so there is
        // no mutual-exclusion guard and no `restorePlan` — `restoreInput` alone decides. A `session.restore`
        // override wins over the capture, taken from the TRANSIENT pending slot (seeded only by an
        // app-bootstrap restore whose split was shown) not the sticky persisted field, and taking it clears
        // it: this factory runs again for a fresh ⌘D split after a split shell exits, which must be a shell.
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
            Self.handlePaneExit(view, store: store, sessionID: sessionID)
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

    /// The fixed wrapper that runs the overlay command and records its exit status to a temp file.
    /// stdout/stderr are NOT redirected (so a TUI renders normally); only the status is captured.
    private static let overlayExitWrapper = "sh -c '\(OverlayCapture.shellLine)'"

    /// Overlay-terminal surface factory: an ephemeral surface running the session's `overlayCommand` as its
    /// process in `overlayCwd` (default the session's current dir). NOT wired to the session (no
    /// `view.session`), so its PWD reports don't clobber the session's cwd. On the command's exit the
    /// process-exit fires `onExit` → `closeOverlay`, tearing the surface down and hiding the overlay.
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
        // the overlay's own background color (session.overlay.open --background-color), applied to the
        // surface in createSurface — the overlay is sessionless, so it can't read it off the session there.
        view.overlayBackgroundColorHex = session.overlayBackgroundColor
        // record the exit status on teardown (always through destroySurface), so it survives an explicit
        // session.overlay.close that bypasses onExit; a force-close removes the session first and no-ops here,
        // where the result is unqueryable anyway.
        view.onExitCodeCaptured = { store.recordOverlayExit(sessionID, code: $0) }
        view.onExit = { store.closeOverlay(sessionID) }
        // typing in the cover is user activity: reset the auto-follow idle timer so an idle fire can't change
        // the selection (vanishing the overlay) mid-typing. destroySurface nils this, breaking the
        // store -> surface -> closure retain cycle.
        view.onUserInput = { store.noteUserActivity() }
        return view
    }

    /// Scratch-terminal surface factory: a third per-session shell, full-overlay rendered. Like the overlay it
    /// is NOT operationally wired to the session (no `view.session`/`isSplitPane`), so its PWD/title never
    /// clobber the sidebar name, but it keeps a weak visual-config link for the session watermark and — unlike
    /// the overlay — stays alive when hidden. Runs a login shell, or `session.scratchCommand`
    /// (`session.scratch --command`) RUN-ONCE, consumed here so a respawn after its exit is a plain shell.
    /// `autoFocus` grabs first responder on show (winning the SwiftUI/AppKit responder race); the shell's
    /// `exit` runs `closeScratch`, hiding + tearing down so the next show is fresh. Seeds from the cwd + env ids.
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
        // typing in the scratch is user activity: reset the auto-follow idle timer so an idle fire can't
        // change the selection (hiding the scratch) mid-typing. destroySurface nils this, breaking the
        // store -> surface -> closure retain cycle.
        view.onUserInput = { store.noteUserActivity() }
        // the scratch is searchable (⌘F), pinned to the same session like the main/split panes; unlike the
        // overlay/quick terminal it behaves as a real pane (kept alive across hides), so a bar over it is safe.
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, library: library)
        return view
    }

    /// The environment a tree surface (main / split / overlay / scratch) exposes to its shell: the `AGTERM_*`
    /// session facts plus agterm's identity (`TERM_PROGRAM`/`TERM_PROGRAM_VERSION`). The window id comes from
    /// the open store owning the session (split/overlay/scratch inherit it), the workspace from the session's
    /// owner, and `AGTERM_SOCKET` is the path `ControlServer` will bind — resolved at init, so a launch-window
    /// shell materializing before `start()` binds still sees it — honoring a test's `AGTERM_CONTROL_SOCKET`
    /// override. `pane` injects `AGTERM_PANE` (`left`=main, `right`=split, `scratch`) so the hook wrapper
    /// forwards `--pane` and a background-pane status records which surface blocked; the overlay passes nil.
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
