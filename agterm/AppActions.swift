import agtermCore
import AppKit
import SwiftUI

/// User actions shared by the toolbar / bottom-bar buttons and the menu bar so the two never drift: the
/// ones with real logic — new-session placement, the directory picker, split/focus/font. Trivial one-liners
/// (quick-terminal / status-bar toggle) call the controller/store directly instead.
@MainActor
final class AppActions {
    /// The window library. Resolves the frontmost window's store per call rather than holding a fixed one,
    /// so menu bar / palette / control channel all drive the window the user is looking at.
    let library: WindowLibrary

    /// The frontmost open window's store, the target of every mutating action. Nil only with all windows
    /// closed (quitting), where callers no-op.
    var store: AppStore? { library.activeStore }

    /// The app's one quick terminal, which lives in a detached panel rather than in a window — so unlike the
    /// zoom/dashboard/pick controllers beside it there is nothing to resolve and nothing to be nil.
    var quickTerminal: QuickTerminalController { .shared }

    /// The frontmost window's zoom controller; `WindowContentView` renders its target above the chrome.
    private var frontmostTerminalZoom: TerminalZoomController? {
        TerminalZoomRegistry.shared.controller(for: library.activeWindowID)
    }

    /// The frontmost window's dashboard controller (one per window). Nil when no window is open.
    var frontmostDashboard: DashboardController? {
        DashboardControllerRegistry.shared.controller(for: library.activeWindowID)
    }

    var terminalZoomActive: Bool {
        frontmostTerminalZoom?.target != nil
    }

    /// Frontmost-window shorthand for the modal gate: while terminal zoom, the dashboard grid or a pending
    /// native picker is up, keyboard/menu/palette actions must not mutate the deck behind it. Dismissal stays
    /// callable so the user is never trapped (the dashboard toggle survives its own grid; zoom/dashboard
    /// toggles are blocked behind a picker). With no window open it DENIES, so nothing runs during teardown.
    var uiActionsEnabled: Bool { uiActionsEnabled(for: library.activeWindowID) }

    /// The modal gate for a specific window — for session-addressed entry points whose target may have
    /// changed while an external menu was tracking.
    func uiActionsEnabled(for windowID: WindowInfo.ID?) -> Bool {
        guard let windowID else { return false }
        return TerminalZoomRegistry.shared.controller(for: windowID)?.target == nil
            && DashboardControllerRegistry.shared.controller(for: windowID)?.isOpen != true
            && PickRegistry.shared.controller(for: windowID)?.pending == nil
    }

    /// Set while a rename starts, so the palette / quick-terminal close focus-restore skips the rename field.
    var renamePending = false

    /// Opens (or raises) a window by id. SwiftUI's `openWindow` is an `@Environment` value reachable only
    /// inside the scene, so `agtermApp` wires this at launch. Used by the cross-window notification reveal
    /// for a banner-clicked session whose window had closed. Nil before the scene `.task` runs.
    var openWindow: ((WindowInfo.ID) -> Void)?

    /// The settings model, holding the parsed keymap whose custom commands feed the action palette. It and
    /// `customCommandRunner` are built AFTER `actions` in `agtermApp.init`, so both are wired from the scene
    /// `.task` rather than passed to `init(library:)` — an init-order break. Nil until that `.task` runs.
    var settingsModel: SettingsModel?

    /// The custom-command runner the palette's custom items invoke. Wired in the scene `.task` like `settingsModel`.
    var customCommandRunner: CustomCommandRunner?

    /// The command-palette controller, so "Select Theme…" and the View menu item can open the `.themes`
    /// palette. Wired in the scene `.task`.
    var palette: PaletteController?

    /// Both theme slots captured when the picker opened, restored on Esc/cancel. Snapshotting the WHOLE pair
    /// keeps the revert flip-safe across a mid-preview macOS appearance switch, whichever slot the preview
    /// wrote. `themePreviewActive` gates preview/commit/cancel so the hooks are inert outside the picker.
    var themePreviewActive = false
    var themePreviewOriginal: (theme: String?, dark: String?)?

    /// The `.agtermAutoFollowed` observer token, installed once in `init` so an idle auto-follow in the key
    /// window moves first responder into the newly selected session.
    private var autoFollowObserver: NSObjectProtocol?

    /// Cancels every window-scoped picker on the synchronous `willTerminate`, never on
    /// `applicationShouldTerminate`: a waiting pick caller gets `cancelled` without delaying quit.
    private var terminationObserver: NSObjectProtocol?

    init(library: WindowLibrary) {
        self.library = library
        // agtermCore can't call `focusActiveSession`, so `AppStore` posts and we resolve + focus here.
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

    // isolated to read init's `@MainActor` non-Sendable tokens; rare (app-lifetime) but an unbalanced leak.
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
        // note activity so the new session buys the full idle grace before auto-follow moves the selection.
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
    }

    /// The cwd for a new session: the new-session-directory setting (home / the current session's cwd / a
    /// fixed custom dir) resolved against the active session's focused-pane cwd, home when `settingsModel`
    /// isn't wired. Read as the `addSession` argument, so it captures the cwd BEFORE the new session exists.
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

    /// Opens a new session at `directory` in the last-active window — the target of `open -a agterm /path`,
    /// the OS "open terminal here" integration. Mirrors `newSession()` but seeds the cwd from `directory`.
    /// NOT `uiActionsEnabled` gated: an external OS command, like a socket command, must land through a modal
    /// zoom/dashboard. Returns whether one was created, so the delegate's drain retries until a store resolves.
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
    /// like the other sidebar row actions, so a background window's context menu acts on its own row. Adds
    /// the select + focus New Session does; the control path calls `store.duplicateSession` for the id.
    func duplicateSession(_ id: UUID, in store: AppStore) {
        guard let session = store.duplicateSession(id) else { return }
        store.noteUserActivity()
        store.selectSession(session.id)
        focusActiveSession()
    }

    /// Duplicate the ACTIVE session (the frontmost store's selection) — the menu bar, ⌃P palette and
    /// `duplicate_session` entry point, against the sidebar's row-scoped `duplicateSession(_:in:)`.
    func duplicateActiveSession() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID else { return }
        duplicateSession(id, in: store)
    }

    /// Reveal the active session's focused-pane cwd in Finder — the directory selected, as elsewhere on Mac.
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

    /// Reveal a session's focused-pane cwd in Finder, store-scoped so a background row menu acts on its row.
    @discardableResult
    func revealSessionInFinder(_ id: UUID, in store: AppStore) -> Bool {
        guard let session = store.session(withID: id),
              let url = DirectoryPanelDefaults.existingDirectoryURL(for: session.focusedCwd)
        else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    // closes the active session, or dismisses a focus-stealing cover over it; returns whether it handled the
    // keystroke, so the ⌘W menu item closes the window only with no cover and no session. precedence is
    // z-order: the window-topmost quick terminal (works with no active session), then a session's overlay
    // above its scratch. the overlay is DESTROYED (run-once ephemeral) while quick/scratch are hidden
    // keep-alive, and a floating overlay holds first responder too, so ANY overlay is dismissed, not only full.
    @discardableResult
    func closeActiveSession() -> Bool {
        // a pick is an external caller waiting on an answer: the first ⌘W layer even behind a zoomed terminal,
        // and resolved rather than hidden so the caller can finish.
        if cancelPendingPick(for: library.activeWindowID) { return true }
        // the quick-terminal panel floats above every window, so it outranks anything inside one — the window
        // rungs below read state the panel is covering, and clearing a zoom the user cannot see is a silent
        // mutation of state they never touched. Stepwise like zoom: a zoomed panel un-zooms first, the next
        // ⌘W hides it. Its zoom is app-level (`isZoomed`), NOT a window's `TerminalZoomTarget`.
        if quickTerminal.holdsKey, quickTerminal.isZoomed { quickTerminal.setZoom(.off); return true }
        if quickTerminal.holdsKey { quickTerminal.hide(); return true }
        // zoom is the topmost cover inside the window: ⌘W dismisses it, never mutating hidden session/window
        // state behind it. the dashboard grid is the
        // other modal cover (mutually exclusive with zoom) — close and refocus, don't close the session.
        if terminalZoomActive { frontmostTerminalZoom?.clear(); return true }
        if let dashboard = frontmostDashboard, dashboard.isOpen { dashboard.close(); focusActiveSession(); return true }
        guard let store, let session = store.activeSession else { return false }
        if session.overlayActive { store.closeOverlay(session.id); return true }
        if session.scratchActive { store.toggleScratch(session.id); return true }
        // the focused pane's own overlay is the last cover: without this rung ⌘W over one falls straight
        // through and closes the SESSION. An overlay on the other pane is not in front of the user, so it
        // does not intercept — that pane stays live and ⌘W keeps its ordinary meaning.
        if let pane = session.focusedOverlayPane { store.closePaneOverlay(session.id, pane: pane); return true }
        // handled either way — returning true on cancel keeps the File menu from closing the whole window.
        guard confirmCloseSession(session) else { return true }
        closeSessionAfterConfirmation(session.id, in: store)
        focusActiveSession()
        return true
    }

    /// The whole close-session keystroke as File ▸ Close Session performs it: dismiss the frontmost cover or
    /// close the active session, and when there was neither — a zero-session window — close `window` instead.
    /// Shared with the key monitor so a `close_session` alternative cannot be the one binding that dies in a
    /// window with nothing left to close.
    func closeActiveSessionOrWindow(_ window: NSWindow?) {
        if !closeActiveSession() { window?.performClose(nil) }
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
    /// before closing a session" setting. `store` is passed in so a background window's sidebar closes ITS
    /// session; ⌘W/menu/palette use `closeActiveSession`, and the control `session.close` never prompts.
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

    /// A native warning confirm before closing `session`, gated by `AppSettings.confirmCloseSession`. Returns
    /// whether to proceed: true with no prompt when the setting is off or under XCUITest (a modal hangs it).
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

    /// Clear the active session's agent-status indicator to idle, like `agtermctl session status idle` and
    /// the sidebar row's "Clear Status". No-op when nothing is selected.
    func clearActiveSessionStatus() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID else { return }
        store.setAgentIndicator(AgentIndicator(), forSession: id)
    }

    /// Re-read `keymap.conf`, re-rendering the menu shortcuts and rebuilding the custom-command runner +
    /// palette items. Shared by the View menu, the palette and `keymap.reload`; no-op before the model wires.
    func reloadKeymap() { settingsModel?.reloadKeymap() }

    /// The session whose open overlay is the keymap editor, so its close reloads the keymap. Nil when none.
    var keymapEditOverlaySession: UUID?

    /// Open `keymap.conf` in the user's editor (`$VISUAL`/`$EDITOR`, else `vi`) in a 95% floating overlay
    /// over the active session, via the login shell so an exported `$EDITOR` is honored; exiting reloads the
    /// keymap. No-op with no active session, before the settings model is wired, or with a caller's PROGRAM
    /// in the overlay slot — a HUD there yields, as it does to any `openOverlay`.
    func editKeymap() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID, let path = settingsModel?.keymapPath else { return }
        if store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95) {
            keymapEditOverlaySession = id
        }
    }

    /// Re-read the ghostty config and rebroadcast it to every live surface; `SettingsModel` posts the
    /// diagnostics banner, mirroring `reloadKeymap`. Returns the diagnostic count (0 = clean, and 0 before the
    /// model is wired) so the control channel reports what the reload produced. Shared by File ▸ Reload
    /// Config, the palette, the Edit-ghostty overlay close, and `config.reload`.
    @discardableResult
    func reloadGhosttyConfig() -> Int {
        settingsModel?.reloadGhosttyConfig() ?? 0
    }

    /// The session whose open overlay is the ghostty.conf editor, so its close reloads the config. Nil when none.
    var ghosttyEditOverlaySession: UUID?

    /// The `ghostty.conf` contents captured when the Edit overlay opened, so a no-op editor session skips the
    /// reload and its per-session font-zoom reset. Nil when none is up.
    private var ghosttyEditOverlaySnapshot: String?

    /// Open `ghostty.conf` in the user's editor in a 95% floating overlay over the active session, mirroring
    /// `editKeymap` (login shell, exported `$VISUAL`/`$EDITOR` else `vi`; exiting reloads the config).
    /// Captures the file contents so that path reloads only on a real change. Same no-ops as `editKeymap`.
    func editGhosttyConfig() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID, let path = settingsModel?.ghosttyConfigPath else { return }
        if store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95) {
            ghosttyEditOverlaySession = id
            ghosttyEditOverlaySnapshot = try? String(contentsOfFile: path, encoding: .utf8)
        }
    }

    /// On Edit-ghostty overlay close: reload only if the file changed, so a no-op open/close does not clear
    /// per-session ⌘+/⌘− zoom (the reload's font reset). File ▸ Reload Config / `config.reload` stay unconditional.
    func reloadGhosttyConfigIfEdited() {
        let before = ghosttyEditOverlaySnapshot
        ghosttyEditOverlaySnapshot = nil
        let after = settingsModel.flatMap { try? String(contentsOfFile: $0.ghosttyConfigPath, encoding: .utf8) }
        guard before != after else { return }
        reloadGhosttyConfig()
    }

    /// Step the selection prev/next/first/last in the sidebar's flattened visual order, through shared
    /// `navigateSession` so GUI, palette and control can't drift, then `selectSession`
    /// (recency/badge/persist/workspace) and first responder into the moved-to session's focused pane. Notes
    /// the manual nav as user activity for the full idle grace against auto-follow; control `session.go`
    /// drives `navigateSession` directly and stays silent. A step landing on the ALREADY-selected session only
    /// re-focuses (next/previous wrap inside the filtered set, first/last repeat at that end): `selectSession`
    /// still returns an indicator for a same-target select, and revealing on it would clear `splitFocused` and
    /// yank first responder onto the primary pane, off the split being typed in. Attention nav DOES reveal.
    private func navigatePlain(_ direction: SessionNavigation) {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        let before = store?.selectedSessionID
        // no live-indicator fallback (unlike attention nav): a plain direction returns nil only when
        // `navigableSessions` is EMPTY, and then nothing was selected, which the moved-check below catches.
        let indicator = store?.navigateSession(direction)
        guard store?.selectedSessionID != before else { focusActiveSession(); return }
        revealActiveBlockedPane(captured: indicator)
    }

    func selectNextSession() { navigatePlain(.next) }
    func selectPreviousSession() { navigatePlain(.previous) }
    func selectFirstSession() { navigatePlain(.first) }
    func selectLastSession() { navigatePlain(.last) }

    /// Step the CURRENT workspace prev/next through the sidebar's visible order and select its first session,
    /// through shared `navigateWorkspace` so the menu, the palette and `workspace.go` can't drift. Notes the
    /// step as user activity like session nav, then routes pane reveal off the step's captured indicator —
    /// the same treatment plain session nav gives, so where focus lands does not depend on which keystroke
    /// got you there. A step with nowhere to go (flagged mode, one visible workspace) leaves focus alone.
    private func navigateWorkspace(_ direction: WorkspaceNavigation) {
        guard uiActionsEnabled else { return }
        store?.noteUserActivity()
        guard let step = store?.navigateWorkspace(direction) else { return }
        revealActiveBlockedPane(captured: step.indicator)
    }

    func selectNextWorkspace() { navigateWorkspace(.next) }
    func selectPreviousWorkspace() { navigateWorkspace(.previous) }

    /// Step to the next/previous session needing attention (`blocked`/`completed`), wrapping and skipping
    /// idle/active, through `navigateSession` shared with the palette and `session.go next-attention|prev-attention`.
    /// Notes user activity like plain nav, then `revealActiveBlockedPane` focuses the split/scratch pane that
    /// SET the status. Unlike plain nav this DOES reveal on a selection no-op, and only the
    /// `?? activeSession?.agentIndicator` fallback makes it: `attentionTarget` EXCLUDES the current session,
    /// so when the sole session needing attention is the selected one, `navigateSession` selects nothing.
    /// Without the fallback the reveal degrades to plain `focusActiveSession` and ⌃⌥↑/↓ stops landing on that
    /// session's tagged pane — constant for an agent, since a pane-scoped block is not cleared by typing in
    /// the OTHER pane. Keep it.
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

    /// Delete a workspace and all its sessions from `store`'s window. Confirms while it still has sessions
    /// (the delete ends their shells), no prompt when empty, no-op when only one workspace remains — one is
    /// always kept. The row's "Delete Workspace" passes its OWN window-local store: the frontmost one would
    /// find no such id and silently do nothing. Ungated like the other store-scoped row actions — a window
    /// renders no sidebar while its zoom or dashboard is up, so the row menu is unreachable in exactly the
    /// state the gate covers, and a frontmost modal must not block a background window's row.
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

    /// Delete the current workspace (where new sessions land) — the menu-bar/palette path, which has no
    /// clicked row and so acts on the frontmost window.
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

    /// Expand every workspace in the frontmost window's sidebar. No-op when no window is open.
    func expandAllWorkspaces() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        expandAllWorkspaces(in: store)
    }

    /// Expand every workspace in `store`'s window sidebar. The sidebar owns the outline, so this posts a
    /// store-scoped notification and only that window's `WorkspaceSidebar.Coordinator` acts — how
    /// `sidebar.expand` targets a specific (default frontmost) window. No-op in flagged mode (no rows).
    func expandAllWorkspaces(in store: AppStore) {
        NotificationCenter.default.post(name: .agtermExpandWorkspaces, object: store)
    }

    /// Collapse every workspace except the active one in the frontmost window's sidebar. No-op with no window.
    func collapseOtherWorkspaces() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        collapseOtherWorkspaces(in: store)
    }

    /// Collapse every workspace except the current one in `store`'s window sidebar, keeping that one
    /// expanded and scrolled into view. Store-scoped like `expandAllWorkspaces(in:)`, no-op in flagged mode,
    /// and how `sidebar.collapse` targets a specific (default frontmost) window.
    func collapseOtherWorkspaces(in store: AppStore) {
        NotificationCenter.default.post(name: .agtermCollapseWorkspaces, object: store)
    }

    /// Fold or unfold the CURRENT workspace alone, for the keyless `toggle_workspace_collapse`, its View-menu
    /// item and its palette row. The per-workspace counterpart of Expand / Collapse Workspaces, which act on
    /// every row and deliberately keep this one open — so before this there was no built-in way to fold the
    /// workspace you are in. Tree mode only, matching those two and the rows it acts on. Targets what the row
    /// SHOWS (`isCurrentWorkspaceCollapsed`), not what is persisted: a reveal routinely leaves this workspace
    /// open on screen while its stored flag still says collapsed, and toggling the stored flag there costs the
    /// user a keystroke that changes nothing he can see.
    func toggleActiveWorkspaceCollapse() {
        guard uiActionsEnabled else { return }
        guard let store, store.sidebarMode == .tree, let id = store.currentWorkspaceID else { return }
        setWorkspaceExpanded(id, expanded: store.isCurrentWorkspaceCollapsed, in: store)
    }

    /// Collapse/expand a SINGLE workspace in `store`'s window sidebar — the shared path for
    /// `workspace.collapse`/`.expand` and for `toggleActiveWorkspaceCollapse` above (a GUI row click drives
    /// the outline directly instead). Persists
    /// `Workspace.isExpanded` DIRECTLY on the store (source of truth for the `collapsed` read-back,
    /// delta-guarded so it's idempotent), THEN posts a store-scoped notification so that window's Coordinator
    /// syncs the live outline row and its tracked expansion set. The persist must NOT ride the notification:
    /// the Coordinator is mounted only while `sidebarVisible`, so with the sidebar hidden a notification-only
    /// write drops silently and leaves the read-back stale. Mirrors `workspace.focus`/`session.resize`.
    func setWorkspaceExpanded(_ id: UUID, expanded: Bool, in store: AppStore) {
        store.setWorkspaceExpanded(id, expanded: expanded)
        NotificationCenter.default.post(
            name: .agtermSetWorkspaceExpanded, object: store,
            userInfo: [WorkspaceSidebar.Coordinator.workspaceIDUserInfoKey: id,
                       WorkspaceSidebar.Coordinator.expandedUserInfoKey: expanded])
    }

    // MARK: - Flagged working-set

    /// Toggle a session's flagged membership (the durable working-set the flat sidebar view projects), from
    /// the row's "Flag"/"Unflag" item; clean no-op on an unknown id.
    func toggleFlag(_ sessionID: UUID) {
        guard uiActionsEnabled else { return }
        guard let store, let session = store.session(withID: sessionID) else { return }
        store.setFlag(!session.flagged, forSession: sessionID)
    }

    /// Toggle the active session's flag, for the menu bar and palette (no clicked row). No-op with none selected.
    func toggleFlagActiveSession() {
        guard let id = store?.selectedSessionID else { return }
        toggleFlag(id)
    }

    /// Flip the sidebar between the workspace tree and the flat flagged working-set list. Shared by the
    /// bottom-bar toggle, the View menu, the palette and `sidebar.mode`; `ContentView` animates the switch.
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

    /// A warning confirm for clearing the flagged working-set (`count` sessions). Returns whether confirmed.
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

    /// Create a fresh window (one default workspace + session) and open it via the scene's window opener,
    /// the seam the control channel uses. No-op before the scene `.task` wires the opener.
    ///
    /// `ignoringModals` skips the frontmost-window modal gate. Creating a window touches no existing
    /// window's state, so the Dock item passes true — a dashboard or zoom in whatever window happened to be
    /// last active must not make it inert. Menu bar and palette keep the gate (`.disabled(modalActive)`).
    func newWindow(ignoringModals: Bool = false) {
        guard ignoringModals || uiActionsEnabled else { return }
        // `library.newWindow()` persists an open entry, so with no opener the app counts a window that has
        // no NSWindow behind it.
        guard let openWindow else { return }
        let info = library.newWindow()
        openWindow(info.id)
    }

    /// Surface a window: raise it if already open, else open it. Used by File ▸ Open Window and the palette.
    func openWindow(_ id: WindowInfo.ID) {
        guard uiActionsEnabled else { return }
        openWindow?(id)
    }

    /// Rename the frontmost window via an `NSAlert` with a pre-filled accessory field — inline rename is
    /// sidebar-row-only and a window has no row. Flows through `library.renameWindow`, the control seam.
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

    /// Delete the frontmost window and its sessions: confirms while it still has sessions (the delete ends
    /// their shells), no-op when only one window remains. Closes the on-screen window first so teardown runs.
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
    /// the edit starts. The post is store-scoped so only that window edits: a nil object reaches EVERY open
    /// window's coordinator (their `selectedSessionID` guard scopes nothing, every window has a selection),
    /// each opening an unused editor and leaking one unbalanced `suppressAutoFollow`.
    func renameActiveSession() {
        guard uiActionsEnabled else { return }
        guard let store, store.activeSession != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtermBeginRenameSession, object: store)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    /// Inline-rename the current workspace (where new sessions land). Store-scoped like the session rename.
    func renameActiveWorkspace() {
        guard uiActionsEnabled else { return }
        guard let store, store.currentWorkspaceID != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtermBeginRenameWorkspace, object: store)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    // MARK: - Split

    /// Toggle the active session's vertical split. A NEW split shows both panes and focuses the new one;
    /// closing only HIDES it (both shells stay alive) and maximizes the focused pane, so reopening restores
    /// both in their original positions with the SAME pane focused — focus follows `splitFocused`, which
    /// `AppStore.toggleSplit` moves only for a genuinely new split.
    ///
    /// A session-wide cover hides the panes, so rearranging them behind it would only be seen once the cover
    /// goes — the layout the user left is silently different. A shown scratch is DISMISSED instead, ⌘W's
    /// cover-first rule, making this the way back to the panes as they were; hiding is keep-alive, so the
    /// scratch shell survives. A full overlay runs a caller's program that must not be closed under it, so
    /// the press is inert. Control's `session.split` keeps acting on the deck behind either cover.
    func toggleSplit() {
        toggleSplit(axis: .leftRight)
    }

    /// Toggle the active session's horizontal split, or transpose a shown vertical split in place.
    func toggleHorizontalSplit() {
        toggleSplit(axis: .topBottom)
    }

    /// Preserve the current axis. Used by the titlebar's stateful split button rather than either
    /// orientation-specific menu/keymap action.
    func toggleCurrentSplit() {
        toggleSplit(axis: nil)
    }

    private func toggleSplit(axis: SplitAxis?) {
        guard uiActionsEnabled else { return }
        guard let store, let session = store.activeSession else { return }
        guard !session.fullOverlayActive else { return }
        // the deck's `scratchActive` onChange reclaims first responder for the pane, as it does for ⌘J.
        if session.scratchActive { store.toggleScratch(session.id); return }
        store.toggleSplit(session.id, axis: axis)
        focusSplitPane(session, wantSplit: session.splitFocused)
    }

    /// The palette's Close Split, GUI twin of `session.split.close`. Gated on `hasSplit`, so the hidden
    /// split ⌘D leaves behind is reachable. Immediate and unconfirmed like the other pane teardowns; the
    /// confirm and undo window stay with `closeActiveSession`. Carries `toggleSplit`'s cover rungs, which
    /// matter more here: behind a cover this destroys a live shell instead of rearranging panes, so the
    /// dismissed scratch makes the teardown a second, deliberate press with the panes in view.
    func closeSplit() {
        guard uiActionsEnabled else { return }
        guard let store, let session = store.activeSession else { return }
        guard session.hasSplit, !session.fullOverlayActive else { return }
        if session.scratchActive { store.toggleScratch(session.id); return }
        store.closeSplit(session.id)
        focusSplitPane(session, wantSplit: false)
    }

    /// Show/hide the active session's scratch terminal, a third full-overlay login shell. Focus rides the
    /// surface's `autoFocus` and the detail pane's hide reclaim, so this only flips the flag; control drives
    /// `AppStore.toggleScratch` directly.
    func toggleScratch() {
        guard uiActionsEnabled else { return }
        guard let store, let session = store.activeSession else { return }
        store.toggleScratch(session.id)
    }

    /// Show/hide the frontmost window's sidebar. The custom split owns visibility (no system toggle), so this
    /// flips the store's per-window `sidebarVisible`, persisted by `AppStore`; the width is intentionally not
    /// animated (see WindowContentView.splitRoot). Shared by toolbar, View menu, palette and `sidebar`.
    func toggleSidebar() {
        guard uiActionsEnabled else { return }
        guard let store else { return }
        store.toggleSidebarVisible()
    }

    /// Focus a pane of the active session's split: `.split` -> right, anything else -> left/primary; no-op with no split.
    func focusPane(_ pane: PaneRole) {
        guard uiActionsEnabled else { return }
        guard let session = store?.activeSession else { return }
        setSplitFocus(pane == .split, of: session)
    }

    /// Set which pane of a session's split holds focus and move first responder there. Shared by `focusPane`
    /// and the control channel (which may target a non-active session). Updates `splitFocused`, so pane dim,
    /// sidebar and title bar follow and a hidden split swaps which pane shows maximized. No-op with no split.
    func setSplitFocus(_ toSplit: Bool, of session: Session) {
        guard session.hasSplit else { return }
        session.splitFocused = toSplit
        focusSplitPane(session, wantSplit: toSplit)
    }

    // MARK: - Quick terminal (frontmost window)

    /// Toggle the frontmost window's quick terminal. Gated on the full `uiActionsEnabled` (zoom, dashboard
    /// AND native picker), not zoom alone — defence in depth, since all three callers already gate: View ▸
    /// Quick Terminal's `.disabled(modalActive)` (which also covers a `keymap.conf` rebind, that being the
    /// item's own key equivalent), the palette's `runPaletteCommand`, and the Dock item's invocation check.
    func toggleQuickTerminal() {
        guard uiActionsEnabled else { return }
        quickTerminal.toggle()
    }

    /// Toggle terminal zoom for whatever the user is actually looking at: the quick-terminal panel when it
    /// owns the keyboard, else the frontmost window's active surface (core resolves overlay, scratch, split
    /// or primary; the owning window renders it above all chrome).
    ///
    /// The panel rung is not optional. The chord still reaches agterm while the panel is key, but the panel
    /// is no longer a `TerminalZoomTarget` a window can hold — so without it the keystroke would arm zoom on
    /// a window BEHIND the panel, changing nothing on screen and leaving a window the user may not even have
    /// visible zoomed with its sidebar gone. Same rule as `closeActiveSession`: never mutate covered state.
    func toggleTerminalZoom() {
        guard !pickActive(for: library.activeWindowID) else { return }
        if quickTerminal.holdsKey {
            quickTerminal.setZoom(.toggle)
            return
        }
        frontmostTerminalZoom?.toggle()
    }

    /// Toggle the frontmost window's dashboard, the ⌘⇧G / Navigate ▸ Dashboard MRU grid, equivalent to
    /// `agtermctl dashboard --mru --auto-size`. Inert while terminal zoom or a pending picker is up, but NOT
    /// while the dashboard itself is open, so the grid stays its own escape hatch. Open → close and refocus;
    /// closed → open over the window's most-recently-used sessions, auto-sized; no-op with none.
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
        // later), through the same DashboardFontMode seam as the control arm so both land on one auto size.
        let base = settingsModel?.settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
        dashboard.setAppliedFontSize(DashboardFontMode.auto.appliedFontSize(memberCount: members.count, base: base))
    }

    /// Toggle native macOS full screen for the key window: the green traffic-light behavior, moving the window
    /// to its own Space; a second invocation exits. The palette's entry alone — `toggle_fullscreen`'s chord
    /// calls `NSWindow.toggleFullScreen` from the key monitor and `window.fullscreen` through
    /// `WindowRegistry`, so neither routes here.
    func toggleFullscreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    // MARK: - Font (on the focused terminal)

    // NOT zoom-gated: font commands act on the FOCUSED surface — while zoomed that is the zoomed terminal —
    // and never touch hidden deck state, so ⌘+/⌘−/⌘0 keep working.
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

    /// The search-capable target. A covering SCRATCH wins FIRST, so ⌘F over a scratch never opens the bar on
    /// the hidden pane beneath — even with key-window focus off the surface (e.g. the sidebar), where
    /// `focusedSurface()` would fall back to the hidden `activeSurface`. Else the focused surface IFF
    /// searchable, else the active session's focused pane. Full overlay and quick terminal are unsearchable
    /// (blocked by `coverHidesActiveSession`); a FLOATING overlay leaves the pane visible, so it targets it.
    private func searchTarget() -> GhosttySurfaceView? {
        if let session = store?.activeSession, session.scratchActive, !session.programOverlayActive {
            return session.topmostSurface as? GhosttySurfaceView
        }
        // the focused pane hidden under its OWN overlay has no searchable target: the overlay is unsearchable
        // and returning the pane would strand the bar over it. The sibling pane keeps its own ⌘F once focused.
        // AFTER the scratch rung on purpose: the scratch covers the pane overlays too, and it IS searchable.
        if store?.activeSession?.focusedOverlayPane != nil { return nil }
        if let view = focusedSurface(), view.isSearchable { return view }
        return store?.activeSession?.activeSurface as? GhosttySurfaceView
    }

    /// Whether a SESSION-WIDE cover BLOCKS ⌘F — the frontmost quick terminal or the active session's FULL
    /// overlay, neither searchable, so the bar would strand over a hidden pane. The scratch IS searchable, so
    /// it never blocks and ⌘F opens the bar over it; the ⌘F-again CLOSE runs regardless. A covering PANE
    /// overlay is NOT a term here — `searchTarget` owns that rung, in the one order that gets the
    /// scratch-above-a-pane-overlay case right; duplicating it here would block ⌘F on the searchable scratch.
    private var coverHidesActiveSession: Bool {
        if quickTerminal.holdsKey { return true }
        guard let session = store?.activeSession else { return false }
        // a FLOATING overlay leaves the session visible, so only a FULL overlay hides it (and is not searchable).
        return session.fullOverlayActive
    }

    /// Toggle the search bar for the active session; shared by the Find menu item, the palette, and ⌘F.
    /// CLOSE: `end_search` DIRECTLY to the pinned `searchSurface` (the surface that opened search) so the END
    /// callback clears the fields and refocuses — never a re-resolved target or a `start_search` round-trip,
    /// which on a split with focus moved to the OTHER pane puts that pane into search mode while
    /// `onSearchStart` closes only the pinned owner, stranding it. OPEN: no-op with no searchable surface or
    /// behind a cover, else `start_search` on the search target, whose `onSearchStart` opens and pins the bar.
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

    /// Set the current query: mirror it into `searchNeedle` (keeping the bar's field in sync), then send
    /// `search:<needle>` to the pinned `searchSurface`, which replies with the match count — the pinned owner
    /// rather than a re-resolved focused surface keeps the bar on the pane that opened search after a split
    /// focus move. An empty needle clears count/selected eagerly, so the counter blanks at once instead of
    /// flashing a stale "N of M" through libghostty's async teardown.
    func updateSearchNeedle(_ needle: String) {
        guard let session = store?.activeSession else { return }
        session.searchNeedle = needle
        if needle.isEmpty {
            session.searchTotal = nil
            session.searchSelected = nil
        }
        (session.searchSurface as? GhosttySurfaceView)?.sendSearchQuery(needle)
    }

    /// Step to the next/previous match (the bar's up/down, Enter/Shift-Enter) on the pinned `searchSurface`.
    func navigateSearch(_ direction: GhosttySurfaceView.SearchDirection) {
        (store?.activeSession?.searchSurface as? GhosttySurfaceView)?.navigateSearch(direction)
    }

    /// Close search: `end_search` to the pinned `searchSurface` so it really exits search mode, never just
    /// flips the flag. END_SEARCH is the single clear point (fields, pinned owner, first responder back).
    func endSearch() {
        (store?.activeSession?.searchSurface as? GhosttySurfaceView)?.endSearch()
    }

    // MARK: - Focus

    /// Per-window focus generation counters (bumped in AppActions+Focus). A fresh `focusSplitPane` bumps its
    /// window's counter so a superseded in-flight retry loop in the SAME window cancels itself, killing the
    /// opposite-target ping-pong flicker — last-focus-wins per window. Keyed by window (one NSWindow = one
    /// first responder) so one window's focus op never cancels another's still-materializing retry.
    var focusGeneration: [UUID: Int] = [:]

    /// The focused terminal: the key window's first responder if a surface (main, split or quick terminal),
    /// else the active session's focused pane.
    private func focusedSurface() -> GhosttySurfaceView? {
        if let view = NSApp.keyWindow?.firstResponder as? GhosttySurfaceView { return view }
        return store?.activeSession?.activeSurface as? GhosttySurfaceView
    }
}
