import agtermCore
import AppKit
import SwiftUI

/// User actions shared by the toolbar / bottom-bar buttons (`ContentView`) and the menu bar
/// (`agtermApp`'s `.commands`) so the two never drift; `@MainActor`, holds the store and resolves the
/// focused terminal for font commands. Trivial one-liners (quick-terminal / status-bar toggle) call the
/// controller/store directly instead; this owns the actions with real logic — new-session placement, the
/// directory picker, split/focus/font.
@MainActor
final class AppActions {
    /// The window library. The seam resolves the frontmost window's store per call rather than holding a
    /// fixed one, so menu bar / palette / control channel all drive the window the user is looking at.
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

    /// The frontmost window's dashboard controller (each window owns its own), resolved on `activeWindowID`
    /// like the quick-terminal/zoom ones. Nil when no window is open.
    var frontmostDashboard: DashboardController? {
        DashboardControllerRegistry.shared.controller(for: library.activeWindowID)
    }

    var terminalZoomActive: Bool {
        frontmostTerminalZoom?.target != nil
    }

    /// Frontmost-window shorthand for the modal gate: while terminal zoom, the dashboard grid, or a pending
    /// native picker is up, keyboard/menu/palette actions must not mutate the deck behind it. Dismissal stays
    /// callable so the user is never trapped — the dashboard toggle survives its own grid, while zoom/dashboard
    /// toggles are blocked behind a picker. With no window open `library.activeWindowID` is nil and the gate
    /// DENIES, so no deck action runs against no window while the app tears down.
    var uiActionsEnabled: Bool { uiActionsEnabled(for: library.activeWindowID) }

    /// The modal gate for a specific window. Session-addressed entry points use this instead of the
    /// frontmost-only property when their target may have changed while an external menu was tracking.
    func uiActionsEnabled(for windowID: WindowInfo.ID?) -> Bool {
        guard let windowID else { return false }
        return TerminalZoomRegistry.shared.controller(for: windowID)?.target == nil
            && DashboardControllerRegistry.shared.controller(for: windowID)?.isOpen != true
            && PickRegistry.shared.controller(for: windowID)?.pending == nil
    }

    /// Set briefly while a rename is being started, so the focus-restore that runs when a palette
    /// or the quick terminal closes doesn't steal first responder from the inline rename field.
    var renamePending = false

    /// Opens (or raises) a window by id. SwiftUI's `openWindow` is an `@Environment` value reachable only
    /// inside the scene, so `agtermApp` wires this at launch (`enqueueClaim` + `openWindow(id:)`, raising an
    /// already-open one via `WindowRegistry`). Used by the cross-window notification reveal for a
    /// banner-clicked session whose window had closed. Nil before the scene `.task` runs.
    var openWindow: ((WindowInfo.ID) -> Void)?

    /// The settings model, holding the parsed keymap whose custom commands feed the action palette. It and
    /// `customCommandRunner` are built AFTER `actions` in `agtermApp.init`, so both are settable and wired in
    /// the scene `.task` (the `NotificationManager.shared.actions` precedent) rather than passed to
    /// `init(library:)`, which would be an init-order break. Nil until that `.task` runs.
    var settingsModel: SettingsModel?

    /// The custom-command runner that the palette's custom items invoke (`run(_:)`). Wired in the
    /// scene `.task` alongside `settingsModel` for the same construction-order reason.
    var customCommandRunner: CustomCommandRunner?

    /// The command-palette controller, so the "Select Theme…" action and the View menu item can open
    /// the `.themes` palette. Wired in the scene `.task` (the controller is `agtermApp` `@State`).
    var palette: PaletteController?

    /// Both theme slots captured when the picker opened, restored on Esc/cancel. Snapshotting the WHOLE pair
    /// (not just the on-screen slot) is what makes the revert flip-safe across a mid-preview macOS appearance
    /// switch, whichever slot the preview wrote. `themePreviewActive` gates preview/commit/cancel so the
    /// hooks are inert outside the picker.
    var themePreviewActive = false
    var themePreviewOriginal: (theme: String?, dark: String?)?

    /// The `.agtermAutoFollowed` observer token. Installed once in `init` (the app builds one `AppActions`)
    /// so an idle auto-follow in the key window moves first responder into the newly selected session.
    private var autoFollowObserver: NSObjectProtocol?

    /// Cancels every window-scoped picker when AppKit begins termination — the same synchronous notification
    /// as the delegate's quit flush, but never `applicationShouldTerminate`: a caller waiting on a pick gets
    /// `cancelled` without delaying the quit-confirmation prompt or termination.
    private var terminationObserver: NSObjectProtocol?

    init(library: WindowLibrary) {
        self.library = library
        // agtermCore can't call `focusActiveSession`, so `AppStore.autoFollowFire` posts and we resolve +
        // focus here, on the main queue.
        autoFollowObserver = NotificationCenter.default.addObserver(
            forName: .agtermAutoFollowed, object: nil, queue: .main
        ) { [weak self] note in
            let sessionID = note.userInfo?[AppStore.autoFollowSessionIDKey] as? UUID
            let indicator = note.userInfo?[AppStore.autoFollowIndicatorKey] as? AgentIndicator
            MainActor.assumeIsolated { self?.autoFollowed(sessionID, indicator: indicator) }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAllPendingPicks() }
        }
    }

    // isolated so it can read the `@MainActor` non-Sendable observer tokens registered in init. AppActions
    // is app-lifetime (one per app), so this rarely runs, but an unbalanced addObserver is a latent leak.
    isolated deinit {
        if let autoFollowObserver { NotificationCenter.default.removeObserver(autoFollowObserver) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
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
        // a user-initiated selection: note activity so it buys the full idle grace before auto-follow can
        // pull the selection off the just-made session.
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
    }

    /// The cwd for a new session, resolved from the new-session-directory setting (home / the current
    /// session's cwd / a fixed custom dir) against the active session's focused-pane cwd; home when
    /// `settingsModel` isn't wired yet or the setting resolves there. Shared by `newSession()` and the
    /// sidebar row's New Session. Read as the `addSession` argument, so it captures the cwd BEFORE the new
    /// session exists.
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
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
    }

    /// Opens a new session at `directory` in the last-active window — the target of `open -a agterm /path`
    /// (the OS "open terminal here" integration). Mirrors `newSession()` (note-activity + select + focus)
    /// but seeds the cwd from `directory`. Resolves `library.activeStore` (the frontmost/last-active window,
    /// the control channel's `session.new` default) and is NOT `uiActionsEnabled` gated: an external OS
    /// command, like a socket command, must land through a modal zoom/dashboard. Returns whether a session
    /// was created, so the delegate's drain can retry until the frontmost store resolves.
    func openSession(atDirectory directory: String) -> Bool {
        guard let store, let workspaceID = store.currentWorkspaceID,
              let session = store.addSession(toWorkspace: workspaceID, cwd: directory)
        else { return false }
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
        return true
    }

    /// Duplicates a session — a fresh shell in the source's directory, placed right after it. Store-scoped
    /// like the other sidebar row actions, so a background window's context menu acts on its own row, not
    /// the frontmost store's session. The directory-only contract is `AppStore.duplicateSession`'s; this
    /// adds the select + focus New Session does. Returns nothing (like `newSession`/`openDirectory`) — the
    /// control path calls `store.duplicateSession` directly for the id.
    func duplicateSession(_ id: UUID, in store: AppStore) {
        guard let session = store.duplicateSession(id) else { return }
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
    }

    /// Duplicate the ACTIVE session — the entry point for the menu bar, the ⌃P palette, and a
    /// `duplicate_session` keymap binding (mirroring `renameActiveSession()` vs the sidebar's row-scoped
    /// `duplicateSession(_:in:)`), acting on the frontmost store's selected session.
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

    // closes the active session, or dismisses a focus-stealing cover over it; returns whether it handled
    // the keystroke, so the ⌘W menu item falls back to closing the window only with no cover and no
    // session. precedence is z-order: the window-topmost quick terminal (works with no active session),
    // then a session's overlay above its scratch. the overlay is DESTROYED (closeOverlay, run-once
    // ephemeral) while quick/scratch are hidden keep-alive; a floating overlay holds first responder too,
    // so ANY overlay is dismissed, not only a full one.
    @discardableResult
    func closeActiveSession() -> Bool {
        // A pick is an external caller waiting on an answer, so it is the first ⌘W layer even when a
        // terminal is zoomed behind it. Resolve rather than merely hiding it so the caller can finish.
        if cancelPendingPick(for: library.activeWindowID) { return true }
        // zoom is the topmost cover: ⌘W dismisses it stepwise (a zoomed quick terminal un-zooms first, the
        // next ⌘W hides it) instead of swallowing the keystroke, never mutating hidden session/window state
        // behind it. the dashboard grid is the other modal cover (mutually exclusive with zoom) — close it
        // and refocus rather than closing the session behind it.
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

    /// Resolve the pending picker owned by `windowID` as cancelled. Used by ⌘W and app termination;
    /// window teardown cancels through `PickRegistry.unregister` so it can retain the terminal result.
    @discardableResult
    func cancelPendingPick(for windowID: WindowInfo.ID?) -> Bool {
        guard let controller = PickRegistry.shared.controller(for: windowID),
              controller.pending != nil
        else { return false }
        controller.cancel()
        return true
    }

    /// Resolve every open window's pending picker during the synchronous app-termination notification. The
    /// library retains its open ids through quit teardown, so every mounted controller is still addressable.
    func cancelAllPendingPicks() {
        for windowID in library.openIDs() {
            cancelPendingPick(for: windowID)
        }
    }

    /// Close session `id` in `store` from a GUI surface (the sidebar row's Close), honoring the "Confirm
    /// before closing a session" setting. `store` is passed in, not resolved from the frontmost
    /// `activeStore`: a background window's sidebar must close ITS session. ⌘W/menu/palette instead use
    /// `closeActiveSession` (the frontmost active session); the control `session.close` closes with no prompt.
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

    /// Re-read and re-parse `keymap.conf`, re-rendering the data-driven menu shortcuts and rebuilding the
    /// custom-command runner + the palette's custom items. Shared by the View menu item, the action palette,
    /// and `keymap.reload`. No-op before the scene wires the settings model.
    func reloadKeymap() { settingsModel?.reloadKeymap() }

    /// The session whose currently-open overlay is the keymap editor, so `WindowContentView`'s overlay
    /// onChange can reload the keymap when that overlay closes. Nil when no keymap-edit overlay is up.
    var keymapEditOverlaySession: UUID?

    /// Open `keymap.conf` in the user's editor (`$VISUAL`/`$EDITOR`, else `vi`) in a 95% floating overlay
    /// over the active session, through the login shell so an `$EDITOR` exported from login-shell startup is
    /// honored. The editor exiting reloads the keymap (`WindowContentView`'s overlay-close onChange). No-op
    /// with no active session, before the settings model is wired, or with an overlay already open.
    func editKeymap() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID, let path = settingsModel?.keymapPath else { return }
        if store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95) {
            keymapEditOverlaySession = id
        }
    }

    /// Re-read the ghostty config and rebroadcast it to every live surface (`SettingsModel.reloadGhosttyConfig`
    /// posts the diagnostics warning banner, mirroring `reloadKeymap`). Returns the config-diagnostic count
    /// (0 = clean, and 0 before the scene wires the settings model) so the control channel reports what the
    /// reload actually produced. Shared by File ▸ Reload Config, the action palette, the Edit-ghostty overlay
    /// close, and `config.reload`.
    @discardableResult
    func reloadGhosttyConfig() -> Int {
        settingsModel?.reloadGhosttyConfig() ?? 0
    }

    /// The session whose currently-open overlay is the ghostty.conf editor, so `WindowContentView`'s overlay
    /// onChange can reload the config when that overlay closes. Nil when no ghostty-edit overlay is up.
    var ghosttyEditOverlaySession: UUID?

    /// The `ghostty.conf` contents captured when the Edit-ghostty overlay opened, so the close path can skip
    /// the reload (and its per-session font-zoom reset) on a no-op editor session. Nil when none is up.
    private var ghosttyEditOverlaySnapshot: String?

    /// Open `ghostty.conf` in the user's editor in a 95% floating overlay over the active session, mirroring
    /// `editKeymap` (login shell, so an exported `$VISUAL`/`$EDITOR` is honored, else `vi`; the editor
    /// exiting reloads the config via `WindowContentView`'s overlay-close onChange). Captures the file
    /// contents so that path reloads only on a real change. Same no-ops as `editKeymap`.
    func editGhosttyConfig() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID, let path = settingsModel?.ghosttyConfigPath else { return }
        if store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95) {
            ghosttyEditOverlaySession = id
            ghosttyEditOverlaySnapshot = try? String(contentsOfFile: path, encoding: .utf8)
        }
    }

    /// On Edit-ghostty overlay close: reload only if the file changed since the editor opened, so a no-op
    /// open/close does not clear per-session ⌘+/⌘− zoom (the reload's font reset). Explicit File ▸ Reload
    /// Config / `config.reload` stay unconditional — the guard covers only the editor round-trip.
    func reloadGhosttyConfigIfEdited() {
        let before = ghosttyEditOverlaySnapshot
        ghosttyEditOverlaySnapshot = nil
        let after = settingsModel.flatMap { try? String(contentsOfFile: $0.ghosttyConfigPath, encoding: .utf8) }
        guard before != after else { return }
        reloadGhosttyConfig()
    }

    /// Step the selection prev/next, or to first/last, in the sidebar's flattened visual order — the logic
    /// is `navigateSession`'s, so the GUI, palette and control channel can't drift. Routes through
    /// `selectSession` (recency/badge/persist/workspace), then moves first responder into the moved-to
    /// session's focused pane, and notes the manual nav as user activity so it buys the full idle grace
    /// against auto-follow (the control `session.go` drives `navigateSession` directly and stays silent).
    /// A step resolving to the ALREADY-selected session reveals nothing and just re-focuses: next/previous
    /// wrap inside the filtered set (a one-element set re-selects), first/last repeat at that end, and
    /// `selectSession` does not short-circuit a same-target select, so it still returns an indicator —
    /// revealing on it would clear `splitFocused` and yank first responder onto the primary pane on a
    /// keystroke that moved nothing, off the split being typed in. Attention nav DOES reveal on its no-op;
    /// see below for why.
    private func navigatePlain(_ direction: SessionNavigation) {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        let before = store?.selectedSessionID
        // no live-indicator fallback here (unlike attention nav): a plain direction returns nil only when
        // `navigableSessions` is EMPTY, and then nothing was selected, which the moved-check below catches.
        let indicator = store?.navigateSession(direction)
        guard store?.selectedSessionID != before else { focusActiveSession(); return }
        revealActiveBlockedPane(captured: indicator)
    }

    func selectNextSession() { navigatePlain(.next) }
    func selectPreviousSession() { navigatePlain(.previous) }
    func selectFirstSession() { navigatePlain(.first) }
    func selectLastSession() { navigatePlain(.last) }

    /// Step to the next/previous session needing attention (`blocked`/`completed`), wrapping around and
    /// skipping idle/active. Shares `navigateSession` with the GUI, palette, and `session.go
    /// next-attention|prev-attention`. Notes user activity like plain nav, then `revealActiveBlockedPane`
    /// focuses the split/scratch pane that SET the status, not just the session's plain focused pane.
    /// Unlike plain nav this DOES reveal on a selection no-op, and only the `?? activeSession?.agentIndicator`
    /// fallback makes it: `attentionTarget` EXCLUDES the current session, so when the sole session needing
    /// attention is the selected one it returns nil and `navigateSession` selects nothing. Without the
    /// fallback the reveal degrades to plain `focusActiveSession` and ⌃⌥↑/↓ stops landing on that session's
    /// tagged pane — constant for an agent, since a pane-scoped block is not cleared by typing in the OTHER
    /// pane. Do not drop it as redundant.
    func selectNextAttentionSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        let indicator = store?.navigateSession(.nextAttention) ?? store?.activeSession?.agentIndicator
        revealActiveBlockedPane(captured: indicator)
    }
    func selectPreviousAttentionSession() {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        let indicator = store?.navigateSession(.previousAttention) ?? store?.activeSession?.agentIndicator
        revealActiveBlockedPane(captured: indicator)
    }

    /// Delete a workspace and all its sessions from `store`'s window. Confirms when it still has sessions
    /// (the delete ends their shells); an empty one deletes without a prompt; no-op when only one workspace
    /// remains — one is always kept. Driven by the row's "Delete Workspace" item, which passes its OWN
    /// window-local store (like Close/Flag/Duplicate/Focus): the item's enabled state came from that store,
    /// and the frontmost one would find no such id and silently do nothing. Ungated like the other
    /// store-scoped row actions — a window renders no sidebar while its zoom or dashboard is up, so the row
    /// menu is unreachable in exactly the state the gate covers, and a frontmost modal must not block a
    /// background window's row.
    func deleteWorkspace(_ workspaceID: UUID, in store: AppStore) {
        guard store.canRemoveWorkspace,
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
    /// action palette, which have no clicked row and so act on the frontmost window by definition.
    func deleteActiveWorkspace() {
        guard uiActionsEnabled, let store, let id = store.currentWorkspaceID else { return }
        deleteWorkspace(id, in: store)
    }

    private func confirmDeleteWorkspace(_ workspace: Workspace) -> Bool {
        confirmDelete(name: workspace.name, sessionCount: workspace.sessions.count)
    }

    /// A standard warning confirm for deleting a named container (workspace or window) still holding
    /// `sessionCount` sessions — the delete ends their running shells. Returns whether the user confirmed.
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

    // MARK: - Sidebar tree expansion

    /// Expand every workspace in the frontmost window's sidebar (the GUI menu/palette target). No-op when
    /// no window is open.
    func expandAllWorkspaces() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        expandAllWorkspaces(in: store)
    }

    /// Expand every workspace in `store`'s window sidebar. The sidebar owns the outline, so this posts a
    /// notification carrying that store as the object and `WorkspaceSidebar.Coordinator` observes with
    /// `object: store`, so only that window's sidebar acts — how `sidebar.expand` targets a specific
    /// (default frontmost) window. A graceful no-op in flagged mode (no workspace rows).
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

    /// Collapse every workspace except the active session's in `store`'s window sidebar, keeping that one
    /// expanded and scrolled into view. Store-object-scoped to that window's Coordinator (see
    /// `expandAllWorkspaces(in:)`), a graceful no-op in flagged mode, and how `sidebar.collapse` targets a
    /// specific (default frontmost) window.
    func collapseOtherWorkspaces(in store: AppStore) {
        NotificationCenter.default.post(name: .agtermCollapseWorkspaces, object: store)
    }

    /// Collapse/expand a SINGLE workspace in `store`'s window sidebar — the `workspace.collapse`/`.expand`
    /// control path, distinct from the all-workspace pair above, and its only caller (a GUI row click drives
    /// the outline directly). Persists `Workspace.isExpanded` DIRECTLY on the store (source of truth for the
    /// `collapsed` read-back, delta-guarded so it's idempotent), THEN posts a store-scoped notification so
    /// the matching `WorkspaceSidebar.Coordinator` syncs the live outline row + its tracked expansion set
    /// (`setWorkspaceExpandedNotified`). The persist must NOT ride the notification: `WindowContentView`
    /// mounts the Coordinator only while `sidebarVisible`, so with the sidebar hidden a notification-only
    /// write drops silently and leaves the read-back stale. Mirrors `workspace.focus`/`session.resize`,
    /// which also persist in the arm and post only for the live view.
    func setWorkspaceExpanded(_ id: UUID, expanded: Bool, in store: AppStore) {
        store.setWorkspaceExpanded(id, expanded: expanded)
        NotificationCenter.default.post(
            name: .agtermSetWorkspaceExpanded, object: store,
            userInfo: [WorkspaceSidebar.Coordinator.workspaceIDUserInfoKey: id,
                       WorkspaceSidebar.Coordinator.expandedUserInfoKey: expanded])
    }

    // MARK: - Flagged working-set

    /// Toggle a session's flagged membership (the durable working-set the flat sidebar view projects); clean
    /// no-op on an unknown id. Driven by the sidebar row's "Flag"/"Unflag" context-menu item.
    func toggleFlag(_ sessionID: UUID) {
        guard uiActionsEnabled else { return }
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
        guard uiActionsEnabled else { return }
        guard let store else { return }
        store.setSidebarMode(store.sidebarMode == .flagged ? .tree : .flagged)
    }

    /// Unflag every session across all workspaces, confirming first when at least one is flagged (a bulk
    /// change) and doing nothing when none is. Skips the confirm under an XCUITest launch — a modal hangs it.
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

    /// Create a fresh window (one default workspace + session) and open it via the scene's window opener
    /// (the seam the control channel uses). No-op before the scene `.task` wires the opener.
    ///
    /// `ignoringModals` skips the frontmost-window modal gate. Creating a window touches no existing
    /// window's state, so the Dock item passes true — a dashboard or terminal zoom in whatever window
    /// happened to be last active must not make it inert, the whole point of driving agterm from the Dock.
    /// The menu bar and palette keep the gate (File ▸ New Window mirrors it with `.disabled(modalActive)`).
    func newWindow(ignoringModals: Bool = false) {
        guard ignoringModals || uiActionsEnabled else { return }
        // `library.newWindow()` persists an entry marked open, so creating without an opener would leave a
        // window the app counts as open with no NSWindow behind it.
        guard let openWindow else { return }
        let info = library.newWindow()
        openWindow(info.id)
    }

    /// Surface a window: raise it if already open, else open it (the opener claims its id + spawns a
    /// new on-screen window). Used by the File ▸ Open Window submenu and the palette.
    func openWindow(_ id: WindowInfo.ID) {
        guard uiActionsEnabled else { return }
        openWindow?(id)
    }

    /// Rename the frontmost window via a one-shot `NSAlert` with an accessory text field pre-filled with the
    /// current name — inline rename is sidebar-row-only and a window has no row, so the alert is the
    /// standard, minimal fit. The rename flows through `library.renameWindow`, the control channel's seam.
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

    /// Start an inline rename of the active session. The sidebar owns the edit field, so this posts a
    /// notification it observes; `renamePending` keeps the palette-close focus restore off the field while
    /// the edit starts. The post carries the frontmost STORE as its object and `WorkspaceSidebar.Coordinator`
    /// registers with `object: store`, so only that window edits (the `expandAllWorkspaces(in:)` scoping).
    /// A nil object reached EVERY open window's coordinator — their `selectedSessionID` guard scopes
    /// nothing, since every window has a selection — so each opened an unused editor and leaked one
    /// unbalanced `suppressAutoFollow`.
    func renameActiveSession() {
        guard uiActionsEnabled else { return }
        guard let store, store.activeSession != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtermBeginRenameSession, object: store)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    /// Start an inline rename of the active session's workspace (the same one new sessions land in).
    /// Store-scoped like `renameActiveSession` above, for the same reason.
    func renameActiveWorkspace() {
        guard uiActionsEnabled else { return }
        guard let store, store.currentWorkspaceID != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtermBeginRenameWorkspace, object: store)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    // MARK: - Split

    /// Toggle the active session's split. A NEW split shows both panes and focuses the new (right) one;
    /// closing HIDES it (both shells stay alive, nothing destroyed) and shows the focused pane maximized, so
    /// reopening restores both in their original positions with the SAME pane focused. Focus follows
    /// `splitFocused`, which `AppStore.toggleSplit` moves only for a genuinely new split.
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

    /// Move keyboard focus to a pane of the active session's split: `.split` -> the right pane, anything
    /// else -> the left/primary. No-op when the active session has no split; works whether the split is shown
    /// side-by-side or hidden (maximized). Drives the keyboard shortcuts, the View menu items, and the palette.
    func focusPane(_ pane: PaneRole) {
        guard uiActionsEnabled else { return }
        guard let session = store?.activeSession else { return }
        setSplitFocus(pane == .split, of: session)
    }

    /// Set which pane of a session's split holds focus and move first responder there. Shared by the GUI
    /// `focusPane` and the control channel (which may target a non-active session). Updates `splitFocused`
    /// so the pane dim, sidebar and title bar follow. Works shown side-by-side or hidden — when hidden,
    /// flipping `splitFocused` swaps which pane shows maximized. No-op only when the session has no split.
    func setSplitFocus(_ toSplit: Bool, of session: Session) {
        guard session.hasSplit else { return }
        session.splitFocused = toSplit
        focusSplitPane(session, wantSplit: toSplit)
    }

    // MARK: - Quick terminal (frontmost window)

    /// Toggle the frontmost window's quick terminal (each window owns its own controller). Gated on the full
    /// `uiActionsEnabled` (zoom, dashboard AND native picker), not zoom alone — defence in depth, not a gap
    /// being closed, since all three callers already gate: View ▸ Quick Terminal's `.disabled(modalActive)`
    /// (which covers a `keymap.conf` rebind too, that rebind being the item's own key equivalent), the
    /// palette's `runPaletteCommand` check, and the Dock item's invocation-time `uiActionsEnabled(for:)`.
    func toggleQuickTerminal() {
        guard uiActionsEnabled else { return }
        frontmostQuickTerminal?.toggle()
    }

    /// Toggle the frontmost window's full-window terminal zoom. Core resolves which surface is active
    /// (quick, overlay, scratch, split, or primary); the owning window renders it above all chrome.
    func toggleTerminalZoom() {
        guard !pickActive(for: library.activeWindowID) else { return }
        frontmostTerminalZoom?.toggle()
    }

    /// Toggle the frontmost window's dashboard — the ⌘⇧D / Navigate ▸ Dashboard opener for the MRU grid,
    /// equivalent to `agtermctl dashboard --mru --auto-size`. Inert while terminal zoom or a pending native
    /// picker is up (mirroring the GUI siblings and menu disablement), but NOT while the dashboard itself is
    /// open, so the grid stays its own close escape hatch. Open → close and refocus the active session;
    /// closed → open over the window's most-recently-used sessions, auto-sized; no-op with no recent sessions.
    func toggleDashboard() {
        guard !terminalZoomActive, !pickActive(for: library.activeWindowID) else { return }
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
        // set the applied size synchronously (the SwiftUI onChange applies surface overrides a runloop turn
        // later), through the same DashboardFontMode seam as ControlServer.setDashboard so the GUI and
        // control opens land on the identical auto size.
        let base = settingsModel?.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
        dashboard.setAppliedFontSize(DashboardFontMode.auto.appliedFontSize(memberCount: members.count, base: base))
    }

    /// Toggle native macOS full screen for the key window (the frontmost terminal window): it matches the
    /// green traffic-light button and moves the window to its own Space, a second invocation exits. Shared
    /// by View ▸ Toggle Full Screen (⌃⌘F), the ⌃⇧P palette, `toggle_fullscreen`, and `window.fullscreen`.
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

    /// The search-capable target. A covering SCRATCH wins FIRST (`topmostSurface` while `scratchActive` with
    /// no overlay), so ⌘F over a scratch never opens the bar on the hidden pane beneath — even with key-window
    /// focus off the surface (e.g. the sidebar), where `focusedSurface()` would fall back to the hidden
    /// `activeSurface`. Else the focused surface IFF searchable (the main/split pane), else the active
    /// session's focused pane. Full overlay and quick terminal are unsearchable (blocked by
    /// `coverHidesActiveSession`); a FLOATING overlay leaves the pane visible, so search targets that pane.
    private func searchTarget() -> GhosttySurfaceView? {
        if let session = store?.activeSession, session.scratchActive, !session.overlayActive {
            return session.topmostSurface as? GhosttySurfaceView
        }
        if let view = focusedSurface(), view.isSearchable { return view }
        return store?.activeSession?.activeSurface as? GhosttySurfaceView
    }

    /// Whether a cover BLOCKS ⌘F — the frontmost window's quick terminal, or the active session's FULL
    /// overlay. Neither is searchable, so the bar would strand over a hidden pane. The scratch is NOT a
    /// blocker: it IS searchable, so ⌘F opens the bar over the scratch itself. The ⌘F-again CLOSE still runs
    /// regardless of any cover.
    private var coverHidesActiveSession: Bool {
        if frontmostQuickTerminal?.isVisible == true { return true }
        guard let session = store?.activeSession else { return false }
        // a FLOATING overlay leaves the session visible, so only a FULL overlay hides it (and is not searchable).
        return session.fullOverlayActive
    }

    /// Toggle the search bar for the active session; shared by the Find menu item, the palette, and ⌘F.
    /// CLOSE (search already active): send `end_search` DIRECTLY to the session's pinned `searchSurface` (the
    /// surface that opened search) so the END callback clears the fields and refocuses — never a re-resolved
    /// target or a `start_search` round-trip, which on a split with focus moved to the OTHER pane would put
    /// that pane into search mode while `onSearchStart` closes only the pinned owner, stranding it. OPEN:
    /// no-op with no searchable surface (never bar-less search on a quick/scratch/overlay surface) or behind
    /// a cover, else `start_search` on the search target, whose `onSearchStart` opens the bar and pins it.
    func toggleSearch() {
        guard !pickActive(for: library.activeWindowID) else { return }
        if store?.activeSession?.searchActive == true {
            (store?.activeSession?.searchSurface as? GhosttySurfaceView)?.endSearch()
            return
        }
        guard !terminalZoomActive else { return }
        guard let target = searchTarget(), !coverHidesActiveSession else { return }
        target.startSearch()
    }

    /// Set the current query: mirror it into the active session's `searchNeedle` (keeping the bar's field in
    /// sync) then send `search:<needle>` to the pinned `searchSurface`, which replies with the new match
    /// count. Driving the pinned owner rather than a re-resolved focused surface keeps the bar on the pane
    /// that opened search after a split focus move. An empty needle clears count/selected eagerly, so the
    /// counter blanks at once instead of flashing the stale "N of M" until libghostty's async teardown lands.
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

    /// Close search: send `end_search` to the session's pinned `searchSurface` so it really exits search mode
    /// (never just flips the flag). The END_SEARCH callback is the single clear point — it clears the
    /// session's fields and the pinned owner and returns first responder to the terminal — so this only
    /// sends the binding action.
    func endSearch() {
        (store?.activeSession?.searchSurface as? GhosttySurfaceView)?.endSearch()
    }

    // MARK: - Focus

    /// Per-window focus generation counters (keyed by owning window id, bumped in AppActions+Focus). A fresh
    /// `focusSplitPane` bumps its window's counter so a superseded in-flight retry loop in the SAME window
    /// cancels itself — killing the opposite-target ping-pong flicker, last-focus-wins per window. Keyed by
    /// window (one NSWindow = one first responder) so one window's focus op never cancels another's
    /// still-materializing retry.
    var focusGeneration: [UUID: Int] = [:]

    /// The focused terminal: the key window's first responder if it's a surface (covers the main
    /// pane, the split pane, and the quick terminal), else the active session's focused pane.
    private func focusedSurface() -> GhosttySurfaceView? {
        if let view = NSApp.keyWindow?.firstResponder as? GhosttySurfaceView { return view }
        return store?.activeSession?.activeSurface as? GhosttySurfaceView
    }
}
