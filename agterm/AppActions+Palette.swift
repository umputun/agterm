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
            activeSessionHasSplit: activeStore?.activeSession?.hasSplit == true
        )
    }

    private func paletteItem(for command: PaletteCommand, context: PaletteContext) -> PaletteItem {
        PaletteItem(title: command.title(in: context),
                    shortcut: command.builtinAction.flatMap { shortcutGlyph(for: $0) }) { [weak self] in
            self?.runPaletteCommand(command)
        }
    }

    private func runPaletteCommand(_ command: PaletteCommand) {
        switch command {
        case .newSession: newSession()
        case .newWorkspace: newWorkspace()
        case .openDirectory: openDirectory()
        case .renameSession: renameActiveSession()
        case .renameWorkspace: renameActiveWorkspace()
        case .closeSession: closeActiveSession()
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
        case .toggleSidebar: toggleSidebar()
        case .toggleFlag: toggleFlagActiveSession()
        case .focusWorkspace: focusActiveWorkspace()
        case .find: toggleSearch()
        case .quickTerminal: toggleQuickTerminal()
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
        return store.attentionSessions.map { paletteItem(for: $0, in: store, status: $0.agentIndicator.status) }
    }

    /// Maps one session to a palette row — title=`displayName`, subtitle="`workspace` · `subtitleDetail`",
    /// `run` selects it. Shared by `paletteSessions()` (status nil) and `paletteAttention()` (status set so
    /// `CommandPalette.row` renders the leading `StatusGlyph`).
    private func paletteItem(for session: Session, in store: AppStore, status: AgentStatus? = nil) -> PaletteItem {
        let id = session.id
        let workspaceName = store.workspace(forSession: id)?.name ?? ""
        let subtitle = "\(workspaceName) · \(session.subtitleDetail)"
        return PaletteItem(id: id.uuidString, title: session.displayName, subtitle: subtitle, status: status) {
            store.selectSession(id)
        }
    }

    /// Toggle the `.attention` command palette (the window's non-idle sessions). Driven by the ⌃⇧I
    /// `BuiltinAction.showAttention`, the Navigate ▸ Go to Attention… menu item, and the titlebar bell
    /// icon — none of these route through the action palette's `runItem`, so a synchronous toggle is
    /// correct. The ⌃⇧P launcher uses `openAttentionPalette()` instead (it must reopen async).
    func toggleAttentionPalette() {
        palette?.toggle(.attention)
    }

    /// Open the `.attention` command palette from the action-palette "Show Attention" launcher. Opened on
    /// the next runloop tick (mirroring `openThemePalette()`): the launcher runs inside the open action
    /// palette's `runItem`, which calls `controller.close()` right after this returns, so a synchronous
    /// `toggle` would be undone by that close. The async `open` lets `.attention` reopen a tick later as a
    /// fresh view that survives the close.
    func openAttentionPalette() {
        DispatchQueue.main.async { [weak self] in self?.palette?.open(.attention) }
    }

    // MARK: - Theme picker

    /// Open the `.themes` command palette (the live-preview theme picker). Invoked by the action-palette
    /// "Select Theme…" launcher and the View ▸ Select Theme… menu item. Opened on the next runloop tick:
    /// when launched from the open action palette, that palette's run handler closes itself right after
    /// this returns, so reopening async lets `.themes` survive the close (the rename actions reopen the
    /// same way).
    func openThemePalette() {
        DispatchQueue.main.async { [weak self] in self?.palette?.open(.themes) }
    }

    /// Theme rows for the `.themes` palette: a leading "Default" entry plus one per bundled theme,
    /// the current one badged. Navigating a row previews it live (`onSelect`); Enter/click commits it.
    func paletteThemes() -> [PaletteItem] {
        let current = settingsModel?.settings.theme
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
        // bundled "agterm" theme, which appears in the named list like any other.
        return ThemeCatalog(names: SettingsCatalog.themeNames()).entries.map(item)
    }

    /// The palette-item id of the currently-applied theme, so the picker opens with that row selected
    /// (and previews it — a no-op — rather than jumping to "Default").
    var currentThemeID: String { ThemeCatalog.id(for: settingsModel?.settings.theme) }

    /// Capture the live theme so Esc/cancel can restore it. Idempotent while a preview is active.
    func beginThemePreview() {
        guard let settingsModel, !themePreviewActive else { return }
        themePreviewOriginal = settingsModel.settings.theme
        themePreviewActive = true
    }

    /// Apply a theme live without persisting (the navigation preview). No-op outside an active picker.
    func previewTheme(_ name: String?) {
        guard themePreviewActive else { return }
        settingsModel?.previewTheme(name)
    }

    /// Persist the previewed theme (Enter/click). Ends the preview so the subsequent palette close
    /// can't revert it.
    func commitThemePreview() {
        guard themePreviewActive else { return }
        settingsModel?.commitTheme()
        themePreviewActive = false
        themePreviewOriginal = nil
    }

    /// Re-apply the captured original theme and end the preview (Esc / scrim / mode switch / unmount
    /// without a commit). No-op when no preview is active (e.g. right after a commit). Routes through
    /// the IMMEDIATE (non-debounced) revert so Esc restores the original theme instantly — the
    /// navigation preview is debounced, so calling `previewTheme` here would lag or leave the last
    /// previewed theme stuck applied.
    func cancelThemePreview() {
        guard themePreviewActive else { return }
        settingsModel?.previewThemeImmediate(themePreviewOriginal)
        themePreviewActive = false
        themePreviewOriginal = nil
    }

    /// Set + persist a theme by name — the control channel's `theme.set` (no live preview; it's the
    /// same persist+apply path as the Settings picker). A nil/empty name selects the default theme.
    func setTheme(_ name: String?) { settingsModel?.setTheme(name) }

    /// The bundled theme names, for the control channel's `theme.list` and its name validation.
    func availableThemes() -> [String] { SettingsCatalog.themeNames() }

    /// The currently-applied theme (nil = default), for the control channel's `theme.list`.
    var currentTheme: String? { settingsModel?.settings.theme }
}
