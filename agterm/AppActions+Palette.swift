import agtermCore
import Foundation

/// Command palettes (action / session / attention / custom-command feeds) and the live-preview
/// theme picker for `AppActions`. The theme-preview session state (`themePreviewActive` /
/// `themePreviewOriginal`) lives on the main `AppActions` declaration — stored properties cannot
/// live in an extension — while the preview/commit/cancel logic that drives it lives here.
extension AppActions {
    // MARK: - Command palettes

    /// The macOS glyph string for a rebindable built-in's CURRENT shortcut (`⌘N`, `⌃⌘S`) — tracking
    /// rebinds, reading like the menu equivalent — or `nil` when the action has no shortcut. The SINGLE
    /// resolver behind both the action-palette hints and the toolbar/sidebar tooltips, so the two
    /// surfaces can't drift. `glyphHint` resolves the live keymap (override else shipped default, with
    /// the arrow-bound actions falling back to their hardcoded arrow glyph since arrows can't round-trip
    /// through `parseKeybind`); before `settingsModel` is wired, fall back to the arrow glyph alone.
    func shortcutGlyph(for action: BuiltinAction) -> String? {
        guard let keymap = settingsModel?.keymap else { return action.arrowGlyphFallback }
        return keymap.glyphHint(for: action)
    }

    private var paletteContext: PaletteContext {
        let activeStore = store
        return PaletteContext(
            canRemoveWorkspace: activeStore?.canRemoveWorkspace == true,
            hasFlaggedSessions: activeStore?.flaggedSessions.isEmpty == false,
            sidebarShowsWorkspaceTree: activeStore?.sidebarMode == .tree,
            sidebarShowsFlaggedOnly: activeStore?.sidebarMode == .flagged,
            activeSessionFlagged: activeStore?.activeSession?.flagged == true,
            hasFocusedWorkspace: activeStore?.focusedWorkspaceID != nil,
            activeSessionHasSplit: activeStore?.activeSession?.hasSplit == true,
            hasPendingClose: activeStore?.pendingCloseSummary != nil,
            hasRecentClosed: !library.recentClosedItems.isEmpty
        )
    }

    private func paletteItem(for command: PaletteCommand, context: PaletteContext) -> PaletteItem {
        PaletteItem(title: command.title(in: context),
                    shortcut: command.builtinAction.flatMap { shortcutGlyph(for: $0) }) { [weak self] in
            self?.runPaletteCommand(command)
        }
    }

    private func runPaletteCommand(_ command: PaletteCommand) {
        guard uiActionsEnabled || command == .toggleTerminalZoom else { return }
        switch command {
        case .newSession: newSession()
        case .newWorkspace: newWorkspace()
        case .openDirectory: openDirectory()
        case .renameSession: renameActiveSession()
        case .duplicateSession: duplicateActiveSession()
        case .renameWorkspace: renameActiveWorkspace()
        case .closeSession: closeActiveSession()
        case .reopenRecent: openLatestRecentClosed()
        case .undoClose: undoClose()
        case .clearStatus: clearActiveSessionStatus()
        case .previousSession: selectPreviousSession()
        case .nextSession: selectNextSession()
        case .previousAttentionSession: selectPreviousAttentionSession()
        case .nextAttentionSession: selectNextAttentionSession()
        case .firstSession: selectFirstSession()
        case .lastSession: selectLastSession()
        case .showAttention: openAttentionPalette()
        case .toggleSplit: toggleSplit()
        case .toggleScratch: toggleScratch()
        case .toggleTerminalZoom: toggleTerminalZoom()
        case .toggleSidebar: toggleSidebar()
        case .toggleFlag: toggleFlagActiveSession()
        case .focusWorkspace: focusActiveWorkspace()
        case .find: toggleSearch()
        case .quickTerminal: toggleQuickTerminal()
        case .dashboard: toggleDashboard()
        case .toggleFullscreen: toggleFullscreen()
        case .increaseFontSize: increaseFontSize()
        case .decreaseFontSize: decreaseFontSize()
        case .resetFontSize: resetFontSize()
        case .selectTheme: openThemePalette()
        case .editKeymap: editKeymap()
        case .reloadKeymap: reloadKeymap()
        case .editGhosttyConfig: editGhosttyConfig()
        case .reloadConfig: reloadGhosttyConfig()
        case .deleteWorkspace: deleteActiveWorkspace()
        case .toggleFlaggedView: toggleFlaggedView()
        case .clearFlagged: clearFlags()
        case .clearFocus: clearFocus()
        case .expandWorkspaces: expandAllWorkspaces()
        case .collapseWorkspaces: collapseOtherWorkspaces()
        case .focusLeftPane: focusPane(.main)
        case .focusRightPane: focusPane(.split)
        }
    }

    /// The app's commands as palette items, sharing the same logic as the menu/buttons. Includes a
    /// "Move Session to …" item per other workspace (when there's an active session to move).
    func paletteActions() -> [PaletteItem] {
        // built-in shortcut hints read the live keymap (`shortcutGlyph`) so a rebind updates them too,
        // matching the data-driven menu key-equivalents; custom commands show their raw shortcut below.
        let context = paletteContext
        var items = PaletteCommand.allCases
            .filter { $0.isVisible(in: context) }
            .map { paletteItem(for: $0, context: context) }
        items.append(PaletteItem(title: "New Window", shortcut: shortcutGlyph(for: .newWindow)) { [weak self] in self?.newWindow() })
        items.append(PaletteItem(title: "Rename Window", shortcut: shortcutGlyph(for: .renameWindow)) { [weak self] in self?.renameActiveWindow() })
        if library.canRemoveWindow {
            items.append(PaletteItem(title: "Delete Window", shortcut: shortcutGlyph(for: .deleteWindow)) { [weak self] in self?.deleteActiveWindow() })
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
        // user-defined keymap commands: marked `custom`, showing the bound chord (if any).
        items.append(contentsOf: customCommandItems(badge: "custom"))
        return items
    }

    /// The user-defined keymap commands as palette items, showing the bound chord (if any). Running one
    /// delegates to the runner, which resolves the active session's context and spawns the shell line.
    /// `badge` tags each entry (`custom` in the mixed action palette); the custom-only palette passes nil
    /// since every row there is already a custom command.
    private func customCommandItems(badge: String?) -> [PaletteItem] {
        (settingsModel?.keymap.commands ?? []).map { command in
            PaletteItem(id: "custom-\(command.id)", title: command.name,
                        shortcut: command.shortcut.isEmpty ? nil : command.shortcut,
                        badge: badge) { [weak self] in
                guard self?.uiActionsEnabled == true else { return }
                self?.customCommandRunner?.run(command)
            }
        }
    }

    /// Only the user-defined keymap commands, for the `.customCommands` palette. Same rows as the
    /// `custom` subset of `paletteActions()` but WITHOUT the `custom` badge — the whole list is custom.
    func paletteCustomCommands() -> [PaletteItem] {
        customCommandItems(badge: nil)
    }

    /// The VISIBLE/FILTERED sessions as palette items (the ⌃P switcher); choosing one selects it. Scoped
    /// to `navigableSessions` — the focused workspace's sessions when a workspace is focused, the flagged
    /// set in flagged mode, else all — so the ⌃P list matches the sidebar (and the Ctrl-Tab MRU switcher
    /// and `session.go` nav, which already filter the same way). The subtitle leads with the owning
    /// workspace (so you can tell sessions of the same name apart, and search by workspace) followed by
    /// `subtitleDetail` (the focused pane's terminal title for a remote session, else its cwd).
    func paletteSessions() -> [PaletteItem] {
        guard let store else { return [] }
        return store.navigableSessions.map { paletteItem(for: $0, in: store) }
    }

    /// The window's non-idle sessions as palette items (the `.attention` mode), each row carrying the
    /// session's agent-status glyph. Sourced from `store.attentionSessions` (blocked→active→completed,
    /// newest status-change first) so the empty-query order matches that ranking; choosing one selects
    /// it. Same subtitle shape as `paletteSessions()` (owning workspace · `subtitleDetail`).
    func paletteAttention() -> [PaletteItem] {
        guard let store else { return [] }
        return store.attentionSessions.map {
            paletteItem(for: $0, in: store, status: $0.agentIndicator.status, statusColor: $0.agentIndicator.color)
        }
    }

    /// Maps one session to a palette row — title=`displayName`, subtitle="`workspace` · `subtitleDetail`",
    /// `run` selects it. Shared by `paletteSessions()` (status nil) and `paletteAttention()` (status set so
    /// `CommandPalette.row` renders the leading `StatusGlyph`, tinted by the session's per-call `statusColor`).
    private func paletteItem(for session: Session, in store: AppStore,
                             status: AgentStatus? = nil, statusColor: String? = nil) -> PaletteItem {
        let id = session.id
        let workspaceName = store.workspace(forSession: id)?.name ?? ""
        let subtitle = "\(workspaceName) · \(session.subtitleDetail)"
        return PaletteItem(id: id.uuidString, title: session.displayName, subtitle: subtitle,
                           status: status, statusColor: statusColor) { [weak self] in
            guard self?.uiActionsEnabled == true else { return }
            // picking a session from the ⌃P / attention palette is a user-initiated selection: note activity
            // so it buys the full idle grace before auto-follow can pull the selection back.
            store.noteUserActivity()
            store.selectSession(id)
            // reveal the picked session's blocked pane (a no-op unless it carries a pane-tagged block),
            // async so it runs AFTER the palette closes and its focus-restore, winning the focus race.
            DispatchQueue.main.async { self?.revealActiveBlockedPane() }
        }
    }

    /// Toggle the `.attention` command palette (the window's non-idle sessions). Driven by the ⌃⇧I
    /// `BuiltinAction.showAttention`, the Navigate ▸ Go to Attention… menu item, and the titlebar bell
    /// icon — none of these route through the action palette's `runItem`, so a synchronous toggle is
    /// correct. The ⌃⇧P launcher uses `openAttentionPalette()` instead (it must reopen async).
    func toggleAttentionPalette() {
        guard !terminalZoomActive else { return }
        palette?.toggle(.attention)
    }

    /// Menu/keymap palette launchers route through actions, not direct `palette.toggle`, so terminal zoom's
    /// modal UI guard is applied consistently to the keyboard shortcut and menu paths.
    func toggleSessionPalette() {
        guard !terminalZoomActive else { return }
        palette?.toggle(.sessions)
    }

    func toggleActionPalette() {
        guard !terminalZoomActive else { return }
        palette?.toggle(.actions)
    }

    func toggleCustomCommandPalette() {
        guard !terminalZoomActive else { return }
        palette?.toggle(.customCommands)
    }

    /// Open the `.attention` command palette from the action-palette "Show Attention" launcher. Opened on
    /// the next runloop tick (mirroring `openThemePalette()`): the launcher runs inside the open action
    /// palette's `runItem`, which calls `controller.close()` right after this returns, so a synchronous
    /// `toggle` would be undone by that close. The async `open` lets `.attention` reopen a tick later as a
    /// fresh view that survives the close.
    func openAttentionPalette() {
        guard !terminalZoomActive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminalZoomActive else { return }
            self.palette?.open(.attention)
        }
    }

    // MARK: - Theme picker

    /// Open the `.themes` command palette (the live-preview theme picker). Invoked by the action-palette
    /// "Select Theme…" launcher and the View ▸ Select Theme… menu item. Opened on the next runloop tick:
    /// when launched from the open action palette, that palette's run handler closes itself right after
    /// this returns, so reopening async lets `.themes` survive the close (the rename actions reopen the
    /// same way).
    func openThemePalette() {
        guard !terminalZoomActive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminalZoomActive else { return }
            self.palette?.open(.themes)
        }
    }

    /// Theme rows for the `.themes` palette: a leading "Default" entry plus one per bundled theme,
    /// the current one badged. Navigating a row previews it live (`onSelect`); Enter/click commits it.
    func paletteThemes() -> [PaletteItem] {
        let current = effectiveTheme
        func item(_ entry: ThemeCatalog.Entry) -> PaletteItem {
            let name = entry.name
            return PaletteItem(id: entry.id, title: entry.title, badge: name == current ? "current" : nil,
                        onSelect: { [weak self] in self?.previewTheme(name) },
                        run: { [weak self] in
                            self?.previewTheme(name)
                            self?.commitThemePreview()
                        })
        }
        // the nil row is ghostty's built-in default (no theme file); the app's own default is the
        // bundled "agterm" theme, which appears in the named list like any other. While following the
        // system appearance the nil row is OMITTED (mirroring the Settings picker): a dual conditional
        // needs two NAMED themes, so previewing nil would blank a slot and wedge the following state.
        let entries = ThemeCatalog(names: SettingsCatalog.themeNames()).entries
        return (followsSystemAppearance ? entries.filter { !$0.isDefault } : entries).map(item)
    }

    /// The palette-item id of the currently-applied theme, so the picker opens with that row selected
    /// (and previews it — a no-op — rather than jumping to "Default").
    var currentThemeID: String { ThemeCatalog.id(for: effectiveTheme) }

    /// The theme currently ON SCREEN: the dark slot while following in dark mode, else `theme`. The
    /// palette badges/opens on this and previews/commits target the same slot, so the open-row preview
    /// matches what is rendering.
    private var effectiveTheme: String? {
        settingsModel?.settings.activeTheme(isDark: GhosttyApp.currentIsDark())
    }

    /// Capture BOTH theme slots so Esc/cancel can restore the pre-preview pair. Snapshotting the whole
    /// pair (not just the on-screen slot) keeps the revert correct even if macOS flips appearance
    /// mid-preview — see `cancelThemePreview`. Idempotent while a preview is active.
    func beginThemePreview() {
        guard let settingsModel, !themePreviewActive else { return }
        themePreviewOriginal = (settingsModel.settings.theme, settingsModel.settings.darkTheme)
        themePreviewActive = true
    }

    /// Apply a theme live without persisting (the navigation preview). No-op outside an active picker.
    func previewTheme(_ name: String?) {
        guard themePreviewActive else { return }
        settingsModel?.previewTheme(name)
    }

    /// Persist the previewed theme (Enter/click). Ends the preview so the subsequent palette close can't
    /// revert it. The preview already wrote the current-appearance slot (dark slot while following in
    /// dark mode, else `theme`), so only that slot commits — the captured pair is passed back so the
    /// OTHER slot is restored to its pre-preview value, otherwise a value browsed into it during a
    /// mid-preview appearance flip would leak in on commit (the flip-safe twin of `cancelThemePreview`).
    func commitThemePreview() {
        guard themePreviewActive else { return }
        if let original = themePreviewOriginal {
            settingsModel?.commitTheme(nonActiveOriginal: original)
        }
        themePreviewActive = false
        themePreviewOriginal = nil
    }

    /// Restore BOTH captured slots and end the preview (Esc / scrim / mode switch / unmount without a
    /// commit). No-op when no preview is active (e.g. right after a commit). Routes through the IMMEDIATE
    /// (non-debounced) revert so Esc restores the original pair instantly — the navigation preview is
    /// debounced, so calling `previewTheme` here would lag or leave the last previewed theme stuck
    /// applied. Reverting the WHOLE pair (not the on-screen slot) is flip-safe: an appearance flip
    /// mid-preview can't strand a previewed value in the wrong slot.
    func cancelThemePreview() {
        guard themePreviewActive else { return }
        if let original = themePreviewOriginal {
            settingsModel?.revertThemePreview(theme: original.theme, darkTheme: original.dark)
        }
        themePreviewActive = false
        themePreviewOriginal = nil
    }

    /// The bundled theme names, for the control channel's `theme.list` and its name validation.
    func availableThemes() -> [String] { SettingsCatalog.themeNames() }

    /// The plain single theme (nil = ghostty default), for `theme.set`/`theme.list`'s `result.theme`.
    /// nil while following — the sync state rides `sync`/`light`/`dark` instead of the single theme.
    var currentTheme: String? {
        guard settingsModel?.settings.followSystemAppearance != true else { return nil }
        return settingsModel?.settings.theme
    }

    /// macOS light/dark appearance-sync state, for `theme.set`/`theme.list`.
    var followsSystemAppearance: Bool { settingsModel?.settings.followSystemAppearance == true }
    var currentLightTheme: String? { followsSystemAppearance ? settingsModel?.settings.theme : nil }
    var currentDarkTheme: String? { followsSystemAppearance ? settingsModel?.settings.darkTheme : nil }

    /// Set the light/single slot, keeping a dark side if present — the control channel's
    /// `theme.set <name>` (the persist+apply path, no live preview). nil clears everything.
    func setLightTheme(_ name: String?) { settingsModel?.setLightTheme(name) }

    /// Set (or with nil, clear) the dark slot — the control channel's `theme.set --dark`.
    func setDarkTheme(_ name: String?) { settingsModel?.setDarkTheme(name) }

    /// Set both sides at once — the control channel's `theme.set --light --dark`.
    func setSystemThemes(light: String, dark: String) { settingsModel?.setSystemThemes(light: light, dark: dark) }
}
