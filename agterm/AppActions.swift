import agtermCore
import AppKit

/// The user-facing actions shared by the toolbar / bottom-bar buttons (`ContentView`) and the
/// menu bar (`agtermApp`'s `.commands`), so the two never drift. `@MainActor`; holds the store, and
/// resolves the focused terminal for font commands.
///
/// Trivial one-liners (quick-terminal toggle, status-bar toggle) are not here — their callers
/// invoke the controller/store directly. This type owns the actions that carry real logic:
/// new-session placement, the directory picker, and the split/focus/font handling.
@MainActor
final class AppActions {
    /// The window library; the action seam resolves the frontmost window's store per call rather
    /// than holding a fixed store, so the menu bar / palette / control channel all drive the
    /// window the user is looking at.
    let library: WindowLibrary

    /// The store of the frontmost open window — the target of every mutating action. Nil only in
    /// the degenerate all-windows-closed state (quitting), in which case the callers no-op.
    var store: AppStore? { library.activeStore }

    /// The frontmost window's quick-terminal controller (each window owns its own), resolved through
    /// the same frontmost-window accessor as `store`. Nil when no window is open.
    private var frontmostQuickTerminal: QuickTerminalController? {
        QuickTerminalRegistry.shared.controller(for: library.activeWindowID)
    }

    /// Set briefly while a rename is being started, so the focus-restore that runs when a palette
    /// or the quick terminal closes doesn't steal first responder from the inline rename field.
    private var renamePending = false

    /// Opens (or raises) the on-screen window for a window id. The scene's `openWindow` is a SwiftUI
    /// `@Environment` value only reachable inside the scene, so `agtermApp` wires this at launch
    /// (`enqueueClaim` + `openWindow(id:)`, raising an already-open one via `WindowRegistry`). Used by
    /// the cross-window notification reveal to surface a banner-clicked session whose window had
    /// closed. Nil before the scene `.task` runs (no window to reveal into yet anyway).
    var openWindow: ((WindowInfo.ID) -> Void)?

    /// The settings model, holding the parsed keymap whose custom commands feed the action palette.
    /// Both this and `customCommandRunner` are constructed AFTER `actions` in `agtermApp.init`, so they
    /// are settable properties wired in the scene `.task` (like `NotificationManager.shared.actions`)
    /// rather than init parameters — keeping the `init(library:)` signature and dodging the init-order
    /// break. Nil before the scene `.task` runs (no custom commands in the palette yet).
    var settingsModel: SettingsModel?

    /// The custom-command runner that the palette's custom items invoke (`run(_:)`). Wired in the
    /// scene `.task` alongside `settingsModel` for the same construction-order reason.
    var customCommandRunner: CustomCommandRunner?

    /// The command-palette controller, so the "Select Theme…" action and the View menu item can open
    /// the `.themes` palette. Wired in the scene `.task` (the controller is `agtermApp` `@State`).
    var palette: PaletteController?

    /// The theme captured when the theme picker opened, restored on Esc/cancel. `themePreviewActive`
    /// gates the preview/commit/cancel so the hooks are inert outside the picker (the palette's other
    /// modes never touch them).
    var themePreviewActive = false
    var themePreviewOriginal: String?

    init(library: WindowLibrary) {
        self.library = library
    }

    // MARK: - Workspaces & sessions

    func newWorkspace() {
        guard let store else { return }
        store.addWorkspace(name: store.defaultWorkspaceName)
    }

    func newSession() {
        guard let store, let workspaceID = store.currentWorkspaceID,
              let session = store.addSession(toWorkspace: workspaceID, cwd: resolvedNewSessionCwd())
        else { return }
        store.selectSession(session.id)
        focusActiveSession()
    }

    /// The working directory a new session should open in, resolved from the new-session-directory setting
    /// (home / the current session's cwd / a fixed custom dir) against the active session's focused-pane
    /// cwd. Shared by `newSession()` and the sidebar's workspace-row New Session so both entry points honor
    /// the setting. Falls back to home when `settingsModel` isn't wired yet (before the scene `.task`) or
    /// the setting resolves there. Read as the `addSession` argument, so it captures the active session's
    /// cwd BEFORE the new session exists.
    func resolvedNewSessionCwd() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return settingsModel?.settings.resolveNewSessionCwd(
            currentSessionCwd: store?.activeSession?.focusedCwd, home: home) ?? home
    }

    func openDirectory() {
        guard let store, let workspaceID = store.currentWorkspaceID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a directory for the new session"
        guard panel.runModal() == .OK, let url = panel.url,
              let session = store.addSession(toWorkspace: workspaceID, cwd: url.path)
        else { return }
        store.selectSession(session.id)
        focusActiveSession()
    }

    // closes the active session, or dismisses a focus-stealing cover on top of it. returns whether it
    // handled the keystroke, so the ⌘W menu item falls back to closing the window only when nothing was
    // dismissed or closed (no cover, no session). precedence follows the z-order: the quick terminal is
    // window-topmost (works even with no active session), then within a session an overlay sits above the
    // scratch. the overlay is destroyed (closeOverlay, run-once ephemeral) while the quick terminal and
    // scratch are hidden keep-alive; a floating overlay also holds first responder, so ANY overlay is
    // dismissed, not only a full one.
    @discardableResult
    func closeActiveSession() -> Bool {
        if let quick = frontmostQuickTerminal, quick.isVisible { quick.hide(); return true }
        guard let store, let session = store.activeSession else { return false }
        if session.overlayActive { store.closeOverlay(session.id); return true }
        if session.scratchActive { store.toggleScratch(session.id); return true }
        // ⌘W was handled either way — on cancel we return true so the File menu doesn't fall back to
        // closing the whole window.
        guard confirmCloseSession(session) else { return true }
        store.closeSession(session.id)
        focusActiveSession()
        return true
    }

    /// Close the session with `id` in `store` from a GUI surface (the sidebar row's Close), honoring the
    /// "Confirm before closing a session" setting. `store` is the caller's own window-local store — a
    /// background window's sidebar must close ITS session, not the frontmost window's — so it is passed in
    /// rather than resolved via the frontmost `activeStore`. The ⌘W/menu/palette path uses
    /// `closeActiveSession` (which acts on the frontmost active session); the control channel's
    /// `session.close` closes directly, without a prompt.
    func closeSession(_ id: UUID, in store: AppStore) {
        guard let session = store.session(withID: id) else { return }
        guard confirmCloseSession(session) else { return }
        store.closeSession(id)
    }

    /// A native warning confirm before closing `session`, gated by `AppSettings.confirmCloseSession`.
    /// Returns whether to proceed with the close: true immediately (no prompt) when the setting is off, or
    /// under an XCUITest launch (a modal would hang the test, like the clear-flagged/quit confirms).
    private func confirmCloseSession(_ session: Session) -> Bool {
        guard settingsModel?.settings.confirmCloseSession == true, !ContentView.isUITestLaunch else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(session.displayName)”?"
        alert.informativeText = "The session and everything running in it will be closed."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Clear the active session's agent-status indicator back to idle (the same effect as `agtermctl
    /// session status idle` and the sidebar row's "Clear Status"). No-op when nothing is selected.
    func clearActiveSessionStatus() {
        guard let store, let id = store.selectedSessionID else { return }
        store.setAgentIndicator(AgentIndicator(), forSession: id)
    }

    /// Re-read and re-parse `keymap.conf`, re-rendering the data-driven menu shortcuts and rebuilding
    /// the custom-command runner + the palette's custom items. Shared by the View menu item, the
    /// action palette, and the control channel (`keymap.reload`). No-op before the scene wires the
    /// settings model.
    func reloadKeymap() { settingsModel?.reloadKeymap() }

    /// The session whose currently-open overlay is the keymap editor, so `WindowContentView`'s overlay
    /// onChange can reload the keymap when that overlay closes. Nil when no keymap-edit overlay is up.
    var keymapEditOverlaySession: UUID?

    /// Open `keymap.conf` in the user's editor (`$VISUAL`/`$EDITOR`, else `vi`) in a 95% floating overlay
    /// over the active session. The overlay runs through the login shell, so an `$EDITOR` exported from
    /// the user's login-shell startup is honored. On the editor exiting, the keymap is reloaded (the
    /// overlay-close onChange in `WindowContentView`). No-op with no active session, before the settings
    /// model is wired, or when an overlay is already open.
    func editKeymap() {
        guard let store, let id = store.selectedSessionID, let path = settingsModel?.keymapPath else { return }
        if store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95) {
            keymapEditOverlaySession = id
        }
    }

    /// Re-read the ghostty config and rebroadcast it to every live surface (the warning banner on
    /// diagnostics is posted by `SettingsModel.reloadGhosttyConfig`, mirroring `reloadKeymap`). Returns the
    /// config-diagnostic count (0 = clean, or 0 before the scene wires the settings model) so the control
    /// channel can report the value the reload actually produced. Shared by the File ▸ Reload Config menu
    /// item, the action palette, the Edit-ghostty overlay close, and the `config.reload` control channel.
    @discardableResult
    func reloadGhosttyConfig() -> Int {
        settingsModel?.reloadGhosttyConfig() ?? 0
    }

    /// The session whose currently-open overlay is the ghostty.conf editor, so `WindowContentView`'s overlay
    /// onChange can reload the config when that overlay closes. Nil when no ghostty-edit overlay is up.
    var ghosttyEditOverlaySession: UUID?

    /// The `ghostty.conf` contents captured when the Edit-ghostty overlay opened, so the overlay-close path
    /// can skip the reload (and its per-session font-zoom reset) on a no-op editor session. Nil when no
    /// ghostty-edit overlay is up.
    private var ghosttyEditOverlaySnapshot: String?

    /// Open `ghostty.conf` in the user's editor (`$VISUAL`/`$EDITOR`, else `vi`) in a 95% floating overlay
    /// over the active session, mirroring `editKeymap`. The overlay runs through the login shell, so an
    /// `$EDITOR` exported from the user's login-shell startup is honored. Captures the file contents so the
    /// overlay-close path can reload only when the file actually changed. On the editor exiting, the config
    /// is reloaded (the overlay-close onChange in `WindowContentView`). No-op with no active session, before
    /// the settings model is wired, or when an overlay is already open.
    func editGhosttyConfig() {
        guard let store, let id = store.selectedSessionID, let path = settingsModel?.ghosttyConfigPath else { return }
        if store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95) {
            ghosttyEditOverlaySession = id
            ghosttyEditOverlaySnapshot = try? String(contentsOfFile: path, encoding: .utf8)
        }
    }

    /// Called when the Edit-ghostty overlay closes: reload the config only if the file actually changed
    /// since the editor opened, so a no-op open/close does not clear per-session ⌘+/⌘− zoom (the reload's
    /// font reset). The explicit File ▸ Reload Config / `config.reload` paths stay unconditional by design
    /// (the user asked to reload); this guard covers only the editor round-trip.
    func reloadGhosttyConfigIfEdited() {
        let before = ghosttyEditOverlaySnapshot
        ghosttyEditOverlaySnapshot = nil
        let after = settingsModel.flatMap { try? String(contentsOfFile: $0.ghosttyConfigPath, encoding: .utf8) }
        guard before != after else { return }
        reloadGhosttyConfig()
    }

    /// Step the selection to the previous/next session, or jump to the first/last, in the sidebar's
    /// flattened visual order (`navigateSession` owns the logic so the GUI, palette, and control
    /// channel can't drift). Each routes through `selectSession` (recency/badge/persist/workspace)
    /// then moves first responder into the moved-to session's focused pane.
    func selectNextSession() { store?.navigateSession(.next); focusActiveSession() }
    func selectPreviousSession() { store?.navigateSession(.previous); focusActiveSession() }
    func selectFirstSession() { store?.navigateSession(.first); focusActiveSession() }
    func selectLastSession() { store?.navigateSession(.last); focusActiveSession() }

    /// Step to the next/previous session needing attention (status `blocked` or `completed`), wrapping
    /// around and skipping idle/active sessions. Shares `navigateSession` with the GUI, palette, and the
    /// `session.go next-attention|prev-attention` control command.
    func selectNextAttentionSession() { store?.navigateSession(.nextAttention); focusActiveSession() }
    func selectPreviousAttentionSession() { store?.navigateSession(.previousAttention); focusActiveSession() }

    /// Delete a workspace and all of its sessions. Confirms first when the workspace still has
    /// sessions (the delete ends their shells); an empty workspace deletes without a prompt.
    /// No-ops when only one workspace remains — one is always kept.
    func deleteWorkspace(_ workspaceID: UUID) {
        guard let store, store.canRemoveWorkspace,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        if !workspace.sessions.isEmpty, !confirmDeleteWorkspace(workspace) { return }
        store.removeWorkspace(workspaceID)
    }

    /// Delete the current workspace (the one new sessions land in) — used by the menu bar and the
    /// action palette, which have no clicked row.
    func deleteActiveWorkspace() {
        guard let store, let id = store.currentWorkspaceID else { return }
        deleteWorkspace(id)
    }

    private func confirmDeleteWorkspace(_ workspace: Workspace) -> Bool {
        confirmDelete(name: workspace.name, sessionCount: workspace.sessions.count)
    }

    /// A standard warning confirm for deleting a named container (workspace or window) that still
    /// holds `sessionCount` sessions — the delete ends their running shells. Returns whether the user
    /// confirmed.
    private func confirmDelete(name: String, sessionCount: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = sessionCount == 1
            ? "This closes its session and ends the running shell."
            : "This closes \(sessionCount) sessions and ends their running shells."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Move a session to another workspace (used by the palette's "Move Session to …" items).
    func moveSession(_ sessionID: UUID, toWorkspace workspaceID: UUID) {
        store?.moveSession(sessionID, toWorkspace: workspaceID)
    }

    /// Focus (or unfocus) a workspace — collapses the sidebar tree to that workspace's subtree, or clears
    /// focus when it is already the focused one. Driven by the sidebar workspace row's "Focus"/"Unfocus"
    /// context-menu item. Clean no-op on an unknown id.
    func focusWorkspace(_ id: UUID) {
        guard let store, store.workspaces.contains(where: { $0.id == id }) else { return }
        store.setFocusedWorkspace(store.focusedWorkspaceID == id ? nil : id)
    }

    /// Focus (or unfocus) the current workspace (the one new sessions land in) — the entry point for the
    /// `focus_workspace` keybind, the View menu, and the action palette, which have no clicked row.
    /// No-op when there is no current workspace.
    func focusActiveWorkspace() {
        guard let id = store?.currentWorkspaceID else { return }
        focusWorkspace(id)
    }

    /// Clear any workspace focus, restoring the full tree. A plain menu/palette "Clear Focus" item (the
    /// bottom-bar pill's ✕ is the primary affordance); no-op when nothing is focused.
    func clearFocus() {
        guard let store, store.focusedWorkspaceID != nil else { return }
        store.setFocusedWorkspace(nil)
    }

    // MARK: - Sidebar tree expansion

    /// Expand every workspace in the frontmost window's sidebar (the GUI menu/palette target). No-op when
    /// no window is open.
    func expandAllWorkspaces() {
        guard let store else { return }
        expandAllWorkspaces(in: store)
    }

    /// Expand every workspace in `store`'s window's sidebar. The sidebar owns the outline, so this posts a
    /// notification carrying that store as the object; `WorkspaceSidebar.Coordinator` registers its
    /// observer with `object: store`, so only that one window's sidebar acts. A graceful no-op in flagged
    /// mode (no workspace rows). The `sidebar.expand` control command targets a specific (default
    /// frontmost) window's store this way.
    func expandAllWorkspaces(in store: AppStore) {
        NotificationCenter.default.post(name: .agtermExpandWorkspaces, object: store)
    }

    /// Collapse every workspace except the active one in the frontmost window's sidebar (the GUI
    /// menu/palette target). No-op when no window is open.
    func collapseOtherWorkspaces() {
        guard let store else { return }
        collapseOtherWorkspaces(in: store)
    }

    /// Collapse every workspace except the active one (the workspace of the active session) in `store`'s
    /// window's sidebar, keeping that workspace expanded and scrolled into view. Scoped by the store
    /// object to that window's Coordinator (see `expandAllWorkspaces(in:)`); a graceful no-op in flagged
    /// mode. The `sidebar.collapse` control command targets a specific (default frontmost) window this way.
    func collapseOtherWorkspaces(in store: AppStore) {
        NotificationCenter.default.post(name: .agtermCollapseWorkspaces, object: store)
    }

    // MARK: - Flagged working-set

    /// Toggle a session's flagged membership (the durable flagged working-set the flat sidebar view
    /// projects). Flips the current state; clean no-op on an unknown id. Driven by the sidebar row's
    /// "Flag"/"Unflag" context-menu item.
    func toggleFlag(_ sessionID: UUID) {
        guard let store, let session = store.session(withID: sessionID) else { return }
        store.setFlag(!session.flagged, forSession: sessionID)
    }

    /// Toggle the active session's flag — used by the menu bar and the action palette, which have no
    /// clicked row. No-op when nothing is selected.
    func toggleFlagActiveSession() {
        guard let id = store?.selectedSessionID else { return }
        toggleFlag(id)
    }

    /// Flip the sidebar between the normal workspace tree and the flat flagged working-set list.
    /// Shared by the bottom-bar toggle, the View menu item, the action palette, and the `sidebar.mode`
    /// control command. The view animates the switch via `ContentView`'s `.animation(value:)`.
    func toggleFlaggedView() {
        guard let store else { return }
        store.setSidebarMode(store.sidebarMode == .flagged ? .tree : .flagged)
    }

    /// Unflag every session across all workspaces. Confirms first when at least one session is flagged
    /// (clearing the working-set is a bulk change worth confirming); does nothing when nothing is
    /// flagged. Skips the confirm under an XCUITest launch (a modal would hang the test).
    func clearFlags() {
        guard let store, !store.flaggedSessions.isEmpty else { return }
        if !ContentView.isUITestLaunch, !confirmClearFlags(count: store.flaggedSessions.count) { return }
        store.clearFlags()
    }

    /// A standard warning confirm for clearing the flagged working-set (`count` flagged sessions).
    /// Returns whether the user confirmed.
    private func confirmClearFlags(count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear flagged sessions?"
        alert.informativeText = count == 1
            ? "This unflags 1 session. The session itself is not closed."
            : "This unflags \(count) sessions. The sessions themselves are not closed."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Windows

    /// Create a fresh window (one default workspace + session) and open its on-screen window via the
    /// scene's window opener (the same seam the control channel uses). No-op if the opener isn't wired
    /// yet (before the scene `.task` runs there's no window to open into).
    func newWindow() {
        let info = library.newWindow()
        openWindow?(info.id)
    }

    /// Surface a window: raise it if already open, else open it (the opener claims its id + spawns a
    /// new on-screen window). Used by the File ▸ Open Window submenu and the palette.
    func openWindow(_ id: WindowInfo.ID) {
        openWindow?(id)
    }

    /// Rename the frontmost window via a one-shot standard `NSAlert` with an accessory text field
    /// pre-filled with the current name. The app has no generic inline-prompt affordance (inline rename
    /// is sidebar-row-only, and a window has no sidebar row), so the alert is the standard, minimal fit.
    /// The rename itself flows through `library.renameWindow`, the same seam the control channel uses.
    func renameActiveWindow() {
        guard let id = library.activeWindowID,
              let window = library.windows.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Window"
        alert.informativeText = "Enter a new name for this window."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = window.name
        field.selectText(nil)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.renameWindow(id, to: field.stringValue)
    }

    /// Delete the frontmost window and its sessions. Confirms first when the window still has sessions
    /// (the delete ends their shells); an empty window deletes without a prompt. No-ops when only one
    /// window remains — one is always kept. Closes its on-screen window first so the teardown runs.
    func deleteActiveWindow() {
        guard library.canRemoveWindow, let id = library.activeWindowID,
              let window = library.windows.first(where: { $0.id == id }) else { return }
        let sessionCount = library.store(for: id)?.workspaces.reduce(0) { $0 + $1.sessions.count } ?? 0
        if sessionCount > 0, !confirmDelete(name: window.name, sessionCount: sessionCount) { return }
        WindowRegistry.shared.close(id)
        library.removeWindow(id)
    }

    // MARK: - Inline rename

    /// Start an inline rename of the active session. The sidebar owns the edit field, so this posts
    /// a notification it observes; `renamePending` keeps the palette-close focus restore off the
    /// field while the edit starts.
    func renameActiveSession() {
        guard store?.activeSession != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtermBeginRenameSession, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    /// Start an inline rename of the active session's workspace (the same one new sessions land in).
    func renameActiveWorkspace() {
        guard store?.currentWorkspaceID != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtermBeginRenameWorkspace, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    // MARK: - Split

    /// Toggle the active session's split. Opening shows both panes and moves focus to the new (right)
    /// pane; closing HIDES the split (both shells stay alive, nothing is destroyed) and shows the
    /// focused pane maximized, so reopening restores the two panes in their original positions. Either
    /// way focus follows `splitFocused`, which `AppStore.toggleSplit` sets to the new pane on open.
    func toggleSplit() {
        guard let store, let session = store.activeSession else { return }
        store.toggleSplit(session.id)
        focusSplitPane(session, wantSplit: session.splitFocused)
    }

    /// Show/hide the active session's scratch terminal — a third, full-overlay login shell. Focus is
    /// handled by the surface's `autoFocus` on show and the detail pane's scratch-hide focus reclaim,
    /// so this just flips the flag. The control channel drives `AppStore.toggleScratch` directly.
    func toggleScratch() {
        guard let store, let session = store.activeSession else { return }
        store.toggleScratch(session.id)
    }

    /// Show/hide the frontmost window's sidebar. The custom split owns visibility (no system toggle), so
    /// this flips the active store's per-window `sidebarVisible`; the view animates the change and
    /// `AppStore` persists it. Shared by the toolbar button, the View menu item, the palette, and the
    /// `sidebar` control command.
    func toggleSidebar() {
        guard let store else { return }
        store.toggleSidebarVisible()
    }

    /// Move keyboard focus to a pane of the active session's split: `.split` -> the right pane,
    /// anything else -> the left/primary. No-op when the active session has no split. Works whether the
    /// split is shown side-by-side or hidden (maximized). Drives the keyboard shortcuts, the View menu
    /// items, and the action palette.
    func focusPane(_ pane: PaneRole) {
        guard let session = store?.activeSession else { return }
        setSplitFocus(pane == .split, of: session)
    }

    /// Set which pane of a session's split holds focus and move first responder there. Shared by the
    /// GUI `focusPane` and the control channel (which may target a session that isn't the active one).
    /// Updates `splitFocused` so the pane dim, sidebar, and title bar follow. Works whether the split is
    /// shown side-by-side or hidden: when hidden, flipping `splitFocused` swaps which pane is shown
    /// maximized. No-op only when the session has no split.
    func setSplitFocus(_ toSplit: Bool, of session: Session) {
        guard session.hasSplit else { return }
        session.splitFocused = toSplit
        focusSplitPane(session, wantSplit: toSplit)
    }

    // MARK: - Quick terminal (frontmost window)

    /// Toggle the frontmost window's quick terminal (each window owns its own controller).
    func toggleQuickTerminal() { frontmostQuickTerminal?.toggle() }

    // MARK: - Font (on the focused terminal)

    func increaseFontSize() { focusedSurface()?.performBindingAction("increase_font_size:1") }
    func decreaseFontSize() { focusedSurface()?.performBindingAction("decrease_font_size:1") }
    func resetFontSize() { focusedSurface()?.performBindingAction("reset_font_size") }

    // MARK: - Search (on the surface that opened it)

    /// The search-capable target. A covering SCRATCH wins FIRST — the scratch surface (`topmostSurface` while
    /// `scratchActive` with no overlay) — so a ⌘F while the scratch covers the session always opens the bar on
    /// the scratch, never on the hidden pane underneath, even when key-window focus sits off the surface (e.g.
    /// the sidebar), where `focusedSurface()` would otherwise fall back to the hidden `activeSurface`. Else the
    /// focused surface IFF it is searchable (the main/split pane), else the active session's focused pane. The
    /// full overlay/quick terminal are not searchable (blocked by `coverHidesActiveSession`); a FLOATING
    /// overlay leaves the pane visible, so search targets the pane behind it (not the unsearchable overlay).
    private func searchTarget() -> GhosttySurfaceView? {
        if let session = store?.activeSession, session.scratchActive, !session.overlayActive {
            return session.topmostSurface as? GhosttySurfaceView
        }
        if let view = focusedSurface(), view.isSearchable { return view }
        return store?.activeSession?.activeSurface as? GhosttySurfaceView
    }

    /// Whether a covering surface hides the active session in a way that BLOCKS ⌘F — the frontmost window's
    /// quick terminal is up, or the active session shows a FULL overlay. Neither is searchable, so opening the
    /// bar would strand it over a hidden pane. The scratch is NOT a blocker: it IS searchable now, so ⌘F opens
    /// the bar over the scratch itself. The ⌘F-again CLOSE still runs regardless (no cover blocks it).
    private var coverHidesActiveSession: Bool {
        if frontmostQuickTerminal?.isVisible == true { return true }
        guard let session = store?.activeSession else { return false }
        // a FLOATING overlay leaves the session visible, so only a FULL overlay hides it (and is not searchable).
        return session.fullOverlayActive
    }

    /// Toggle the search bar for the active session. CLOSE branch (search already active): send
    /// `end_search` DIRECTLY to the session's pinned `searchSurface` (the surface that opened search), so
    /// the END callback clears the fields and refocuses — it does NOT re-resolve a target or round-trip
    /// `start_search`, which on a split with focus moved to the OTHER pane would put that pane into search
    /// mode while `onSearchStart` closes only the pinned owner, stranding it. OPEN branch (search inactive):
    /// no-op when no searchable surface exists (never enters bar-less search on a quick/scratch/overlay
    /// surface) or while a covering surface hides the session, else send `start_search` to the search
    /// target — `onSearchStart` opens the bar and pins the surface. Shared by the Find menu item, the
    /// palette, and ⌘F.
    func toggleSearch() {
        if store?.activeSession?.searchActive == true {
            (store?.activeSession?.searchSurface as? GhosttySurfaceView)?.endSearch()
            return
        }
        guard let target = searchTarget(), !coverHidesActiveSession else { return }
        target.startSearch()
    }

    /// Set the current query: mirror it into the active session's `searchNeedle` (so the bar's field stays
    /// in sync) then send `search:<needle>` to the session's pinned `searchSurface`, which replies with the
    /// new match count. Driving the pinned owner (not a re-resolved focused surface) keeps the bar bound to
    /// the pane that opened search even after split focus moves. Clearing the field (empty needle) clears
    /// the count/selected eagerly so the counter blanks at once rather than flashing the stale "N of M"
    /// until libghostty's async teardown callback lands.
    func updateSearchNeedle(_ needle: String) {
        guard let session = store?.activeSession else { return }
        session.searchNeedle = needle
        if needle.isEmpty {
            session.searchTotal = nil
            session.searchSelected = nil
        }
        (session.searchSurface as? GhosttySurfaceView)?.sendSearchQuery(needle)
    }

    /// Step to the next/previous match (the up/down buttons, Enter/Shift-Enter in the bar), on the active
    /// session's pinned `searchSurface`.
    func navigateSearch(_ direction: GhosttySurfaceView.SearchDirection) {
        (store?.activeSession?.searchSurface as? GhosttySurfaceView)?.navigateSearch(direction)
    }

    /// Close search: send `end_search` to the session's pinned `searchSurface` so it exits search mode
    /// (never just flips the flag). The resulting END_SEARCH callback clears the session's fields, the
    /// pinned owner, and returns first responder to the terminal — the single clear point, so this only
    /// sends the binding action.
    func endSearch() {
        (store?.activeSession?.searchSurface as? GhosttySurfaceView)?.endSearch()
    }

    // MARK: - Focus

    /// Move first responder back to the active session's topmost surface (used after the quick terminal
    /// or a palette/rename field closes). Targets `topmostSurface` (overlay > scratch > active pane) so a
    /// palette close re-focuses whatever is actually visible — the scratch or overlay if one is up, else
    /// the focused pane — never a pane hidden under a cover. Re-asserts briefly since the target view may
    /// not be on-window yet. Bails only for the quick terminal: it is a window-level cover that owns focus
    /// and re-focuses the session on its own hide, so don't fight it here.
    func focusActiveSession(attempt: Int = 0) {
        if renamePending { return }
        // never grab terminal focus while a command palette is open — the palette owns the keyboard.
        // this also kills the retry loop the instant a palette (re)opens, so the action-palette "Select
        // Theme…" launcher (which closes the action palette, then opens the .themes picker a tick later)
        // can't have its field focus stolen back by the close-restore's retry.
        if palette?.mode != nil { return }
        if frontmostQuickTerminal?.isVisible == true { return }
        if let view = store?.activeSession?.topmostSurface as? GhosttySurfaceView, let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusActiveSession(attempt: attempt + 1)
        }
    }

    /// Move first responder to the split (right) pane on open, or the primary on close.
    /// Re-asserts over a short window because the split surface materializes a beat after the
    /// toggle and the HSplitView collapse churns the primary view. While a full-coverage surface
    /// (scratch or overlay) is up, the requested pane is hidden beneath it, so keep first responder on
    /// the visible `topmostSurface` instead — the caller has already set `splitFocused`, so the correct
    /// pane shows once the cover is dismissed.
    func focusSplitPane(_ session: Session, wantSplit: Bool, attempt: Int = 0) {
        // the quick terminal is a window-level cover above the session; while it's up it owns focus, so
        // don't move first responder to a pane behind it (its own hide restores the session). The caller
        // has already set `splitFocused`, so the right pane shows once the quick terminal is dismissed.
        if frontmostQuickTerminal?.isVisible == true { return }
        let target: (any TerminalSurface)? = (session.overlayActive || session.scratchActive)
            ? session.topmostSurface
            : (wantSplit ? session.splitSurface : session.surface)
        if let view = target as? GhosttySurfaceView, let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusSplitPane(session, wantSplit: wantSplit, attempt: attempt + 1)
        }
    }

    /// Bring a session/pane to the foreground from a notification click: surface the owning window
    /// (reopening it when the banner was clicked after the window closed), select the session (which
    /// clears its unseen badge and derives its workspace), and focus the firing pane. Stale-safe: an
    /// unknown session in an open window resolves directly; an unknown window/session just leaves the
    /// app active (the caller has already activated it). A `.split` pane that is no longer split
    /// falls back to the primary.
    func reveal(windowID: UUID, sessionID: UUID, pane: PaneRole) {
        // window already open: select + focus right away.
        if let store = library.store(forSession: sessionID) {
            revealSession(sessionID, pane: pane, in: store)
            return
        }
        // window closed: reopen it, then select once its store has loaded (the surface materializes
        // a beat after the window appears, so retry like focusSplitPane does).
        guard library.windows.contains(where: { $0.id == windowID }) else { return }
        openWindow?(windowID)
        revealAfterOpen(windowID: windowID, sessionID: sessionID, pane: pane)
    }

    /// Polls for a reopened window's store to load, then reveals the session. Bounded so a stale id
    /// (the window never materializes) gives up instead of looping forever.
    private func revealAfterOpen(windowID: UUID, sessionID: UUID, pane: PaneRole, attempt: Int = 0) {
        if let store = library.store(for: windowID), store.session(withID: sessionID) != nil {
            revealSession(sessionID, pane: pane, in: store)
            return
        }
        guard attempt < 30 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.revealAfterOpen(windowID: windowID, sessionID: sessionID, pane: pane, attempt: attempt + 1)
        }
    }

    /// Selects a session in its owning store and focuses the firing pane.
    private func revealSession(_ sessionID: UUID, pane: PaneRole, in store: AppStore) {
        guard let session = store.session(withID: sessionID) else { return }
        store.selectSession(session.id)
        let wantSplit = pane == .split && session.hasSplit
        session.splitFocused = wantSplit
        focusSplitPane(session, wantSplit: wantSplit)
    }

    /// The focused terminal: the key window's first responder if it's a surface (covers the main
    /// pane, the split pane, and the quick terminal), else the active session's focused pane.
    private func focusedSurface() -> GhosttySurfaceView? {
        if let view = NSApp.keyWindow?.firstResponder as? GhosttySurfaceView { return view }
        return store?.activeSession?.activeSurface as? GhosttySurfaceView
    }
}
