import AppKit
import agtermCore
import Foundation

/// Command palettes (action / session / attention / custom-command feeds) and the live-preview theme picker
/// for `AppActions`. The theme-preview state (`themePreviewActive`/`themePreviewOriginal`) lives on the main
/// `AppActions` declaration — an extension can hold no stored properties — while its logic lives here.
extension AppActions {
    // MARK: - Command palettes

    /// The macOS glyph string for a rebindable built-in's CURRENT shortcut (`⌘N`, `⌃⌘S`), reading like the menu
    /// equivalent, or nil when the action has no shortcut. The SINGLE resolver behind both the action-palette
    /// hints and the toolbar/sidebar tooltips, so the two can't drift. `glyphHint` resolves the live keymap
    /// (override else shipped default); before `settingsModel` is wired, the shipped default alone.
    func shortcutGlyph(for action: BuiltinAction) -> String? {
        guard let keymap = settingsModel?.keymap else { return action.defaultChord?.glyphString }
        return keymap.glyphHint(for: action)
    }

    /// The live facts behind `PaletteCommand.isEnabled(in:)`. Read by the palette rows, by `perform(_:in:)`
    /// and by the menu items in `agtermApp+Menus`, so the three read one predicate over one set of facts.
    var paletteContext: PaletteContext {
        let activeStore = store
        return PaletteContext(
            canRemoveWorkspace: activeStore?.canRemoveWorkspace == true,
            hasFlaggedSessions: activeStore?.flaggedSessions.isEmpty == false,
            sidebarShowsWorkspaceTree: activeStore?.sidebarMode == .tree,
            sidebarShowsFlaggedOnly: activeStore?.sidebarMode == .flagged,
            activeSessionFlagged: activeStore?.activeSession?.flagged == true,
            hasMarkedWorkspaces: activeStore?.focusedWorkspaceIDs.isEmpty == false,
            activeWorkspaceMarked: activeStore?.isCurrentWorkspaceFocusMember == true,
            activeSessionHasSplit: activeStore?.activeSession?.hasSplit == true,
            hasPendingClose: activeStore?.pendingCloseSummary != nil,
            hasRecentClosed: !library.recentClosedItems.isEmpty,
            hasActiveSession: activeStore?.activeSession != nil,
            hasCurrentWorkspace: activeStore?.currentWorkspaceID != nil,
            terminalZoomActive: terminalZoomActive,
            dashboardOpen: frontmostDashboard?.isOpen == true,
            pickerActive: pickActive(for: library.activeWindowID)
        )
    }

    /// `context` supplies only the title, which the palette's own rebuild refreshes. Enablement takes a closure
    /// over LIVE state instead: the row renders and runs against the state of the moment, not of the last build.
    private func paletteItem(for command: PaletteCommand, context: PaletteContext) -> PaletteItem {
        PaletteItem(title: command.title(in: context),
                    shortcut: command.builtinAction.flatMap { shortcutGlyph(for: $0) },
                    isEnabled: { [weak self] in
                        guard let self else { return false }
                        return command.isEnabled(in: paletteContext)
                    },
                    run: { [weak self] in self?.runPaletteCommand(command) })
    }

    /// The row's body keeps the predicate too, so a caller reaching `run` without asking `isEnabled` still
    /// cannot run a disabled action.
    private func runPaletteCommand(_ command: PaletteCommand) {
        guard command.isEnabled(in: paletteContext) else { return }
        dispatch(command)
    }

    /// The action behind a palette row, ungated: both callers apply `PaletteCommand.isEnabled(in:)` first.
    private func dispatch(_ command: PaletteCommand) {
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
        case .addWorkspaceToFocus: addActiveWorkspaceToFocus()
        case .toggleWorkspaceFilter: toggleFocusFilter()
        case .expandWorkspaces: expandAllWorkspaces()
        case .collapseWorkspaces: collapseOtherWorkspaces()
        case .focusLeftPane: focusPane(.main)
        case .focusRightPane: focusPane(.split)
        }
    }

    /// Run a built-in action fired by `CustomCommandRunner`'s key monitor in `window` — a `map` line's
    /// alternative beyond the menu key equivalent. The MENU chord is the reference behavior: an alternative of
    /// a line does what its menu-bound sibling does, so it runs the palette row's body behind
    /// `isEnabled(in:)`, the predicate the menu item spells as its `.disabled(…)`. The rest go through
    /// `paletteLessHandler(for:)`, whose entry points carry their gate themselves.
    func perform(_ action: BuiltinAction, in window: NSWindow?) {
        if let command = PaletteCommand.allCases.first(where: { $0.builtinAction == action }) {
            guard command.isEnabled(in: paletteContext) else { return }
            // the MENU's close rung, not the palette's: with no cover and no session left to close, ⌘W closes
            // the window — the zero-session window a keybind still fires in. The menu's other rung, an
            // auxiliary key window keeping its own ⌘W, is unreachable here: the monitor fires only inside an
            // agterm terminal window.
            if command == .closeSession {
                closeActiveSessionOrWindow(window)
                return
            }
            dispatch(command)
            return
        }
        paletteLessHandler(for: action)?()
    }

    /// The entry point for a built-in that no `PaletteCommand` row owns — window management and the three
    /// palette launchers, each already gated where it needs to be — and nil for every action the palette
    /// covers. The SINGLE listing of those actions: `perform(_:)` dispatches through it and
    /// `AppActionsPaletteTests` partitions `BuiltinAction.allCases` across it and `PaletteCommand`, so a new
    /// action reaching neither fails a test instead of binding a key that swallows itself and does nothing.
    func paletteLessHandler(for action: BuiltinAction) -> (() -> Void)? {
        switch action {
        case .newWindow: return { self.newWindow() }
        case .renameWindow: return renameActiveWindow
        case .deleteWindow: return deleteActiveWindow
        case .sessionPalette: return toggleSessionPalette
        case .commandPalette: return toggleActionPalette
        case .customCommandPalette: return toggleCustomCommandPalette
        default: return nil
        }
    }

    /// The app's commands as palette items, sharing the same logic as the menu/buttons. Includes a
    /// "Move Session to …" item per other workspace (when there's an active session to move).
    func paletteActions() -> [PaletteItem] {
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
        // skip the session's OWN workspace, not `currentWorkspaceID` — a freshly created workspace is
        // current while the selection still sits elsewhere, and it is a valid destination.
        if let store, let sessionID = store.selectedSessionID,
           let owner = store.workspace(forSession: sessionID)?.id {
            for workspace in store.workspaces where workspace.id != owner {
                let target = workspace.id
                items.append(PaletteItem(id: "move-\(target)", title: "Move Session to \(workspace.name)") { [weak self] in
                    self?.moveSession(sessionID, toWorkspace: target)
                })
            }
        }
        items.append(contentsOf: customCommandItems(badge: "custom"))
        return items
    }

    /// The user-defined keymap commands as palette items with their bound chord; running one delegates to the
    /// runner, which resolves the active session's context and spawns the shell line. `badge` tags each entry.
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

    /// The user-defined keymap commands alone, for the `.customCommands` palette: unbadged, all are custom.
    func paletteCustomCommands() -> [PaletteItem] {
        customCommandItems(badge: nil)
    }

    /// The VISIBLE/FILTERED sessions as palette items (the ⌃P switcher); choosing one selects it. Scoped to
    /// `navigableSessions` — the MARKED workspaces' sessions under the focus filter, the flagged set in flagged
    /// mode, else all — so ⌃P matches the sidebar, the Ctrl-Tab MRU switcher and `session.go`. The subtitle
    /// leads with the owning workspace, telling same-named sessions apart and searchable, then `subtitleDetail`.
    func paletteSessions() -> [PaletteItem] {
        guard let store else { return [] }
        return store.navigableSessions.map { paletteItem(for: $0, in: store) }
    }

    /// The window's non-idle sessions as palette items (`.attention` mode), each row carrying the session's
    /// agent-status glyph. `store.attentionSessions` orders blocked→active→completed, newest status-change
    /// first, so the empty-query order matches; choosing one selects it. Subtitle as in `paletteSessions()`.
    func paletteAttention() -> [PaletteItem] {
        guard let store else { return [] }
        return store.attentionSessions.map {
            paletteItem(for: $0, in: store, status: $0.agentIndicator.status,
                        statusColor: $0.agentIndicator.color, statusShape: $0.agentIndicator.shape)
        }
    }

    /// Maps one session to a palette row — title `displayName`, subtitle "`workspace` · `subtitleDetail`", run
    /// selects it. Shared by `paletteSessions()` (status nil) and `paletteAttention()`, where a set status makes
    /// `CommandPalette.row` render the leading `StatusGlyph` in the per-call `statusColor`/`statusShape`.
    private func paletteItem(for session: Session, in store: AppStore, status: AgentStatus? = nil,
                             statusColor: String? = nil, statusShape: StatusShape? = nil) -> PaletteItem {
        let id = session.id
        let workspaceName = store.workspace(forSession: id)?.name ?? ""
        let subtitle = "\(workspaceName) · \(session.subtitleDetail)"
        return PaletteItem(id: id.uuidString, title: session.displayName, subtitle: subtitle,
                           status: status, statusColor: statusColor, statusShape: statusShape) { [weak self] in
            guard self?.uiActionsEnabled == true else { return }
            // a palette pick is user-initiated: note activity so it buys the full idle grace before
            // auto-follow can pull the selection back.
            store.noteUserActivity()
            let indicator = store.selectSession(id)
            // reveal the picked session's blocked pane (no-op without a pane-tagged block), async so it runs
            // AFTER the palette closes and its focus-restore, winning the focus race.
            DispatchQueue.main.async { self?.revealActiveBlockedPane(captured: indicator) }
        }
    }

    /// Toggle the `.attention` palette. Driven by ⌃⇧I `BuiltinAction.showAttention`, Navigate ▸ Go to
    /// Attention…, and the titlebar bell — none route through the action palette's `runItem`, so a synchronous
    /// toggle is correct; the ⌃⇧P launcher uses `openAttentionPalette()`, which must reopen async.
    func toggleAttentionPalette() {
        guard !terminalZoomActive, !pickActive(for: library.activeWindowID) else { return }
        palette?.toggle(.attention)
    }

    /// Menu/keymap palette launchers route through actions, not `palette.toggle`, so the modal UI guard applies
    /// consistently to the keyboard-shortcut and menu paths. The full `uiActionsEnabled` and not zoom/picker
    /// alone: their menu items carry the `modalActive` mirror, so a launcher must not open a palette over the
    /// dashboard grid the menu item refuses to open it over.
    func toggleSessionPalette() {
        guard uiActionsEnabled else { return }
        palette?.toggle(.sessions)
    }

    func toggleActionPalette() {
        guard uiActionsEnabled else { return }
        palette?.toggle(.actions)
    }

    func toggleCustomCommandPalette() {
        guard uiActionsEnabled else { return }
        palette?.toggle(.customCommands)
    }

    /// Open `.attention` from the action-palette "Show Attention" launcher on the next runloop tick, like
    /// `openThemePalette()`: the launcher runs inside the action palette's `runItem`, which calls
    /// `controller.close()` right after this returns, so a synchronous toggle would be undone.
    func openAttentionPalette() {
        guard !terminalZoomActive, !pickActive(for: library.activeWindowID) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminalZoomActive,
                  !self.pickActive(for: self.library.activeWindowID) else { return }
            self.palette?.open(.attention)
        }
    }

    // MARK: - Theme picker

    /// Open the `.themes` palette (the live-preview theme picker), from the action-palette "Select Theme…"
    /// launcher or View ▸ Select Theme…, on the next runloop tick: launched from the open action palette, that
    /// palette's run handler closes itself right after this returns, so only an async reopen survives it.
    func openThemePalette() {
        guard !terminalZoomActive, !pickActive(for: library.activeWindowID) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminalZoomActive,
                  !self.pickActive(for: self.library.activeWindowID) else { return }
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
        // the nil row is ghostty's built-in default (no theme file); the app's own default is the bundled
        // "agterm" theme, listed like any other. While following the system appearance the nil row is OMITTED:
        // a dual conditional needs two NAMED themes, so previewing nil blanks a slot and wedges that state.
        let entries = ThemeCatalog(names: SettingsCatalog.themeNames()).entries
        return (followsSystemAppearance ? entries.filter { !$0.isDefault } : entries).map(item)
    }

    /// The applied theme's palette-item id, so the picker opens on that row (a no-op preview), not "Default".
    var currentThemeID: String { ThemeCatalog.id(for: effectiveTheme) }

    /// The theme currently ON SCREEN: the dark slot while following in dark mode, else `theme`. The palette
    /// badges/opens on it and previews/commits target the same slot, so the open-row preview matches rendering.
    private var effectiveTheme: String? {
        settingsModel?.settings.activeTheme(isDark: GhosttyApp.currentIsDark())
    }

    /// Capture BOTH theme slots, not just the on-screen one, so Esc/cancel restores the pre-preview pair even
    /// if macOS flips appearance mid-preview. Idempotent while a preview is active.
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

    /// Persist the previewed theme (Enter/click), ending the preview so the palette close can't revert it. The
    /// preview already wrote the current-appearance slot, so only that slot commits; the captured pair goes
    /// back so the OTHER slot returns to its pre-preview value, else a value browsed into it during a
    /// mid-preview appearance flip would leak in on commit.
    func commitThemePreview() {
        guard themePreviewActive else { return }
        if let original = themePreviewOriginal {
            settingsModel?.commitTheme(nonActiveOriginal: original)
        }
        themePreviewActive = false
        themePreviewOriginal = nil
    }

    /// Restore BOTH captured slots and end the preview (Esc / scrim / mode switch / unmount without a commit);
    /// no-op when no preview is active. Routes through the IMMEDIATE (non-debounced) revert so Esc restores the
    /// original pair instantly — the debounced navigation preview would lag or leave the last theme stuck
    /// applied. Reverting the WHOLE pair is flip-safe: a mid-preview flip can't strand a value in a wrong slot.
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

    /// Set the light/single slot, keeping any dark side — `theme.set <name>`: persist+apply, no live preview;
    /// nil clears everything.
    func setLightTheme(_ name: String?) { settingsModel?.setLightTheme(name) }

    /// Set (or with nil, clear) the dark slot — the control channel's `theme.set --dark`.
    func setDarkTheme(_ name: String?) { settingsModel?.setDarkTheme(name) }

    /// Set both sides at once — the control channel's `theme.set --light --dark`.
    func setSystemThemes(light: String, dark: String) { settingsModel?.setSystemThemes(light: light, dark: dark) }
}
