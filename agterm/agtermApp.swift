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

    /// The plain `WindowGroup`'s scene id, used by `openWindow(id:)` to spawn additional windows.
    private static let windowGroupID = "terminal"

    init() {
        let library = agtermApp.restoredLibrary()
        _library = State(initialValue: library)
        let actions = AppActions(library: library)
        _actions = State(initialValue: actions)
        // settings persist alongside the workspace snapshot (same AGTERM_STATE_DIR override). Built
        // before the control server so the server can drive `keymap.reload` on it (both depend only on
        // the library, so this reorder is safe).
        let settingsStore = ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]
            .map { SettingsStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? SettingsStore()
        let settingsModel = SettingsModel(library: library, settingsStore: settingsStore)
        _settingsModel = State(initialValue: settingsModel)
        let controlServer = ControlServer(library: library, actions: actions, settingsModel: settingsModel)
        _controlServer = State(initialValue: controlServer)
        _sessionSwitcher = State(initialValue: SessionSwitcher(library: library))
        _paneShortcuts = State(initialValue: PaneShortcuts(library: library, actions: actions))
        _undoCloseShortcut = State(initialValue: UndoCloseShortcut(actions: actions))
        // the custom-command runner needs the keymap (settings) and the bound socket path (control
        // server) for the `{AGT_SOCKET}` token; built last so both are available.
        _customCommandRunner = State(initialValue: CustomCommandRunner(
            library: library, settings: settingsModel,
            socketProvider: { controlServer.resolvedSocketPath }))
        // follows the macOS light/dark appearance via an app-level KVO observer on
        // NSApp.effectiveAppearance (see SystemAppearanceObserver). No dependencies; started in `.task`.
        _appearanceObserver = State(initialValue: SystemAppearanceObserver())
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
                makeSurface: { Self.makeSurface(for: $0, store: $1, env: surfaceEnv(for: $0, pane: .left), library: library) },
                makeSplitSurface: { Self.makeSplitSurface(for: $0, store: $1, env: surfaceEnv(for: $0, pane: .right), library: library) },
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
                    // install the Ctrl-1/Ctrl-2 direct pane-focus key monitor (idempotent).
                    paneShortcuts.start()
                    // install the undo-close shortcut (idempotent); it passes through text fields so
                    // native edit undo still wins there.
                    undoCloseShortcut.start()
                    // install the custom-command key monitor (idempotent); rebuilds its matcher from
                    // the keymap on `.agtermKeymapChanged`. Hand the delegate a reference so it can
                    // remove the monitor on terminate.
                    appDelegate.customCommandRunner = customCommandRunner
                    appDelegate.settingsModel = settingsModel
                    customCommandRunner.start()
                    // wire the keymap + runner into the action hub so the command palette can list the
                    // custom commands and run them (both are built after `actions`, so they're set here
                    // rather than in the init, mirroring the NotificationManager wiring below).
                    actions.settingsModel = settingsModel
                    // seed the auto-follow setting into every open window's store now that the model is
                    // wired — deterministic regardless of the per-window resolveStore/onAppear ordering
                    // (the resolveStore seed handles windows opened later). Idempotent.
                    settingsModel.applyAutoFollowToAllWindows()
                    actions.customCommandRunner = customCommandRunner
                    // the action hub opens the .themes palette for the "Select Theme…" launcher + menu.
                    actions.palette = palette
                    // register the notification delegate + request authorization (idempotent), and
                    // hand it the action hub + library so a banner click can navigate to the firing
                    // pane and the capture side can stamp the firing window id into the identity.
                    NotificationManager.shared.actions = actions
                    NotificationManager.shared.library = library
                    NotificationManager.shared.start()
                    // drive the Dock icon's count badge (via UNUserNotifications) from the app-wide unseen
                    // total (the same Session.unseenCount the sidebar pills track, summed across windows).
                    DockBadgeController.shared.library = library
                    DockBadgeController.shared.start()
                    // surface keymap parse errors / conflicts loaded at SettingsModel init (too early to
                    // post then — before notification registration above). Only on the launch window:
                    // `hasReopened` is still false here for the first window's `.task` (reopenWindows()
                    // below flips it), so subsequent windows don't repost the same banner.
                    if !library.hasReopened, !settingsModel.keymapDiagnostics.isEmpty {
                        NotificationManager.shared.notifyKeymapDiagnostics(count: settingsModel.keymapDiagnostics.count)
                    }
                    // same for ghostty config diagnostics: GhosttyApp.loadConfig records them at boot
                    // (applicationDidFinishLaunching, before notification registration), so surface them
                    // here on the launch window only, the same `hasReopened` gate as the keymap banner.
                    if !library.hasReopened, GhosttyApp.shared.lastConfigDiagnosticsCount > 0 {
                        NotificationManager.shared.notifyConfigDiagnostics(count: GhosttyApp.shared.lastConfigDiagnosticsCount)
                    }
                    // reopen every window that was open at quit. SwiftUI auto-opened one window
                    // (this one) at launch, which claimed the launch id; open one more per remaining
                    // open id. runs once (the .task fires per window) via the library latch.
                    reopenWindows()
                    appDelegate.scheduleRestoredWindowReconciliation(reason: "scene-task")
                    // start following the macOS appearance last: `[.initial]` seeds the launch side once
                    // the eager-deck surfaces exist (idempotent, so per-window `.task` re-entry is safe).
                    appearanceObserver.start()
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

    /// Builds the app-global window library rooted at the state directory. The library's bootstrap
    /// runs migration/recovery (legacy `workspaces.json` → one window, else seed) so the resulting
    /// window set is always valid and non-empty. UI tests pass `AGTERM_STATE_DIR` to isolate persistence
    /// in a temp dir so a run never touches the user's real state.
    @MainActor
    private static func restoredLibrary() -> WindowLibrary {
        ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"]
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
    private static func makeSurface(for session: Session, store: AppStore, env: [String: String],
                                    library: WindowLibrary) -> GhosttySurfaceView {
        // `initialCommand` (from `session.new --command`) runs as the surface's process instead of the
        // login shell; on its exit the surface's onExit (below) closes the single session, like kitty.
        // restore-running-command: `foregroundCommand` (a distinct child captured at quit) is consumed
        // run-once here; the persisted `initialCommand` is the durable creation identity (re-emitted by every
        // `snapshot()`). A command that exec-replaces the shell is invisible to libghostty's foreground pid
        // (nil), so it is never captured and restores via the exec `command` path (preserving close-on-exit).
        // The gate + precedence (fresh-always-runs, restored-honors-toggle, a captured foreground preempts
        // `initialCommand` even when denylist-suppressed) is the host-free `CommandRestore.restorePlan`.
        let hadForeground = session.foregroundCommand != nil
        let restoreInput = Self.restoreInitialInput(session.foregroundCommand)
        session.foregroundCommand = nil
        let plan = CommandRestore.restorePlan(wasRestored: session.wasRestored,
                                              restoreEnabled: GhosttyApp.shared.restoreRunningCommand,
                                              hadForeground: hadForeground, foregroundInput: restoreInput,
                                              initialCommand: session.initialCommand)
        let view = GhosttySurfaceView(workingDirectory: session.initialCwd, fontSize: session.fontSize.map(Float.init),
                                      command: plan.command,
                                      initialInput: plan.initialInput, env: env)
        view.session = session
        let sessionID = session.id
        view.onExit = {
            store.closePrimaryPane(sessionID)
            // focus the surviving (now maximized) pane; if the whole (single) session closed instead,
            // focus the session it reselected to. the collapse/switch re-hosts the target, so use the retry.
            // resolve through `topmostSurface`, so a pane exiting under an overlay or scratch hands focus to
            // the cover on top rather than to the pane it hides.
            let target = store.session(withID: sessionID)?.topmostSurface ?? store.activeSession?.topmostSurface
            (target as? GhosttySurfaceView)?.focusAfterReparent()
        }
        view.onFocusChange = { focused in
            guard focused else { return }
            store.session(withID: sessionID)?.splitFocused = false
            // focusing a pane means you've seen the session: clear the badge and any delivered banners.
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        Self.wireStatusClear(view, store: store, sessionID: sessionID, pane: .left)
        view.onUserInput = { store.noteUserActivity() }
        view.onFontSizeChange = { store.setFontSize(sessionID, $0) }
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, library: library)
        return view
    }

    /// The `initial_input` for a restored pane: the captured foreground argv re-rendered as a shell
    /// command line + newline, or nil when the restore-running-command flag is off or the command's
    /// basename is in the user's `restore-denylist.conf` (→ plain shell). Host-free decisions live in
    /// `CommandRestore`; the denylist is parsed at launch into `GhosttyApp.shared.restoreDenylist`.
    @MainActor
    private static func restoreInitialInput(_ argv: [String]?) -> String? {
        guard GhosttyApp.shared.restoreRunningCommand, let argv,
              CommandRestore.shouldRestore(argv: argv, denylist: GhosttyApp.shared.restoreDenylist) else { return nil }
        return CommandRestore.shellQuotedLine(argv) + "\n"
    }

    /// Wire the four `onSearch*` surface callbacks to the owning session's search fields, resolving the
    /// session live via `sessionID`. START toggles: if the session's bar is already open it sends
    /// `end_search` (the ⌘F-again close) and lets the resulting END do the clear; else it opens the bar
    /// (`searchActive = true`, seeding any returned needle) and pins THIS surface as `searchSurface` (the
    /// owner the bar's needle/navigate/close drive). END is the single clear point — it resets the fields,
    /// clears the owner, hides the bar, and returns first responder to the session's visible terminal.
    /// TOTAL/SELECTED carry the match count/index. Shared by both surface factories — so the GUI and the
    /// control channel pin the owner the same way and can't drift.
    @MainActor
    private static func wireSearchCallbacks(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID,
                                            library: WindowLibrary) {
        view.isSearchable = true
        view.onSearchStart = { [weak view] needle in
            guard let session = store.session(withID: sessionID) else { return }
            if session.searchActive {
                // bar already open: ⌘F-again close — end search on the PINNED owner (the surface START
                // first fired on), not the just-fired `view`, so a second ⌘F on the OTHER split pane closes
                // the original owner rather than stranding it in libghostty search mode. the resulting END
                // callback clears the fields and refocuses.
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
            // return first responder to the terminal ONLY when this is still the selected session AND no
            // covering surface is up: a `session.search --close --target <background>` closes a hidden,
            // opacity-0 surface whose first responder would steal input from the visible session (hidden
            // views CAN become first responder), and a cover owns focus itself. besides the in-deck
            // overlay/scratch (caught by `topmostSurface`), the window-level quick terminal also covers the
            // session — refocusing the hidden pane behind it would steal focus, so bail while it's up
            // (it restores the session on its own hide). target the visible `topmostSurface` (overlay >
            // scratch > active pane) and re-assert past the SwiftUI teardown via the bounded retry.
            guard store.selectedSessionID == sessionID else { return }
            let quickTerminalVisible = library.windowID(forSession: sessionID)
                .flatMap { QuickTerminalRegistry.shared.controller(for: $0) }?.isVisible ?? false
            guard !quickTerminalVisible else { return }
            (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
        }
        view.onSearchTotal = { total in store.session(withID: sessionID)?.searchTotal = total }
        view.onSearchSelected = { selected in store.session(withID: sessionID)?.searchSelected = selected }
    }

    /// Wire the pane-scoped keystroke-clear: `keyDown` fires `onUserInputClearsStatus` unconditionally, and
    /// this closure clears the status back to idle ONLY when the host-free `AgentIndicator.clearedBy(pane:isInterrupt:)`
    /// says the keystroke's OWN pane owns the current status — so a block set from a background pane survives
    /// foreground typing in another pane. Wired by all three surface factories with only the pane differing
    /// (main=`.left`, split=`.right`, scratch=`.scratch`), like `wireSearchCallbacks`; the scratch has no
    /// `view.session`, so the decision must live in this closure rather than `keyDown`.
    @MainActor
    private static func wireStatusClear(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID, pane: StatusPane) {
        view.onUserInputClearsStatus = { isInterrupt in
            if store.session(withID: sessionID)?.agentIndicator.clearedBy(pane: pane, isInterrupt: isInterrupt) == true {
                store.setAgentIndicator(AgentIndicator(), forSession: sessionID)
            }
        }
    }

    /// Split-pane surface factory: a second independent login shell in the session's current
    /// directory. Wired to the session as `isSplitPane`, so its PWD/title reports go to
    /// `session.splitCwd`/`splitTitle` (never clobbering the primary's), and on shell exit it closes
    /// just the split (hide + teardown), not the whole session.
    @MainActor
    private static func makeSplitSurface(for session: Session, store: AppStore, env: [String: String],
                                         library: WindowLibrary) -> GhosttySurfaceView {
        // seed the split's cwd from its persisted `initialSplitCwd` (so a restored split keeps its
        // own directory, not the primary's), falling back to the session's effectiveCwd for a fresh
        // split. Font size matches the primary; its own cmd +/- changes aren't persisted. It inherits
        // the parent session's window/workspace/session ids in the env.
        // restore-running-command: re-run the split pane's captured foreground command via initial_input
        // (consumed run-once). Splits never carry an `initialCommand`, so no mutual-exclusion guard.
        let restoreInput = Self.restoreInitialInput(session.splitForegroundCommand)
        session.splitForegroundCommand = nil
        let view = GhosttySurfaceView(workingDirectory: session.initialSplitCwd ?? session.effectiveCwd,
                                      fontSize: session.fontSize.map(Float.init), initialInput: restoreInput, env: env)
        view.session = session
        view.isSplitPane = true
        let sessionID = session.id
        view.onExit = {
            store.closeSplitPane(sessionID)
            // focus the surviving (now maximized) pane; if the whole session closed (primary already
            // exited), focus the session it reselected to. the collapse/switch re-hosts it, so retry.
            // resolve through `topmostSurface`, so a pane exiting under an overlay or scratch hands focus to
            // the cover on top rather than to the pane it hides.
            let target = store.session(withID: sessionID)?.topmostSurface ?? store.activeSession?.topmostSurface
            (target as? GhosttySurfaceView)?.focusAfterReparent()
        }
        view.onFocusChange = { focused in
            guard focused else { return }
            store.session(withID: sessionID)?.splitFocused = true
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        Self.wireStatusClear(view, store: store, sessionID: sessionID, pane: .right)
        view.onUserInput = { store.noteUserActivity() }
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, library: library)
        return view
    }

    /// The fixed wrapper that runs the overlay command and records its exit status to a temp file.
    /// stdout/stderr are NOT redirected (so a TUI renders normally); only the status is captured.
    private static let overlayExitWrapper = "sh -c '\(OverlayCapture.shellLine)'"

    /// Overlay-terminal surface factory: an ephemeral surface running the session's `overlayCommand`
    /// as its process in `overlayCwd` (default the session's current dir). Like the split, it is NOT
    /// wired to the session (no `view.session`), so its PWD reports don't clobber the session's
    /// cwd. When the command exits, the surface's process-exit fires `onExit` → `closeOverlay`,
    /// which tears the surface down and hides the overlay — so the program's exit makes it vanish.
    @MainActor
    private static func makeOverlaySurface(for session: Session, store: AppStore, env: [String: String]) -> GhosttySurfaceView {
        let sessionID = session.id
        // wrap the command so its exit status lands in a per-surface temp file. No stdout/stderr
        // redirect — the program renders in the overlay as usual.
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
        // record the exit status on teardown (the surface always tears down through destroySurface), so
        // it survives an explicit session.overlay.close that bypasses onExit. a session/window force-close
        // removes the session first, so this no-ops there — but the result is unqueryable after that anyway.
        view.onExitCodeCaptured = { store.recordOverlayExit(sessionID, code: $0) }
        view.onExit = { store.closeOverlay(sessionID) }
        // typing in the cover counts as user activity: reset the window's auto-follow idle timer so an
        // idle fire can't change the underlying selection (vanishing the overlay) while you type in it.
        // destroySurface nils this, breaking the store -> surface -> closure retain cycle.
        view.onUserInput = { store.noteUserActivity() }
        return view
    }

    /// Scratch-terminal surface factory: a third per-session shell, full-overlay rendered. Like the
    /// overlay it is NOT wired to the session (no `view.session`/`isSplitPane`), so its PWD/title never
    /// clobber the session's sidebar name; unlike the overlay it is kept alive when hidden. Runs a plain
    /// login shell, or `session.scratchCommand` when set (`session.scratch --command`) — RUN-ONCE: the
    /// command is consumed here so a respawn after it exits is a plain shell. `autoFocus` grabs first
    /// responder on show (winning the SwiftUI/AppKit responder race); on the shell's `exit`, `closeScratch`
    /// hides + tears it down so the next show spawns fresh. Seeds from the session's current dir + env ids.
    @MainActor
    private static func makeScratchSurface(for session: Session, store: AppStore, env: [String: String],
                                           suppressAutoFocus: Bool, library: WindowLibrary) -> GhosttySurfaceView {
        // autoFocus on creation gives the first show reliable focus — but suppress it when another
        // surface already owns focus above the scratch (a full overlay, or the window-level quick
        // terminal), so a scratch created under one can't steal first responder. Re-shows are focused
        // via the `scratchActive` onChange (which also defers to those covers).
        // scratchCommand is run-once: read it for this spawn, then clear so a post-exit respawn is a shell.
        let command = session.scratchCommand
        session.scratchCommand = nil
        let view = GhosttySurfaceView(workingDirectory: session.effectiveCwd,
                                      fontSize: session.fontSize.map(Float.init),
                                      command: command,
                                      autoFocus: !suppressAutoFocus, env: env)
        let sessionID = session.id
        view.onExit = { store.closeScratch(sessionID) }
        Self.wireStatusClear(view, store: store, sessionID: sessionID, pane: .scratch)
        // typing in the scratch counts as user activity: reset the window's auto-follow idle timer so an
        // idle fire can't change the underlying selection (hiding the per-session scratch) while you type
        // in it. destroySurface nils this, breaking the store -> surface -> closure retain cycle.
        view.onUserInput = { store.noteUserActivity() }
        // the scratch supports in-terminal search (⌘F), so wire the four onSearch* callbacks and mark it
        // searchable — pinned to the same session, like the main/split panes. Unlike the overlay/quick
        // terminal, the scratch behaves like a real pane (kept alive across hides), so a bar over it is safe.
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, library: library)
        return view
    }

    /// The `AGTERM_*` environment a tree surface (main / split / overlay / scratch) exposes to its spawned
    /// shell. The window id comes from the open store that owns the session (split/overlay/scratch inherit it
    /// via the same session); the workspace from the session's owning workspace; `AGTERM_SOCKET` is the path
    /// `ControlServer` will bind (resolved at init, so a launch-window shell that materializes before
    /// `start()` binds still sees it), honoring a test's `AGTERM_CONTROL_SOCKET` override. `pane` injects the
    /// matching `AGTERM_PANE` (`left`=main, `right`=split, `scratch`) so the hook wrapper forwards `--pane`
    /// and a status set from a background pane records which surface blocked; the overlay passes nil (no pane).
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
        return SurfaceEnvironment.session(sessionID: session.id, windowID: windowID,
                                          workspaceID: workspaceID, socketPath: controlServer.resolvedSocketPath,
                                          pane: pane)
    }

    /// The `AGTERM_*` environment a window's quick terminal exposes — scratch, not in the tree, so it
    /// carries only `AGTERM_ENABLED`, `AGTERM_WINDOW_ID`, and `AGTERM_SOCKET` (no workspace/session ids).
    @MainActor
    func quickTerminalEnv(for windowID: WindowInfo.ID) -> [String: String] {
        SurfaceEnvironment.quickTerminal(windowID: windowID, socketPath: controlServer.resolvedSocketPath)
    }
}
