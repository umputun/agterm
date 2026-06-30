import agtermCore
import AppKit
import SwiftUI

@main
struct agtermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @Environment(\.openWindow) private var openWindow

    @State private var library: WindowLibrary
    @State private var actions: AppActions
    @State private var palette = PaletteController()
    @State private var sessionSwitcher: SessionSwitcher
    @State private var paneShortcuts: PaneShortcuts
    @State private var settingsModel: SettingsModel
    @State private var controlServer: ControlServer
    @State private var customCommandRunner: CustomCommandRunner

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
        // the custom-command runner needs the keymap (settings) and the bound socket path (control
        // server) for the `{AGT_SOCKET}` token; built last so both are available.
        _customCommandRunner = State(initialValue: CustomCommandRunner(
            library: library, settings: settingsModel,
            socketProvider: { controlServer.resolvedSocketPath }))
    }

    /// The active SwiftUI shortcut for a built-in action, driven by the keymap: the user override when
    /// one is `map`ped, else the action's shipped default. `nil` when neither exists (a keyless action,
    /// or one of the four arrow-bound actions whose default can't round-trip through the keymap grammar)
    /// — the menu drops the shortcut for those (the arrow actions supply their own hardcoded fallback).
    /// Because `keymap` is `@Observable`, reading it here re-renders the menu shortcut on a reload.
    private func shortcut(for action: BuiltinAction) -> KeyboardShortcut? {
        settingsModel.keymap.equivalent(for: action).map(Self.toShortcut)
    }

    /// The shortcut for one of the six arrow-bound actions: the user override when `map`ped, else the
    /// hardcoded arrow default. Those defaults can't round-trip through the keymap grammar (`parseKeybind`
    /// has no arrow keys), so `defaultChord` is nil and the fallback lives here in one place — keyed by
    /// action so every arrow call site reads uniformly and the fallback set has a single home.
    private func arrowShortcut(for action: BuiltinAction) -> KeyboardShortcut {
        if let override = shortcut(for: action) { return override }
        switch action {
        case .focusLeftPane: return KeyboardShortcut(.leftArrow, modifiers: [.command, .option])
        case .focusRightPane: return KeyboardShortcut(.rightArrow, modifiers: [.command, .option])
        case .previousSession: return KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .nextSession: return KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .previousAttentionSession: return KeyboardShortcut(.upArrow, modifiers: [.control, .option])
        case .nextAttentionSession: return KeyboardShortcut(.downArrow, modifiers: [.control, .option])
        default: return KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
    }

    /// Map a host-free `Chord` to a SwiftUI `KeyboardShortcut`. The base key is a single printable
    /// character (`Character`) or one of the named keys the grammar allows (`tab`/`space`/`return`/
    /// `delete`); the modifiers map one-for-one. This is the menu-side mirror of the runner's
    /// `NSEvent`→`Chord` mapping.
    private static func toShortcut(_ chord: Chord) -> KeyboardShortcut {
        let key: KeyEquivalent
        switch chord.key {
        case "tab": key = .tab
        case "space": key = .space
        case "return": key = .return
        case "delete": key = .delete
        default: key = KeyEquivalent(Character(chord.key))
        }
        var modifiers: EventModifiers = []
        if chord.mods.contains(.control) { modifiers.insert(.control) }
        if chord.mods.contains(.command) { modifiers.insert(.command) }
        if chord.mods.contains(.option) { modifiers.insert(.option) }
        if chord.mods.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: modifiers)
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
                makeSurface: { Self.makeSurface(for: $0, store: $1, env: surfaceEnv(for: $0), library: library) },
                makeSplitSurface: { Self.makeSplitSurface(for: $0, store: $1, env: surfaceEnv(for: $0), library: library) },
                makeOverlaySurface: { Self.makeOverlaySurface(for: $0, store: $1, env: surfaceEnv(for: $0)) },
                makeScratchSurface: { session, store in
                    // suppress the scratch's creation autoFocus when a full overlay OR this window's quick
                    // terminal is already up — each renders above the scratch and owns focus.
                    let qtVisible = library.windowID(forSession: session.id)
                        .flatMap { QuickTerminalRegistry.shared.controller(for: $0) }?.isVisible ?? false
                    return Self.makeScratchSurface(for: session, store: store, env: surfaceEnv(for: session),
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
                    actions.customCommandRunner = customCommandRunner
                    // the action hub opens the .themes palette for the "Select Theme…" launcher + menu.
                    actions.palette = palette
                    // register the notification delegate + request authorization (idempotent), and
                    // hand it the action hub + library so a banner click can navigate to the firing
                    // pane and the capture side can stamp the firing window id into the identity.
                    NotificationManager.shared.actions = actions
                    NotificationManager.shared.library = library
                    NotificationManager.shared.start()
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
                }
        }
        // chromeless: no system title bar (the traffic lights float over our custom titlebar row in
        // ContentView), so there's no empty title-bar strip above our header.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            // App menu: replace the default "About agterm" with one that opens the standard
            // panel enriched with a clickable repo link and, on release builds, the build commit.
            CommandGroup(replacing: .appInfo) {
                Button("About agterm") { showAboutPanel() }
            }
            // File: replace the default "New" group with all of agterm's creation/management actions,
            // grouped by entity into three sections — Window, then Workspace, then Session. The
            // system Close / Close All commands stay below in their own group.
            CommandGroup(replacing: .newItem) {
                // Window: create/open/rename/delete the top-level window bundles. Open Window lists
                // the library with a checkmark on already-open ones (picking a closed one opens it,
                // an open one raises it). Delete is disabled with one window left (keep-at-least-one).
                Button("New Window") { actions.newWindow() }
                    .keyboardShortcut(shortcut(for: .newWindow))
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
                    .keyboardShortcut(shortcut(for: .renameWindow))
                Button("Delete Window") { actions.deleteActiveWindow() }
                    .keyboardShortcut(shortcut(for: .deleteWindow))
                    .disabled(!library.canRemoveWindow)

                Divider()
                // Workspace.
                Button("New Workspace") { actions.newWorkspace() }
                    .keyboardShortcut(shortcut(for: .newWorkspace))
                Button("Rename Workspace") { actions.renameActiveWorkspace() }
                    .keyboardShortcut(shortcut(for: .renameWorkspace))
                    .disabled(library.activeStore?.currentWorkspaceID == nil)
                Button("Delete Workspace") { actions.deleteActiveWorkspace() }
                    .keyboardShortcut(shortcut(for: .deleteWorkspace))
                    .disabled(library.activeStore?.canRemoveWorkspace != true)

                Divider()
                // Session. Open Directory… opens a new session rooted at a chosen folder; Close
                // Session is terminal-style ⌘W (closes the active session, or the window when none).
                Button("New Session") { actions.newSession() }
                    .keyboardShortcut(shortcut(for: .newSession))
                Button("Open Directory…") { actions.openDirectory() }
                    .keyboardShortcut(shortcut(for: .openDirectory))
                Button("Rename Session") { actions.renameActiveSession() }
                    .keyboardShortcut(shortcut(for: .renameSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button("Close Session") {
                    // closeActiveSession dismisses any cover (quick terminal / overlay / scratch) or closes the
                    // active session; only when it handled nothing (no cover, no session) fall back to the window.
                    if !actions.closeActiveSession() { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut(shortcut(for: .closeSession))
                Button("Clear Status") { actions.clearActiveSessionStatus() }
                    .keyboardShortcut(shortcut(for: .clearStatus))
                    .disabled(library.activeStore?.activeSession == nil)
                Divider()
                // open keymap.conf in $EDITOR in a 95% overlay over the active session; it reloads on the
                // editor exiting. Keyless, like Reload Keymap.
                Button { actions.editKeymap() } label: { Label("Edit Keymap…", systemImage: "pencil") }
                // re-read keymap.conf and apply (menu shortcuts re-render, the runner + palette rebuild).
                // Keyless — a future BuiltinAction could give it a default chord.
                Button { actions.reloadKeymap() } label: { Label("Reload Keymap", systemImage: "keyboard") }
                // open the agterm-scoped ghostty.conf in $EDITOR in a 95% overlay; it reloads the config on
                // the editor exiting. Keyless, like Edit Keymap.
                Button { actions.editGhosttyConfig() } label: { Label("Edit ghostty.conf…", systemImage: "slider.horizontal.3") }
                // re-read ghostty.conf and rebroadcast to every surface; warns with a banner on a
                // malformed file. Keyless, like Reload Keymap.
                Button { actions.reloadGhosttyConfig() } label: { Label("Reload Config", systemImage: "arrow.clockwise") }
            }
            // View: font zoom (drives ghostty on the focused terminal), the status-bar toggle, and
            // split / quick terminal / palettes. The menu reserves an icon column because the system
            // "Enter Full Screen" item has an icon, so every custom item carries an SF Symbol too —
            // otherwise they render as blank, indented slots.
            CommandGroup(after: .toolbar) {
                Button { actions.increaseFontSize() } label: { Label("Increase Font Size", systemImage: "textformat.size.larger") }
                    .keyboardShortcut(shortcut(for: .increaseFontSize))
                Button { actions.decreaseFontSize() } label: { Label("Decrease Font Size", systemImage: "textformat.size.smaller") }
                    .keyboardShortcut(shortcut(for: .decreaseFontSize))
                Button { actions.resetFontSize() } label: { Label("Actual Size", systemImage: "textformat.size") }
                    .keyboardShortcut(shortcut(for: .resetFontSize))
                // open the live-preview theme picker (the .themes palette). Keyless by default like Edit
                // Keymap; rebindable via select_theme. The control half is theme.set / theme.list.
                Button { actions.openThemePalette() } label: { Label("Select Theme…", systemImage: "paintpalette") }
                    .keyboardShortcut(shortcut(for: .selectTheme))
                Divider()
                let sidebarShown = library.activeStore?.sidebarVisible ?? true
                Button { actions.toggleSidebar() } label: {
                    Label(sidebarShown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut(shortcut(for: .toggleSidebar))
                // expand every workspace / collapse all but the active one. plain (non-BuiltinAction)
                // keyless items like Reload Keymap; disabled with no active store or in flagged mode
                // (no workspace rows to expand/collapse). The control half is sidebar.expand/collapse.
                let treeMode = library.activeStore?.sidebarMode == .tree
                Button { actions.expandAllWorkspaces() } label: { Label("Expand Workspaces", systemImage: "chevron.down") }
                    .disabled(library.activeStore == nil || !treeMode)
                Button { actions.collapseOtherWorkspaces() } label: { Label("Collapse Workspaces", systemImage: "chevron.right") }
                    .disabled(library.activeStore == nil || !treeMode)
                // flip the sidebar between the workspace tree and the flat flagged working-set list.
                // single 2-state item like the sidebar/scratch toggles; keyless by default (rebindable
                // via toggle_flagged_view). The control half is sidebar.mode.
                let flaggedMode = library.activeStore?.sidebarMode == .flagged
                // disabled (along with its shortcut) when there's nothing to show: tree mode + no flags.
                // Enabled in flagged mode so it can always switch back to the tree.
                let noFlaggedToShow = !flaggedMode && (library.activeStore?.flaggedSessions.isEmpty ?? true)
                Button { actions.toggleFlaggedView() } label: {
                    Label(flaggedMode ? "Show All Sessions" : "Show Flagged Sessions", systemImage: "flag")
                }
                .keyboardShortcut(shortcut(for: .toggleFlaggedView))
                .disabled(noFlaggedToShow)
                let sessionFlagged = library.activeStore?.activeSession?.flagged == true
                Button { actions.toggleFlagActiveSession() } label: {
                    Label(sessionFlagged ? "Unflag Session" : "Flag Session", systemImage: "flag.badge.ellipsis")
                }
                .keyboardShortcut(shortcut(for: .toggleFlag))
                .disabled(library.activeStore?.activeSession == nil)
                Button { actions.clearFlags() } label: { Label("Clear Flagged", systemImage: "flag.slash") }
                    .disabled(library.activeStore?.flaggedSessions.isEmpty ?? true)
                // collapse the tree to the current workspace's subtree (or unfocus when already focused).
                // keyless by default (rebindable via focus_workspace). The control half is workspace.focus.
                // the label tracks the toggle (Focus/Unfocus) like the workspace row's context-menu item.
                let focusStore = library.activeStore
                let currentFocused = focusStore?.focusedWorkspace?.id == focusStore?.currentWorkspaceID
                Button { actions.focusActiveWorkspace() } label: {
                    Label(currentFocused ? "Unfocus Workspace" : "Focus Workspace", systemImage: "scope")
                }
                .keyboardShortcut(shortcut(for: .focusWorkspace))
                .disabled(library.activeStore?.currentWorkspaceID == nil)
                // plain (non-BuiltinAction) clear, like Clear Flagged; the bottom-bar pill ✕ is primary.
                Button { actions.clearFocus() } label: { Label("Clear Focus", systemImage: "scope") }
                    .disabled(library.activeStore?.focusedWorkspaceID == nil)
                Button { actions.toggleSplit() } label: {
                    Label(library.activeStore?.activeSession?.isSplit == true ? "Hide Split" : "Split Right", systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut(shortcut(for: .toggleSplit))
                .disabled(library.activeStore?.activeSession == nil)
                let scratchShown = library.activeStore?.activeSession?.scratchActive == true
                Button { actions.toggleScratch() } label: {
                    // static neutral icon like the Split menu item above; state is shown by the label text.
                    Label(scratchShown ? "Hide Scratch" : "Show Scratch", systemImage: "rectangle")
                }
                .keyboardShortcut(shortcut(for: .toggleScratch))
                .disabled(library.activeStore?.activeSession == nil)
                // search the focused terminal's scrollback. data-driven shortcut (⌘F default) like the
                // toggles above — no hardcoded literal; the bar's open/close toggle lives in onSearchStart.
                Button { actions.toggleSearch() } label: { Label("Find…", systemImage: "magnifyingglass") }
                    .keyboardShortcut(shortcut(for: .toggleSearch))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.toggleQuickTerminal() } label: { Label("Quick Terminal", systemImage: "terminal") }
                    .keyboardShortcut(shortcut(for: .quickTerminal))
            }
            // a dedicated Navigate menu keeps the View menu scannable: moving the selection/focus between
            // existing sessions and split panes lives here — the palettes that jump to a session/command,
            // the spatial session stepping, and the pane focus. all drive the SAME AppActions the View items
            // did; only their menu home changed (the control API / palette / keymap surfaces are untouched).
            CommandMenu("Navigate") {
                Button { palette.toggle(.sessions) } label: { Label("Go to Session", systemImage: "rectangle.stack") }
                    .keyboardShortcut(shortcut(for: .sessionPalette))
                Button { palette.toggle(.actions) } label: { Label("Command Palette", systemImage: "command") }
                    .keyboardShortcut(shortcut(for: .commandPalette))
                Button { palette.toggle(.customCommands) } label: { Label("Custom Commands", systemImage: "terminal") }
                    .keyboardShortcut(shortcut(for: .customCommandPalette))
                Button { actions.toggleAttentionPalette() } label: { Label("Go to Attention…", systemImage: "bell") }
                    .keyboardShortcut(shortcut(for: .showAttention))
                Divider()
                // step between sessions in the sidebar's flattened order. Prev/Next ride ⌥⌘↑/↓ (NOT bare
                // ⌘+arrows, which shadow text-field caret nav in the rename/palette/settings fields); ⌥⌘↑/↓
                // sessions complements the ⌥⌘←/→ pane focus below (left/right = panes, up/down = sessions).
                // First/Last get no key (menu + palette + control only). Real menu items so AppKit menu
                // dispatch swallows the shortcut before libghostty — never leaked to the shell.
                Button { actions.selectPreviousSession() } label: { Label("Previous Session", systemImage: "chevron.up") }
                    .keyboardShortcut(arrowShortcut(for: .previousSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.selectNextSession() } label: { Label("Next Session", systemImage: "chevron.down") }
                    .keyboardShortcut(arrowShortcut(for: .nextSession))
                    .disabled(library.activeStore?.activeSession == nil)
                // step only through sessions needing attention (blocked/completed glyphs), wrapping. ⌃⌥↑/↓
                // are arrow-bound like the session nav above, so they ride arrowShortcut's hardcoded fallback.
                Button { actions.selectPreviousAttentionSession() } label: { Label("Previous Attention Session", systemImage: "chevron.up.circle") }
                    .keyboardShortcut(arrowShortcut(for: .previousAttentionSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.selectNextAttentionSession() } label: { Label("Next Attention Session", systemImage: "chevron.down.circle") }
                    .keyboardShortcut(arrowShortcut(for: .nextAttentionSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.selectFirstSession() } label: { Label("First Session", systemImage: "arrow.up.to.line") }
                    .keyboardShortcut(shortcut(for: .firstSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.selectLastSession() } label: { Label("Last Session", systemImage: "arrow.down.to.line") }
                    .keyboardShortcut(shortcut(for: .lastSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Divider()
                // arrow-bound actions: their default ⌘⌥←/→ can't round-trip through the keymap grammar
                // (parseKeybind has no arrow keys), so defaultChord is nil and the hardcoded arrow is the
                // FALLBACK — a user override (a parseable chord) wins. arrowShortcut(for:) owns the four
                // fallbacks in one place.
                Button { actions.focusPane(.main) } label: {
                    Label("Focus Left Pane", systemImage: "rectangle.lefthalf.filled")
                }
                .keyboardShortcut(arrowShortcut(for: .focusLeftPane))
                .disabled(library.activeStore?.activeSession?.hasSplit != true)
                Button { actions.focusPane(.split) } label: {
                    Label("Focus Right Pane", systemImage: "rectangle.righthalf.filled")
                }
                .keyboardShortcut(arrowShortcut(for: .focusRightPane))
                .disabled(library.activeStore?.activeSession?.hasSplit != true)
            }
            CommandGroup(replacing: .help) {
                Button("Developer Documentation…") {
                    if let url = URL(string: "https://github.com/umputun/agterm#scripting-agterm") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Install Command Line Tool…") { CLIInstaller.run() }
                Button("Install Agent Status Hooks…") { AgentHooksInstaller.run() }
                Button("Install Agent Skill…") { SkillInstaller.run() }
            }
        }

        Settings {
            SettingsView(model: settingsModel)
        }
    }

    /// Opens the standard About panel, enriched with a clickable repository link and — on release
    /// builds, where `GIT_COMMIT` is baked into the bundle — the short build commit shown in the
    /// version's parenthetical. Dev builds (no baked commit) fall back to the plain version.
    private func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        let repo = "https://github.com/umputun/agterm"
        if let url = URL(string: repo) {
            options[.credits] = NSAttributedString(string: repo, attributes: [
                .link: url,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ])
        }
        if let commit = Bundle.main.infoDictionary?["GitCommit"] as? String, !commit.isEmpty, commit != "unknown" {
            options[.version] = commit
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
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
        // restore-running-command: feed the captured foreground command as `initial_input` (re-run inside
        // the login shell, exits to a prompt) — but only when there's no `initialCommand` (those are
        // mutually exclusive ways to seed a surface). Consumed run-once, like `scratchCommand`.
        let restoreInput = Self.restoreInitialInput(session.foregroundCommand)
        session.foregroundCommand = nil
        let view = GhosttySurfaceView(workingDirectory: session.initialCwd, fontSize: session.fontSize.map(Float.init),
                                      command: session.initialCommand,
                                      initialInput: session.initialCommand == nil ? restoreInput : nil, env: env)
        view.session = session
        let sessionID = session.id
        view.onExit = {
            store.closePrimaryPane(sessionID)
            // focus the surviving (now maximized) pane; if the whole (single) session closed instead,
            // focus the session it reselected to. the collapse/switch re-hosts the target, so use the retry.
            let target = store.session(withID: sessionID)?.activeSurface ?? store.activeSession?.activeSurface
            (target as? GhosttySurfaceView)?.focusAfterReparent()
        }
        view.onFocusChange = { focused in
            guard focused else { return }
            store.session(withID: sessionID)?.splitFocused = false
            // focusing a pane means you've seen the session: clear the badge and any delivered banners.
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        view.onUserInputClearsStatus = { store.setAgentIndicator(AgentIndicator(), forSession: sessionID) }
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
            let target = store.session(withID: sessionID)?.activeSurface ?? store.activeSession?.activeSurface
            (target as? GhosttySurfaceView)?.focusAfterReparent()
        }
        view.onFocusChange = { focused in
            guard focused else { return }
            store.session(withID: sessionID)?.splitFocused = true
            store.clearUnseen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        view.onUserInputClearsStatus = { store.setAgentIndicator(AgentIndicator(), forSession: sessionID) }
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, library: library)
        return view
    }

    /// The fixed wrapper that runs the overlay command and records its exit status to a temp file.
    /// stdout/stderr are NOT redirected (so a TUI renders normally); only the status is captured —
    /// libghostty's child-exited status reflects the login-shell wrapper, not the command. The real
    /// command + the temp path ride in env (`AGTERM_OVL_CMD`/`AGTERM_OVL_CODE`), never interpolated, so
    /// there is no shell-quoting of user data. The subshell makes an inline `exit N` propagate to `$?`.
    private static let overlayExitWrapper = "sh -c '( eval \"$AGTERM_OVL_CMD\" ); echo $? > \"$AGTERM_OVL_CODE\"'"

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
        overlayEnv["AGTERM_OVL_CMD"] = session.overlayCommand ?? ""
        overlayEnv["AGTERM_OVL_CODE"] = codeFile
        let view = GhosttySurfaceView(workingDirectory: session.overlayCwd ?? session.effectiveCwd,
                                      fontSize: session.fontSize.map(Float.init), command: overlayExitWrapper,
                                      waitAfterCommand: session.overlayWait, autoFocus: true, env: overlayEnv)
        view.overlayCodeFile = codeFile
        // record the exit status on teardown (the surface always tears down through destroySurface), so
        // it survives an explicit session.overlay.close that bypasses onExit. a session/window force-close
        // removes the session first, so this no-ops there — but the result is unqueryable after that anyway.
        view.onExitCodeCaptured = { store.recordOverlayExit(sessionID, code: $0) }
        view.onExit = { store.closeOverlay(sessionID) }
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
        // the scratch supports in-terminal search (⌘F), so wire the four onSearch* callbacks and mark it
        // searchable — pinned to the same session, like the main/split panes. Unlike the overlay/quick
        // terminal, the scratch behaves like a real pane (kept alive across hides), so a bar over it is safe.
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, library: library)
        return view
    }

    /// The `AGTERM_*` environment a tree surface (main / split / overlay) exposes to its spawned shell.
    /// The window id comes from the open store that owns the session (split/overlay inherit it via
    /// the same session); the workspace from the session's owning workspace; `AGTERM_SOCKET` is the path
    /// `ControlServer` will bind (resolved at init, so a launch-window shell that materializes before
    /// `start()` binds still sees it), honoring a test's `AGTERM_CONTROL_SOCKET` override.
    @MainActor
    private func surfaceEnv(for session: Session) -> [String: String] {
        var env = ["AGTERM_ENABLED": "1", "AGTERM_SESSION_ID": session.id.uuidString,
                   "AGTERM_SOCKET": controlServer.resolvedSocketPath]
        if let windowID = library.windowID(forSession: session.id) {
            env["AGTERM_WINDOW_ID"] = windowID.uuidString
            if let workspace = library.store(for: windowID)?.workspace(forSession: session.id) {
                env["AGTERM_WORKSPACE_ID"] = workspace.id.uuidString
            }
        }
        return env
    }

    /// The `AGTERM_*` environment a window's quick terminal exposes — scratch, not in the tree, so it
    /// carries only `AGTERM_ENABLED`, `AGTERM_WINDOW_ID`, and `AGTERM_SOCKET` (no workspace/session ids).
    @MainActor
    func quickTerminalEnv(for windowID: WindowInfo.ID) -> [String: String] {
        ["AGTERM_ENABLED": "1", "AGTERM_WINDOW_ID": windowID.uuidString,
         "AGTERM_SOCKET": controlServer.resolvedSocketPath]
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
        // the adaptive icon. Let LaunchServices render the bundle icon.
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
            && window.title == "agterm"
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
        alert.messageText = "Quit agterm?"
        alert.informativeText = QuitPrompt.message(windows: counts.windows, sessions: counts.sessions)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_: Notification) {
        controlServer?.stop()
        customCommandRunner?.stop()
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
