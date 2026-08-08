import agtermCore
import AppKit
import SwiftUI

extension agtermApp {
    /// The active SwiftUI shortcut for a built-in action: the user's `map` override, else the shipped
    /// default; nil only for a keyless action. `keymap` is `@Observable`, but SwiftUI defers its menu
    /// rebuild to the next app activation, so a reload leaves live key equivalents stale until then — ⌘W is
    /// asserted from AppKit instead, by `AppDelegate.applyCloseSessionChord`.
    private func shortcut(for action: BuiltinAction) -> KeyboardShortcut? {
        settingsModel.keymap.equivalent(for: action).map(Self.toShortcut)
    }

    /// Map a host-free `Chord` to a SwiftUI `KeyboardShortcut` — the menu-side mirror of the runner's
    /// `NSEvent`→`Chord` mapping. The base key is a printable `Character` or a named key; modifiers map 1:1.
    private static func toShortcut(_ chord: Chord) -> KeyboardShortcut {
        let key: KeyEquivalent
        switch chord.key {
        case "tab": key = .tab
        case "space": key = .space
        case "return": key = .return
        case "delete": key = .delete
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        case "up": key = .upArrow
        case "down": key = .downArrow
        default: key = KeyEquivalent(Character(chord.key))
        }
        var modifiers: EventModifiers = []
        if chord.mods.contains(.control) { modifiers.insert(.control) }
        if chord.mods.contains(.command) { modifiers.insert(.command) }
        if chord.mods.contains(.option) { modifiers.insert(.option) }
        if chord.mods.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    /// Whether `close_session` currently holds ⌘W, read live rather than off the deferred menu equivalent.
    /// `AppDelegate.applyCloseSessionChord` splits the chord on the same condition.
    private var closeSessionOwnsCommandW: Bool {
        settingsModel.keymap.equivalent(for: .closeSession) == Chord(mods: [.command], key: "w")
    }

    private func recentTitle(_ item: RecentClosedItem) -> String {
        guard let subtitle = item.subtitle, !subtitle.isEmpty else { return item.title }
        return "\(item.title) - \(subtitle)"
    }

    @CommandsBuilder
    var appCommands: some Commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Agterm") { showAboutPanel() }
            }
            // drop SwiftUI's stock Undo/Redo: agterm registers no NSUndoManager, and the ⌘Z they advertise
            // is owned by File ▸ Reopen Closed Item (`BuiltinAction.undoClose`), whose menu precedes Edit
            // and wins the key-equivalent search — so Undo could only ever be CLICKED, and AppKit enabled it
            // only in the sidebar's inline rename field (whose field editor supplies an undo manager). The
            // rest stays stock: replacing the shared `.pasteboard` group takes ⌘C/⌘V/⌘A from text fields.
            CommandGroup(replacing: .undoRedo) {}
            // File: replace the default "New" group with agterm's creation/management actions, grouped by
            // entity into Window, Workspace, Session. System Close / Close All stay below in their own group.
            CommandGroup(replacing: .newItem) {
                // zoom, the dashboard grid, or a topmost native picker makes the UI modal (the AppActions
                // gate already no-ops these); `.disabled` mirrors it so items read as unavailable instead
                // of dead and key equivalents cannot mutate the covered deck.
                let zoomed = actions.terminalZoomActive
                let pickActive = actions.pickActive(for: library.activeWindowID)
                let modalActive = zoomed || (actions.frontmostDashboard?.isOpen ?? false) || pickActive
                // Window: Open Window lists the library with a checkmark on already-open ones (picking a
                // closed one opens it, an open one raises it). Delete is disabled with one window left.
                Button("New Window") { actions.newWindow() }
                    .keyboardShortcut(shortcut(for: .newWindow))
                    .disabled(modalActive)
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
                .disabled(modalActive)
                Button("Rename Window…") { actions.renameActiveWindow() }
                    .keyboardShortcut(shortcut(for: .renameWindow))
                    .disabled(modalActive)
                Button("Delete Window") { actions.deleteActiveWindow() }
                    .keyboardShortcut(shortcut(for: .deleteWindow))
                    .disabled(!library.canRemoveWindow || modalActive)

                Divider()
                // Workspace.
                Button("New Workspace") { actions.newWorkspace() }
                    .keyboardShortcut(shortcut(for: .newWorkspace))
                    .disabled(modalActive)
                Button("Rename Workspace") { actions.renameActiveWorkspace() }
                    .keyboardShortcut(shortcut(for: .renameWorkspace))
                    .disabled(library.activeStore?.currentWorkspaceID == nil || modalActive)
                Button("Delete Workspace") { actions.deleteActiveWorkspace() }
                    .keyboardShortcut(shortcut(for: .deleteWorkspace))
                    .disabled(library.activeStore?.canRemoveWorkspace != true || modalActive)

                Divider()
                // Session.
                Button("New Session") { actions.newSession() }
                    .keyboardShortcut(shortcut(for: .newSession))
                    .disabled(modalActive)
                Button("Open Directory…") { actions.openDirectory() }
                    .keyboardShortcut(shortcut(for: .openDirectory))
                    .disabled(modalActive)
                Menu("Open Recent") {
                    let recentSessions = library.recentClosedItems.filter { $0.kind == .session }
                    let recentWorkspaces = library.recentClosedItems.filter { $0.kind == .workspace }
                    if recentSessions.isEmpty && recentWorkspaces.isEmpty {
                        Text("No Recent Items")
                    } else {
                        if !recentSessions.isEmpty {
                            Section("Sessions") {
                                ForEach(recentSessions) { item in
                                    Button(recentTitle(item)) { actions.openRecentClosed(item.id) }
                                }
                            }
                        }
                        if !recentWorkspaces.isEmpty {
                            Section("Workspaces") {
                                ForEach(recentWorkspaces) { item in
                                    Button(recentTitle(item)) { actions.openRecentClosed(item.id) }
                                }
                            }
                        }
                        Divider()
                        Button("Clear Menu") { actions.clearRecentClosedItems() }
                    }
                }
                .disabled(library.recentClosedItems.isEmpty || modalActive)
                Button("Reopen Last Closed Item") { actions.openLatestRecentClosed() }
                    .keyboardShortcut(shortcut(for: .reopenRecent))
                    .disabled(library.recentClosedItems.isEmpty || modalActive)
                Button("Rename Session") { actions.renameActiveSession() }
                    .keyboardShortcut(shortcut(for: .renameSession))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Button("Duplicate Session") { actions.duplicateActiveSession() }
                    .keyboardShortcut(shortcut(for: .duplicateSession))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Button("Reveal in Finder") { actions.revealActiveSessionInFinder() }
                    .disabled(!actions.canRevealActiveSessionInFinder)
                Button("Close Session") {
                    // an auxiliary key window — Settings, the About panel, an open/save panel — is not part of
                    // any terminal deck, so ⌘W there keeps its standard meaning and closes THAT window. It can
                    // only come from here: `applyCloseSessionChord` strips ⌘W off the stock File ▸ Close item
                    // while close_session owns the chord, so without this rung the keystroke falls through to
                    // the deck behind the panel and takes a session with it (issue #401). Same predicate as
                    // `CustomCommandRunner`'s no-surface gate. A nil key window keeps the deck behavior.
                    // Gated on close_session still holding ⌘W: rebound off it, the stock item takes the chord
                    // back and an auxiliary window closes itself, so the new chord means only what it says.
                    if closeSessionOwnsCommandW, let key = NSApp.keyWindow, !WindowRegistry.shared.contains(key) {
                        key.performClose(nil)
                        return
                    }
                    // closeActiveSession dismisses any cover (quick terminal / overlay / scratch) or closes the
                    // active session; only when it handled nothing (no cover, no session) fall back to the window.
                    if !actions.closeActiveSession() { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut(shortcut(for: .closeSession))
                Button("Reopen Closed Item") { actions.undoClose() }
                    .disabled(library.activeStore?.pendingCloseSummary == nil || modalActive)
                Button("Clear Status") { actions.clearActiveSessionStatus() }
                    .keyboardShortcut(shortcut(for: .clearStatus))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Divider()
                // open keymap.conf in $EDITOR in a 95% overlay over the active session; reloads when the
                // editor exits. keyless, like Reload Keymap.
                Button { actions.editKeymap() } label: { Label("Edit Keymap…", systemImage: "pencil") }
                    .disabled(modalActive)
                // re-read keymap.conf and apply — menu shortcuts, runner and palette rebuild. keyless.
                Button { actions.reloadKeymap() } label: { Label("Reload Keymap", systemImage: "keyboard") }
                // open the agterm-scoped ghostty.conf in $EDITOR in a 95% overlay; reloads on editor exit.
                Button { actions.editGhosttyConfig() } label: { Label("Edit ghostty.conf…", systemImage: "slider.horizontal.3") }
                    .disabled(modalActive)
                // re-read ghostty.conf and rebroadcast to every surface; banner-warns on a malformed file.
                Button { actions.reloadGhosttyConfig() } label: { Label("Reload Config", systemImage: "arrow.clockwise") }
            }
            // View: font zoom (on the focused terminal), the status-bar toggle, split / quick terminal /
            // palettes. Every item needs an SF Symbol: one iconless item renders as a blank, indented slot
            // beside the icon column its neighbours reserve.
            CommandGroup(after: .toolbar) {
                // the File group's modal gate, mirrored.
                let zoomed = actions.terminalZoomActive
                let pickActive = actions.pickActive(for: library.activeWindowID)
                let modalActive = zoomed || (actions.frontmostDashboard?.isOpen ?? false) || pickActive
                Button { actions.increaseFontSize() } label: { Label("Increase Font Size", systemImage: "textformat.size.larger") }
                    .keyboardShortcut(shortcut(for: .increaseFontSize))
                Button { actions.decreaseFontSize() } label: { Label("Decrease Font Size", systemImage: "textformat.size.smaller") }
                    .keyboardShortcut(shortcut(for: .decreaseFontSize))
                Button { actions.resetFontSize() } label: { Label("Actual Size", systemImage: "textformat.size") }
                    .keyboardShortcut(shortcut(for: .resetFontSize))
                // open the live-preview theme picker (the .themes palette). keyless by default, rebindable
                // via select_theme; the control half is theme.set / theme.list.
                Button { actions.openThemePalette() } label: { Label("Select Theme…", systemImage: "paintpalette") }
                    .keyboardShortcut(shortcut(for: .selectTheme))
                    .disabled(modalActive)
                Divider()
                let sidebarShown = library.activeStore?.sidebarVisible ?? true
                Button { actions.toggleSidebar() } label: {
                    Label(sidebarShown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut(shortcut(for: .toggleSidebar))
                .disabled(modalActive)
                // expand every workspace / collapse all but the active one. plain keyless items, disabled
                // with no active store or in flagged mode (no workspace rows); control sidebar.expand/collapse.
                let treeMode = library.activeStore?.sidebarMode == .tree
                Button { actions.expandAllWorkspaces() } label: { Label("Expand Workspaces", systemImage: "chevron.down") }
                    .disabled(library.activeStore == nil || !treeMode || modalActive)
                Button { actions.collapseOtherWorkspaces() } label: { Label("Collapse Workspaces", systemImage: "chevron.right") }
                    .disabled(library.activeStore == nil || !treeMode || modalActive)
                // flip the sidebar between the workspace tree and the flat flagged working-set list. one
                // 2-state item, keyless by default (rebindable via toggle_flagged_view); control sidebar.mode.
                let flaggedMode = library.activeStore?.sidebarMode == .flagged
                // disabled (along with its shortcut) when there's nothing to show: tree mode + no flags.
                // Enabled in flagged mode so it can always switch back to the tree.
                let noFlaggedToShow = !flaggedMode && (library.activeStore?.flaggedSessions.isEmpty ?? true)
                Button { actions.toggleFlaggedView() } label: {
                    Label(flaggedMode ? "Show All Sessions" : "Show Flagged Sessions", systemImage: "flag")
                }
                .keyboardShortcut(shortcut(for: .toggleFlaggedView))
                .disabled(noFlaggedToShow || modalActive)
                let sessionFlagged = library.activeStore?.activeSession?.flagged == true
                Button { actions.toggleFlagActiveSession() } label: {
                    Label(sessionFlagged ? "Unflag Session" : "Flag Session", systemImage: "flag.badge.ellipsis")
                }
                .keyboardShortcut(shortcut(for: .toggleFlag))
                .disabled(library.activeStore?.activeSession == nil || modalActive)
                Button { actions.clearFlags() } label: { Label("Clear Flagged", systemImage: "flag.slash") }
                    .disabled(library.activeStore?.flaggedSessions.isEmpty ?? true || modalActive)
                // collapse the tree to the current workspace's subtree (or unfocus when already focused).
                // keyless, rebindable via focus_workspace; control workspace.focus. the label tracks the toggle.
                let focusStore = library.activeStore
                Button { actions.focusActiveWorkspace() } label: {
                    Label(focusStore?.isCurrentWorkspaceSoleFocus == true ? "Unfocus Workspace" : "Focus Workspace",
                          systemImage: "scope")
                }
                .keyboardShortcut(shortcut(for: .focusWorkspace))
                .disabled(focusStore?.currentWorkspaceID == nil || modalActive)
                // the ADDITIVE sibling of Focus Workspace: mark the current workspace without dropping the
                // other members, so a working set can be built from the menu. plain keyless item; control
                // workspace.focus add. disabled once the workspace is marked, where it would be a silent
                // no-op (the row menu flips to "Remove from Focus", having a clicked row). membership is
                // NOT gated on sidebar mode here or in the palette, matching its focus siblings.
                Button { actions.addActiveWorkspaceToFocus() } label: {
                    Label("Add Workspace to Focus", systemImage: "square.grid.2x2")
                }
                .disabled(focusStore?.currentWorkspaceID == nil
                    || focusStore?.isCurrentWorkspaceFocusMember == true || modalActive)
                // apply or suspend the filter without losing the marked set — the menu twin of the bottom-bar
                // grid toggle, disabled on an empty set (the store refuses one); control workspace.filter.
                Button { actions.toggleFocusFilter() } label: {
                    Label("Toggle Workspace Filter", systemImage: "square.grid.2x2")
                }
                .keyboardShortcut(shortcut(for: .toggleWorkspaceFilter))
                .disabled((focusStore?.focusedWorkspaceIDs.isEmpty ?? true) || modalActive)
                // plain (non-BuiltinAction) clear, like Clear Flagged; the bottom-bar toggle is primary.
                Button { actions.clearFocus() } label: { Label("Clear Focus", systemImage: "scope") }
                    .disabled((focusStore?.focusedWorkspaceIDs.isEmpty ?? true) || modalActive)
                Button { actions.toggleSplit() } label: {
                    Label(library.activeStore?.activeSession?.isSplit == true ? "Hide Split" : "Split Right", systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut(shortcut(for: .toggleSplit))
                .disabled(library.activeStore?.activeSession == nil || modalActive)
                let scratchShown = library.activeStore?.activeSession?.scratchActive == true
                Button { actions.toggleScratch() } label: {
                    // static neutral icon like the Split menu item above; state is shown by the label text.
                    Label(scratchShown ? "Hide Scratch" : "Show Scratch", systemImage: "rectangle")
                }
                .keyboardShortcut(shortcut(for: .toggleScratch))
                .disabled(library.activeStore?.activeSession == nil || modalActive)
                // search the focused terminal's scrollback. data-driven shortcut (⌘F default), no hardcoded
                // literal; the bar's open/close toggle lives in onSearchStart.
                Button { actions.toggleSearch() } label: { Label("Find…", systemImage: "magnifyingglass") }
                    .keyboardShortcut(shortcut(for: .toggleSearch))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Button { actions.toggleQuickTerminal() } label: { Label("Quick Terminal", systemImage: "terminal") }
                    .keyboardShortcut(shortcut(for: .quickTerminal))
                    .disabled(modalActive)
                Button { actions.toggleTerminalZoom() } label: { Label("Toggle Terminal Zoom", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .keyboardShortcut(shortcut(for: .toggleTerminalZoom))
                Divider()
                // NO full screen item: AppKit appends its own "Enter Full Screen" (`toggleFullScreen:`,
                // Globe+F) below this menu whenever it is displayed, and nothing suppresses it — removal
                // before the injection is undone and afterwards changes only the model, since the menu is
                // already snapshotted for display; `NSFullScreenMenuItemEverywhere` is ignored on macOS 26;
                // and adopting the selector on an item of our own does not stop it either. An item here is
                // therefore a visible duplicate. The rebindable `toggle_fullscreen` chord is matched in
                // `CustomCommandRunner` instead, and the action palette still offers Toggle Full Screen.
            }
            // a dedicated Navigate menu keeps the View menu scannable: selection/focus movement between
            // sessions and split panes lives here, driving the SAME AppActions the View menu does, with the
            // control API / palette / keymap surfaces untouched.
            CommandMenu("Navigate") {
                // the File/View modal gate, mirrored.
                let zoomed = actions.terminalZoomActive
                let pickActive = actions.pickActive(for: library.activeWindowID)
                let modalActive = zoomed || (actions.frontmostDashboard?.isOpen ?? false) || pickActive
                Button { actions.toggleSessionPalette() } label: { Label("Go to Session", systemImage: "rectangle.stack") }
                    .keyboardShortcut(shortcut(for: .sessionPalette))
                    .disabled(modalActive)
                Button { actions.toggleActionPalette() } label: { Label("Command Palette", systemImage: "command") }
                    .keyboardShortcut(shortcut(for: .commandPalette))
                    .disabled(modalActive)
                Button { actions.toggleCustomCommandPalette() } label: { Label("Custom Commands", systemImage: "terminal") }
                    .keyboardShortcut(shortcut(for: .customCommandPalette))
                    .disabled(modalActive)
                Button { actions.toggleAttentionPalette() } label: { Label("Go to Attention…", systemImage: "bell") }
                    .keyboardShortcut(shortcut(for: .showAttention))
                    .disabled(modalActive)
                Button { actions.toggleDashboard() } label: { Label("Dashboard", systemImage: "rectangle.split.2x2") }
                    .keyboardShortcut(shortcut(for: .dashboard))
                    // not disabled when the dashboard itself is open: ⌘⇧D remains its close escape hatch.
                    // zoom and a topmost native picker still block the toggle.
                    .disabled(zoomed || pickActive)
                Divider()
                // step between sessions in the sidebar's flattened order. prev/next ride ⌥⌘↑/↓, NOT bare
                // ⌘+arrows (which shadow text-field caret nav in rename/palette/settings fields), and
                // complement the ⌥⌘←/→ pane focus below. first/last get no key. real menu items, so AppKit
                // menu dispatch swallows the shortcut before libghostty and nothing leaks to the shell.
                Button { actions.selectPreviousSession() } label: { Label("Previous Session", systemImage: "chevron.up") }
                    .keyboardShortcut(shortcut(for: .previousSession))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Button { actions.selectNextSession() } label: { Label("Next Session", systemImage: "chevron.down") }
                    .keyboardShortcut(shortcut(for: .nextSession))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                // step only through sessions needing attention (blocked/completed glyphs), wrapping.
                Button { actions.selectPreviousAttentionSession() } label: { Label("Previous Attention Session", systemImage: "chevron.up.circle") }
                    .keyboardShortcut(shortcut(for: .previousAttentionSession))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Button { actions.selectNextAttentionSession() } label: { Label("Next Attention Session", systemImage: "chevron.down.circle") }
                    .keyboardShortcut(shortcut(for: .nextAttentionSession))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Button { actions.selectFirstSession() } label: { Label("First Session", systemImage: "arrow.up.to.line") }
                    .keyboardShortcut(shortcut(for: .firstSession))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Button { actions.selectLastSession() } label: { Label("Last Session", systemImage: "arrow.down.to.line") }
                    .keyboardShortcut(shortcut(for: .lastSession))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Divider()
                Button { actions.focusPane(.main) } label: {
                    Label("Focus Left Pane", systemImage: "rectangle.lefthalf.filled")
                }
                .keyboardShortcut(shortcut(for: .focusLeftPane))
                .disabled(library.activeStore?.activeSession?.hasSplit != true || modalActive)
                Button { actions.focusPane(.split) } label: {
                    Label("Focus Right Pane", systemImage: "rectangle.righthalf.filled")
                }
                .keyboardShortcut(shortcut(for: .focusRightPane))
                .disabled(library.activeStore?.activeSession?.hasSplit != true || modalActive)
            }
            CommandGroup(replacing: .help) {
                Button("Developer Documentation…") {
                    if let url = URL(string: "https://agterm.com/docs#agtermctl") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Install Command Line Tool…") { CLIInstaller.run() }
                Button("Install Agent Status Hooks…") { AgentHooksInstaller.run() }
                Button("Install Agent Skill…") { SkillInstaller.run() }
            }
    }

    /// Opens the standard About panel with a clickable agterm.com link and, on release builds where
    /// `GIT_COMMIT` is baked into the bundle, the short commit in the version's parenthetical.
    private func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        let website = "https://agterm.com"
        if let url = URL(string: website) {
            options[.credits] = NSAttributedString(string: website, attributes: [
                .link: url,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ])
        }
        if let commit = Bundle.main.infoDictionary?["GitCommit"] as? String, !commit.isEmpty, commit != "unknown" {
            options[.version] = commit
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }
}
