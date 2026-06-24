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
    private let library: WindowLibrary

    /// The store of the frontmost open window — the target of every mutating action. Nil only in
    /// the degenerate all-windows-closed state (quitting), in which case the callers no-op.
    private var store: AppStore? { library.activeStore }

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
              let session = store.addSession(toWorkspace: workspaceID,
                                             cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        else { return }
        store.selectSession(session.id)
        focusActiveSession()
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

    func closeActiveSession() {
        guard let store, let id = store.selectedSessionID else { return }
        store.closeSession(id)
        focusActiveSession()
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
        if store.openOverlay(id, command: ConfigPaths.editorCommand(forKeymapPath: path), sizePercent: 95) {
            keymapEditOverlaySession = id
        }
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

    // MARK: - Command palettes

    /// The palette shortcut hint for a rebindable built-in: its currently-bound chord rendered as macOS
    /// menu glyphs (so it tracks rebinds and reads like the menu equivalent), or `nil` when the action
    /// has no chord. The arrow-bound actions fall back to their hardcoded arrow glyph when no override is
    /// set — `defaultChord` is nil for them (arrows can't round-trip through `parseKeybind`), mirroring
    /// `agtermApp.arrowShortcut(for:)`.
    private func paletteHint(for action: BuiltinAction) -> String? {
        if let chord = settingsModel?.keymap.equivalent(for: action) {
            // macOS glyphs (⌘N, ⌃P) so a built-in reads like its menu item, NOT the raw kitty
            // `displayString` (custom commands keep that).
            return chord.glyphString
        }
        switch action {
        case .focusLeftPane: return "⌥⌘←"
        case .focusRightPane: return "⌥⌘→"
        case .previousSession: return "⌥⌘↑"
        case .nextSession: return "⌥⌘↓"
        case .previousAttentionSession: return "⌃⌥↑"
        case .nextAttentionSession: return "⌃⌥↓"
        default: return nil
        }
    }

    /// The app's commands as palette items, sharing the same logic as the menu/buttons. Includes a
    /// "Move Session to …" item per other workspace (when there's an active session to move).
    func paletteActions() -> [PaletteItem] {
        // built-in shortcut hints read the live keymap (`paletteHint`) so a rebind updates them too,
        // matching the data-driven menu key-equivalents; custom commands show their raw shortcut below.
        var items: [PaletteItem] = [
            PaletteItem(title: "New Session", shortcut: paletteHint(for: .newSession)) { [weak self] in self?.newSession() },
            PaletteItem(title: "New Workspace", shortcut: paletteHint(for: .newWorkspace)) { [weak self] in self?.newWorkspace() },
            PaletteItem(title: "Open Directory…", shortcut: paletteHint(for: .openDirectory)) { [weak self] in self?.openDirectory() },
            PaletteItem(title: "Rename Session", shortcut: paletteHint(for: .renameSession)) { [weak self] in self?.renameActiveSession() },
            PaletteItem(title: "Rename Workspace", shortcut: paletteHint(for: .renameWorkspace)) { [weak self] in self?.renameActiveWorkspace() },
            PaletteItem(title: "Close Session", shortcut: paletteHint(for: .closeSession)) { [weak self] in self?.closeActiveSession() },
            PaletteItem(title: "Clear Status", shortcut: paletteHint(for: .clearStatus)) { [weak self] in self?.clearActiveSessionStatus() },
            PaletteItem(title: "Previous Session", shortcut: paletteHint(for: .previousSession)) { [weak self] in self?.selectPreviousSession() },
            PaletteItem(title: "Next Session", shortcut: paletteHint(for: .nextSession)) { [weak self] in self?.selectNextSession() },
            PaletteItem(title: "Previous Attention Session", shortcut: paletteHint(for: .previousAttentionSession)) { [weak self] in self?.selectPreviousAttentionSession() },
            PaletteItem(title: "Next Attention Session", shortcut: paletteHint(for: .nextAttentionSession)) { [weak self] in self?.selectNextAttentionSession() },
            PaletteItem(title: "First Session", shortcut: paletteHint(for: .firstSession)) { [weak self] in self?.selectFirstSession() },
            PaletteItem(title: "Last Session", shortcut: paletteHint(for: .lastSession)) { [weak self] in self?.selectLastSession() },
            PaletteItem(title: "Toggle Split", shortcut: paletteHint(for: .toggleSplit)) { [weak self] in self?.toggleSplit() },
            PaletteItem(title: "Toggle Scratch", shortcut: paletteHint(for: .toggleScratch)) { [weak self] in self?.toggleScratch() },
            PaletteItem(title: "Quick Terminal", shortcut: paletteHint(for: .quickTerminal)) { [weak self] in self?.toggleQuickTerminal() },
            PaletteItem(title: "Increase Font Size", shortcut: paletteHint(for: .increaseFontSize)) { [weak self] in self?.increaseFontSize() },
            PaletteItem(title: "Decrease Font Size", shortcut: paletteHint(for: .decreaseFontSize)) { [weak self] in self?.decreaseFontSize() },
            PaletteItem(title: "Actual Font Size", shortcut: paletteHint(for: .resetFontSize)) { [weak self] in self?.resetFontSize() },
            PaletteItem(title: "Edit Keymap") { [weak self] in self?.editKeymap() },
            PaletteItem(title: "Reload Keymap") { [weak self] in self?.reloadKeymap() },
        ]
        if store?.canRemoveWorkspace == true {
            items.append(PaletteItem(title: "Delete Workspace", shortcut: paletteHint(for: .deleteWorkspace)) { [weak self] in self?.deleteActiveWorkspace() })
        }
        if store?.activeSession?.isSplit == true {
            items.append(PaletteItem(title: "Focus Left Pane", shortcut: paletteHint(for: .focusLeftPane)) { [weak self] in self?.focusPane(.main) })
            items.append(PaletteItem(title: "Focus Right Pane", shortcut: paletteHint(for: .focusRightPane)) { [weak self] in self?.focusPane(.split) })
        }
        items.append(PaletteItem(title: "New Window", shortcut: paletteHint(for: .newWindow)) { [weak self] in self?.newWindow() })
        items.append(PaletteItem(title: "Rename Window", shortcut: paletteHint(for: .renameWindow)) { [weak self] in self?.renameActiveWindow() })
        if library.canRemoveWindow {
            items.append(PaletteItem(title: "Delete Window", shortcut: paletteHint(for: .deleteWindow)) { [weak self] in self?.deleteActiveWindow() })
        }
        // one "Open Window: <name>" per closed window — open ones are already on screen.
        for window in library.windows where !library.isOpen(window.id) {
            let target = window.id
            items.append(PaletteItem(id: "open-window-\(target)", title: "Open Window: \(window.name)") { [weak self] in
                self?.openWindow(target)
            })
        }
        if let store, let current = store.currentWorkspaceID, let sessionID = store.selectedSessionID {
            for workspace in store.workspaces where workspace.id != current {
                let target = workspace.id
                items.append(PaletteItem(id: "move-\(target)", title: "Move Session to \(workspace.name)") { [weak self] in
                    self?.moveSession(sessionID, toWorkspace: target)
                })
            }
        }
        // user-defined keymap commands: marked `custom`, showing the bound chord (if any). Running one
        // delegates to the runner, which resolves the active session's context and spawns the shell line.
        for command in settingsModel?.keymap.commands ?? [] {
            items.append(PaletteItem(id: "custom-\(command.id)", title: command.name,
                                     shortcut: command.shortcut.isEmpty ? nil : command.shortcut,
                                     badge: "custom") { [weak self] in
                self?.customCommandRunner?.run(command)
            })
        }
        return items
    }

    /// Every open session across workspaces as palette items; choosing one selects it. The
    /// subtitle leads with the owning workspace (so you can tell sessions of the same name apart,
    /// and search by workspace) followed by the working directory.
    func paletteSessions() -> [PaletteItem] {
        guard let store else { return [] }
        return store.workspaces.flatMap { workspace in
            workspace.sessions.map { session in
                let id = session.id
                let subtitle = "\(workspace.name) · \(session.effectiveCwd)"
                return PaletteItem(id: id.uuidString, title: session.displayName, subtitle: subtitle) {
                    store.selectSession(id)
                }
            }
        }
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

    /// Move keyboard focus to a pane of the active session's split: `.split` -> the right pane,
    /// anything else -> the left/primary. No-op when the active session isn't split. Drives the
    /// keyboard shortcuts, the View menu items, and the action palette.
    func focusPane(_ pane: PaneRole) {
        guard let session = store?.activeSession else { return }
        setSplitFocus(pane == .split, of: session)
    }

    /// Set which pane of a session's split holds focus and move first responder there. Shared by the
    /// GUI `focusPane` and the control channel (which may target a session that isn't the active one).
    /// Updates `splitFocused` so the pane dim, sidebar, and title bar follow. No-op when not split.
    func setSplitFocus(_ toSplit: Bool, of session: Session) {
        guard session.isSplit else { return }
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

    // MARK: - Focus

    /// Move first responder back to the active session's topmost surface (used after the quick terminal
    /// or a palette/rename field closes). Targets `topmostSurface` (overlay > scratch > active pane) so a
    /// palette close re-focuses whatever is actually visible — the scratch or overlay if one is up, else
    /// the focused pane — never a pane hidden under a cover. Re-asserts briefly since the target view may
    /// not be on-window yet. Bails only for the quick terminal: it is a window-level cover that owns focus
    /// and re-focuses the session on its own hide, so don't fight it here.
    func focusActiveSession(attempt: Int = 0) {
        if renamePending { return }
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
        let wantSplit = pane == .split && session.isSplit
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
