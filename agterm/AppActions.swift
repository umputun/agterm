import agtermCore
import AppKit
import SwiftUI

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
    var frontmostQuickTerminal: QuickTerminalController? {
        QuickTerminalRegistry.shared.controller(for: library.activeWindowID)
    }

    /// The frontmost window's terminal-zoom controller. The host-free controller tracks the per-window
    /// zoom target; `WindowContentView` renders that target above this window's chrome.
    private var frontmostTerminalZoom: TerminalZoomController? {
        TerminalZoomRegistry.shared.controller(for: library.activeWindowID)
    }

    /// The frontmost window's dashboard controller (each window owns its own), resolved through the same
    /// `activeWindowID` accessor as `frontmostQuickTerminal`/`frontmostTerminalZoom`. Nil when no window is open.
    var frontmostDashboard: DashboardController? {
        DashboardControllerRegistry.shared.controller(for: library.activeWindowID)
    }

    var terminalZoomActive: Bool {
        frontmostTerminalZoom?.target != nil
    }

    /// While terminal zoom OR the dashboard grid is active, the UI is modal: keyboard/menu/palette actions
    /// must not mutate the deck behind it. The zoom/dashboard toggles, socket commands, and macOS window
    /// controls remain separate paths (they never gate on this), so the user is never trapped and can always
    /// dismiss the modal. `frontmostDashboard?.isOpen` mirrors `terminalZoomActive`, resolved on the frontmost
    /// window like the zoom target.
    var uiActionsEnabled: Bool { !terminalZoomActive && !(frontmostDashboard?.isOpen ?? false) }

    /// Set briefly while a rename is being started, so the focus-restore that runs when a palette
    /// or the quick terminal closes doesn't steal first responder from the inline rename field.
    var renamePending = false

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

    /// Both theme slots captured when the theme picker opened, restored on Esc/cancel. Snapshotting the
    /// WHOLE pair (not just the on-screen slot) is what makes the revert flip-safe: if macOS switches
    /// appearance mid-preview, restoring both slots reverts correctly regardless of which slot the
    /// preview wrote. `themePreviewActive` gates the preview/commit/cancel so the hooks are inert outside
    /// the picker (the palette's other modes never touch them).
    var themePreviewActive = false
    var themePreviewOriginal: (theme: String?, dark: String?)?

    /// The `.agtermAutoFollowed` observer token. Installed once in `init` (the app builds one `AppActions`)
    /// so an idle auto-follow in the key window moves first responder into the newly selected session.
    private var autoFollowObserver: NSObjectProtocol?

    init(library: WindowLibrary) {
        self.library = library
        // bridge the host-free `AppStore.autoFollowFire` post to the app-target focus move: agtermCore can't
        // call `focusActiveSession`, so it posts and we resolve + focus here. runs on the main queue.
        autoFollowObserver = NotificationCenter.default.addObserver(
            forName: .agtermAutoFollowed, object: nil, queue: .main
        ) { [weak self] note in
            let sessionID = note.userInfo?[AppStore.autoFollowSessionIDKey] as? UUID
            MainActor.assumeIsolated { self?.autoFollowed(sessionID) }
        }
    }

    // isolated so it can read the `@MainActor` non-Sendable observer token; balances the block-based
    // observer registered in init. AppActions is app-lifetime (one per app), so this rarely runs, but an
    // unbalanced addObserver(forName:) is a latent leak either way.
    isolated deinit {
        if let autoFollowObserver { NotificationCenter.default.removeObserver(autoFollowObserver) }
    }

    // MARK: - Workspaces & sessions

    func newWorkspace() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        store.addWorkspace(name: store.defaultWorkspaceName)
    }

    func newSession() {
        guard uiActionsEnabled else { return }
        guard let store, let workspaceID = store.currentWorkspaceID,
              let session = store.addSession(toWorkspace: workspaceID, cwd: resolvedNewSessionCwd())
        else { return }
        // creating + selecting a session is a user-initiated selection: note activity so it buys the full
        // idle grace before auto-follow can pull the selection away from the just-made session.
        store.noteUserActivity()
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
        guard uiActionsEnabled else { return }
        guard let store, let workspaceID = store.currentWorkspaceID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = DirectoryPanelDefaults.url(paths: store.activeSession?.focusedCwd)
        panel.prompt = "Open"
        panel.message = "Choose a directory for the new session"
        guard panel.runModal() == .OK, let url = panel.url,
              let session = store.addSession(toWorkspace: workspaceID, cwd: url.path)
        else { return }
        // creating + selecting a session is a user-initiated selection: note activity so it buys the full
        // idle grace before auto-follow can pull the selection away from the just-made session.
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
    }

    /// Opens a new session at `directory` in the last-active window — the target of `open -a agterm /path`
    /// (the OS "open terminal here" integration). Mirrors `newSession()`
    /// (note-activity + select + focus) but seeds the cwd from the passed directory instead of the
    /// new-session-directory setting. Resolves `library.activeStore` (the frontmost/last-active window,
    /// the same target the control channel's `session.new` defaults to), so it is NOT gated on
    /// `uiActionsEnabled` — an external OS command, like a socket command, must land regardless of a
    /// modal zoom/dashboard. Returns whether a session was created, so the delegate's drain can retry
    /// until the frontmost store resolves.
    func openSession(atDirectory directory: String) -> Bool {
        guard let store, let workspaceID = store.currentWorkspaceID,
              let session = store.addSession(toWorkspace: workspaceID, cwd: directory)
        else { return false }
        // creating + selecting a session is a user-initiated selection: note activity so it buys the full
        // idle grace before auto-follow can pull the selection away from the just-made session.
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
        return true
    }

    /// Duplicates a session — a fresh shell in the source's directory, placed right after it. Scoped to the
    /// caller's store (like the other sidebar row actions) so a background window's context menu acts on its
    /// own row, not the frontmost store's session. `AppStore.duplicateSession` carries the directory-only
    /// contract; this adds the same select + focus the sidebar's New Session does. Returns nothing (matching
    /// `newSession`/`openDirectory`) — the control path calls `store.duplicateSession` directly for the id.
    func duplicateSession(_ id: UUID, in store: AppStore) {
        guard let session = store.duplicateSession(id) else { return }
        // creating + selecting a session is a user-initiated selection: note activity so it buys the full
        // idle grace before auto-follow can pull the selection away from the just-made session.
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
    }

    /// Duplicate the ACTIVE session — the active-session entry point for the menu bar, the ⌃P command
    /// palette, and a `duplicate_session` keymap binding, mirroring `renameActiveSession()` vs the sidebar's
    /// row-scoped `duplicateSession(_:in:)`. Acts on the frontmost window's store and its selected session.
    func duplicateActiveSession() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID else { return }
        duplicateSession(id, in: store)
    }

    /// Reveal the active session's focused-pane cwd in Finder. Finder gets the directory itself selected
    /// (rather than opening arbitrary terminal output), matching "Reveal in Finder" behavior elsewhere on Mac.
    func revealActiveSessionInFinder() {
        guard let store, let id = store.selectedSessionID else { return }
        revealSessionInFinder(id, in: store)
    }

    var canRevealActiveSessionInFinder: Bool {
        guard let store, let id = store.selectedSessionID else { return false }
        return canRevealSessionInFinder(id, in: store)
    }

    func canRevealSessionInFinder(_ id: UUID, in store: AppStore) -> Bool {
        guard let session = store.session(withID: id) else { return false }
        return DirectoryPanelDefaults.existingDirectoryURL(for: session.focusedCwd) != nil
    }

    /// Reveal a specific session's focused-pane cwd in Finder, scoped to the caller's store so a sidebar
    /// context menu in a background window still acts on the clicked row in that window.
    @discardableResult
    func revealSessionInFinder(_ id: UUID, in store: AppStore) -> Bool {
        guard let session = store.session(withID: id),
              let url = DirectoryPanelDefaults.existingDirectoryURL(for: session.focusedCwd)
        else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
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
        // terminal zoom is the window-topmost cover of all: ⌘W dismisses it like the covers below
        // (stepwise — a zoomed quick terminal un-zooms first, the next ⌘W hides it) rather than
        // swallowing the keystroke, and still never mutates hidden session/window state behind it. the
        // dashboard grid is the other modal cover (mutually exclusive with zoom): ⌘W dismisses it the same
        // way — close the grid and refocus the session — rather than closing the session behind it.
        if terminalZoomActive { frontmostTerminalZoom?.clear(); return true }
        if let dashboard = frontmostDashboard, dashboard.isOpen { dashboard.close(); focusActiveSession(); return true }
        if let quick = frontmostQuickTerminal, quick.isVisible { quick.hide(); return true }
        guard let store, let session = store.activeSession else { return false }
        if session.overlayActive { store.closeOverlay(session.id); return true }
        if session.scratchActive { store.toggleScratch(session.id); return true }
        // ⌘W was handled either way — on cancel we return true so the File menu doesn't fall back to
        // closing the whole window.
        guard confirmCloseSession(session) else { return true }
        closeSessionAfterConfirmation(session.id, in: store)
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
        guard uiActionsEnabled else { return }
        guard let session = store.session(withID: id) else { return }
        guard confirmCloseSession(session) else { return }
        closeSessionAfterConfirmation(id, in: store)
    }

    /// Undo the latest grace-period session/workspace close in the frontmost window.
    func undoClose() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        let restored = withAnimation(.easeInOut(duration: 0.16)) {
            store.undoPendingClose()
        }
        guard restored else { return }
        focusActiveSession()
    }

    func openRecentClosed(_ id: RecentClosedItem.ID) {
        guard uiActionsEnabled else { return }
        guard library.reopenRecentClosed(id) else { return }
        focusActiveSession()
    }

    func openLatestRecentClosed() {
        guard uiActionsEnabled else { return }
        guard library.reopenLatestRecentClosed() else { return }
        focusActiveSession()
    }

    func clearRecentClosedItems() {
        library.clearRecentClosedItems()
    }

    /// A native warning confirm before closing `session`, gated by `AppSettings.confirmCloseSession`.
    /// Returns whether to proceed with the close: true immediately (no prompt) when the setting is off, or
    /// under an XCUITest launch (a modal would hang the test, like the clear-flagged/quit confirms).
    private func confirmCloseSession(_ session: Session) -> Bool {
        guard settingsModel?.settings.confirmCloseSession == true,
              !ContentView.shouldBypassCloseConfirmation else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(session.displayName)”?"
        alert.informativeText = closeGraceUndoEnabled
            ? "The session will close after a short undo window."
            : "The session will close immediately and can be reopened from File > Open Recent."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var closeGraceUndoEnabled: Bool {
        settingsModel?.settings.closeGraceUndoEnabled ?? true
    }

    private func closeSessionAfterConfirmation(_ id: UUID, in store: AppStore) {
        if closeGraceUndoEnabled {
            withAnimation(.easeInOut(duration: 0.16)) {
                _ = store.softCloseSession(id)
            }
        } else {
            store.closeSession(id)
        }
    }

    /// Clear the active session's agent-status indicator back to idle (the same effect as `agtermctl
    /// session status idle` and the sidebar row's "Clear Status"). No-op when nothing is selected.
    func clearActiveSessionStatus() {
        guard uiActionsEnabled else { return }
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
        guard uiActionsEnabled else { return }
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
        guard uiActionsEnabled else { return }
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
    /// then moves first responder into the moved-to session's focused pane. Each also notes the manual
    /// navigation as user activity so it buys the full idle grace before auto-follow can pull the
    /// selection back (the control `session.go` drives `navigateSession` directly, so it stays silent).
    func selectNextSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        store?.navigateSession(.next)
        revealActiveBlockedPane()
    }
    func selectPreviousSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        store?.navigateSession(.previous)
        revealActiveBlockedPane()
    }
    func selectFirstSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        store?.navigateSession(.first)
        revealActiveBlockedPane()
    }
    func selectLastSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        store?.navigateSession(.last)
        revealActiveBlockedPane()
    }

    /// Step to the next/previous session needing attention (status `blocked` or `completed`), wrapping
    /// around and skipping idle/active sessions. Shares `navigateSession` with the GUI, palette, and the
    /// `session.go next-attention|prev-attention` control command. Notes user activity like the plain
    /// session nav (a manual step to an attention session buys the idle grace too), then reveals and focuses
    /// the moved-to session's blocked pane (`revealActiveBlockedPane`) so nav lands on the split/scratch pane
    /// that set the status, not just the session's plain focused pane.
    func selectNextAttentionSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        store?.navigateSession(.nextAttention)
        revealActiveBlockedPane()
    }
    func selectPreviousAttentionSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        store?.navigateSession(.previousAttention)
        revealActiveBlockedPane()
    }

    /// Delete a workspace and all of its sessions. Confirms first when the workspace still has
    /// sessions (the delete ends their shells); an empty workspace deletes without a prompt.
    /// No-ops when only one workspace remains — one is always kept.
    func deleteWorkspace(_ workspaceID: UUID) {
        guard uiActionsEnabled else { return }
        guard let store, store.canRemoveWorkspace,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        if !workspace.sessions.isEmpty, !confirmDeleteWorkspace(workspace) { return }
        if closeGraceUndoEnabled {
            withAnimation(.easeInOut(duration: 0.16)) {
                _ = store.softRemoveWorkspace(workspaceID)
            }
        } else {
            store.removeWorkspace(workspaceID)
        }
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
        let suffix = closeGraceUndoEnabled
            ? "after a short undo window."
            : "immediately. You can reopen it from File > Open Recent."
        alert.informativeText = sessionCount == 1
            ? "This closes its session \(suffix)"
            : "This closes \(sessionCount) sessions \(suffix)"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Move a session to another workspace (used by the palette's "Move Session to …" items).
    func moveSession(_ sessionID: UUID, toWorkspace workspaceID: UUID) {
        guard uiActionsEnabled else { return }
        store?.moveSession(sessionID, toWorkspace: workspaceID)
    }

    /// Focus (or unfocus) a workspace — collapses the sidebar tree to that workspace's subtree, or clears
    /// focus when it is already the focused one. Driven by the sidebar workspace row's "Focus"/"Unfocus"
    /// context-menu item. Clean no-op on an unknown id.
    func focusWorkspace(_ id: UUID) {
        guard uiActionsEnabled else { return }
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
        guard uiActionsEnabled else { return }
        guard let store, store.focusedWorkspaceID != nil else { return }
        store.setFocusedWorkspace(nil)
    }

    // MARK: - Sidebar tree expansion

    /// Expand every workspace in the frontmost window's sidebar (the GUI menu/palette target). No-op when
    /// no window is open.
    func expandAllWorkspaces() {
        guard uiActionsEnabled else { return }
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
        guard uiActionsEnabled else { return }
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
        guard uiActionsEnabled else { return }
        guard let store, let session = store.session(withID: sessionID) else { return }
        store.setFlag(!session.flagged, forSession: sessionID)
    }

    /// Toggle one or more session flags in a specific window-local store. This mirrors `closeSessions`:
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
        guard uiActionsEnabled else { return }
        guard let store else { return }
        store.setSidebarMode(store.sidebarMode == .flagged ? .tree : .flagged)
    }

    /// Unflag every session across all workspaces. Confirms first when at least one session is flagged
    /// (clearing the working-set is a bulk change worth confirming); does nothing when nothing is
    /// flagged. Skips the confirm under an XCUITest launch (a modal would hang the test).
    func clearFlags() {
        guard uiActionsEnabled else { return }
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
        guard uiActionsEnabled else { return }
        let info = library.newWindow()
        openWindow?(info.id)
    }

    /// Surface a window: raise it if already open, else open it (the opener claims its id + spawns a
    /// new on-screen window). Used by the File ▸ Open Window submenu and the palette.
    func openWindow(_ id: WindowInfo.ID) {
        guard uiActionsEnabled else { return }
        openWindow?(id)
    }

    /// Rename the frontmost window via a one-shot standard `NSAlert` with an accessory text field
    /// pre-filled with the current name. The app has no generic inline-prompt affordance (inline rename
    /// is sidebar-row-only, and a window has no sidebar row), so the alert is the standard, minimal fit.
    /// The rename itself flows through `library.renameWindow`, the same seam the control channel uses.
    func renameActiveWindow() {
        guard uiActionsEnabled else { return }
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
        guard uiActionsEnabled else { return }
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
        guard uiActionsEnabled else { return }
        guard store?.activeSession != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtermBeginRenameSession, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    /// Start an inline rename of the active session's workspace (the same one new sessions land in).
    func renameActiveWorkspace() {
        guard uiActionsEnabled else { return }
        guard store?.currentWorkspaceID != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtermBeginRenameWorkspace, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    // MARK: - Split

    /// Toggle the active session's split. Opening a NEW split shows both panes and moves focus to the
    /// new (right) pane; closing HIDES the split (both shells stay alive, nothing is destroyed) and shows
    /// the focused pane maximized, so reopening restores the two panes in their original positions with
    /// the SAME pane focused. Either way focus follows `splitFocused`, which `AppStore.toggleSplit` sets
    /// to the new pane only when the split is genuinely new (a re-show preserves the prior focused pane).
    func toggleSplit() {
        guard uiActionsEnabled else { return }
        guard let store, let session = store.activeSession else { return }
        store.toggleSplit(session.id)
        focusSplitPane(session, wantSplit: session.splitFocused)
    }

    /// Show/hide the active session's scratch terminal — a third, full-overlay login shell. Focus is
    /// handled by the surface's `autoFocus` on show and the detail pane's scratch-hide focus reclaim,
    /// so this just flips the flag. The control channel drives `AppStore.toggleScratch` directly.
    func toggleScratch() {
        guard uiActionsEnabled else { return }
        guard let store, let session = store.activeSession else { return }
        store.toggleScratch(session.id)
    }

    /// Show/hide the frontmost window's sidebar. The custom split owns visibility (no system toggle), so
    /// this flips the active store's per-window `sidebarVisible` (an instant toggle — the width is
    /// intentionally not animated, see WindowContentView.splitRoot) and `AppStore` persists it. Shared by
    /// the toolbar button, the View menu item, the palette, and the `sidebar` control command.
    func toggleSidebar() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        store.toggleSidebarVisible()
    }

    /// Move keyboard focus to a pane of the active session's split: `.split` -> the right pane,
    /// anything else -> the left/primary. No-op when the active session has no split. Works whether the
    /// split is shown side-by-side or hidden (maximized). Drives the keyboard shortcuts, the View menu
    /// items, and the action palette.
    func focusPane(_ pane: PaneRole) {
        guard uiActionsEnabled else { return }
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
    func toggleQuickTerminal() {
        guard !terminalZoomActive else { return }
        frontmostQuickTerminal?.toggle()
    }

    /// Toggle the frontmost window's full-window terminal zoom. Core resolves which surface is active
    /// (quick, overlay, scratch, split, or primary); the owning window renders it above all chrome.
    func toggleTerminalZoom() { frontmostTerminalZoom?.toggle() }

    /// Toggle the frontmost window's dashboard — the keyboard/menu/palette opener for the MRU dashboard grid
    /// (the ⌘⇧D / Navigate ▸ Dashboard equivalent of `agtermctl dashboard --mru --auto-size`). Inert while
    /// terminal zoom is active (mirrors the GUI siblings + the `.disabled(zoomed)` menu item; the control
    /// path keeps its own zoom-clear). Open → close it and refocus the active session; closed → open it over
    /// the window's most-recently-used sessions, auto-sized. A no-op when the window has no recent sessions.
    func toggleDashboard() {
        guard !terminalZoomActive else { return }
        guard let dashboard = frontmostDashboard else { return }
        if dashboard.isOpen {
            dashboard.close()
            focusActiveSession()
            return
        }
        guard let store else { return }
        let members = store.dashboardMRUMembers(limit: DashboardLayout.maxCells)
        guard !members.isEmpty else { return }
        dashboard.open(members: members, fontMode: .auto)
        // set the applied font size synchronously (the SwiftUI onChange applies the surface overrides a runloop
        // turn later), resolving through the same DashboardFontMode seam as ControlServer.setDashboard so the
        // GUI and control opens land on the identical auto size.
        let base = settingsModel?.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
        dashboard.setAppliedFontSize(DashboardFontMode.auto.appliedFontSize(memberCount: members.count, base: base))
    }

    /// Toggle native macOS full screen for the key window (the frontmost terminal window). Native full
    /// screen matches the green traffic-light button and moves the window to its own Space; a second
    /// invocation exits. Shared by the View ▸ Toggle Full Screen menu item (⌃⌘F), the ⌃⇧P palette, the
    /// `toggle_fullscreen` keymap action, and the `window.fullscreen` control command.
    func toggleFullscreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    // MARK: - Font (on the focused terminal)

    // deliberately NOT zoom-gated: font commands act on the FOCUSED surface — while zoomed that is the
    // zoomed terminal the user is reading — and never touch hidden deck state, so ⌘+/⌘−/⌘0 keep working.
    func increaseFontSize() {
        focusedSurface()?.performBindingAction("increase_font_size:1")
    }
    func decreaseFontSize() {
        focusedSurface()?.performBindingAction("decrease_font_size:1")
    }
    func resetFontSize() {
        focusedSurface()?.performBindingAction("reset_font_size")
    }

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
        guard !terminalZoomActive else { return }
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

    /// Bridge for `.agtermAutoFollowed`: an idle auto-follow has moved some window's selection to a blocked
    /// session. Selection alone does NOT move first responder (the eager deck keeps the prior surface as
    /// responder), so pull focus into the newly selected session — but ONLY when the firing window is key.
    /// A non-key window keeps just the selection change and focuses normally when it next becomes key.
    /// `revealActiveBlockedPane` targets the frontmost (= key) store — the firing window here since we gate
    /// on its being key — and reveals the pane that set the status (split/scratch), so the initial jump lands
    /// on the waiting pane, not just the session's plain focused pane.
    private func autoFollowed(_ sessionID: UUID?) {
        guard let sessionID, let windowID = library.windowID(forSession: sessionID),
              WindowRegistry.shared.isKeyWindow(windowID) else { return }
        // never reveal behind the zoom layer: the reveal mutates scratch visibility / splitFocused,
        // exactly the hidden-state writes zoom forbids. The auto-follow SELECTION stands (the user
        // lands on the blocked session when they exit zoom); only the pane reveal is skipped.
        guard TerminalZoomRegistry.shared.controller(for: windowID)?.target == nil else { return }
        revealActiveBlockedPane()
    }

    /// Per-window generation counters (keyed by the owning window id; bumped in AppActions+Focus). A fresh
    /// `focusSplitPane` call bumps its window's counter so an older in-flight retry loop in the SAME window
    /// cancels itself when superseded, stopping the opposite-target ping-pong flicker and giving
    /// last-focus-wins within a window. Keyed by window (one NSWindow = one first responder) so a focus op
    /// in one window never cancels another window's still-materializing focus retry.
    var focusGeneration: [UUID: Int] = [:]

    /// The focused terminal: the key window's first responder if it's a surface (covers the main
    /// pane, the split pane, and the quick terminal), else the active session's focused pane.
    private func focusedSurface() -> GhosttySurfaceView? {
        if let view = NSApp.keyWindow?.firstResponder as? GhosttySurfaceView { return view }
        return store?.activeSession?.activeSurface as? GhosttySurfaceView
    }
}
