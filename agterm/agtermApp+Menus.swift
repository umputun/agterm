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
                // every item backed by a `PaletteCommand` reads `isEnabled(in:)` — the SINGLE predicate the
                // palette row and a keymap.conf alternative on the same action read too, so an item cannot
                // grow a term the other two miss. `modalActive` remains for the items with no palette row:
                // zoom, the dashboard grid or a topmost native picker covers the deck, and neither a click
                // nor a key equivalent may mutate what it hides.
                let context = actions.paletteContext
                let modalActive = context.modalActive
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
                    .disabled(!PaletteCommand.newWorkspace.isEnabled(in: context))
                Button("Rename Workspace") { actions.renameActiveWorkspace() }
                    .keyboardShortcut(shortcut(for: .renameWorkspace))
                    .disabled(!PaletteCommand.renameWorkspace.isEnabled(in: context))
                Button("Delete Workspace") { actions.deleteActiveWorkspace() }
                    .keyboardShortcut(shortcut(for: .deleteWorkspace))
                    .disabled(!PaletteCommand.deleteWorkspace.isEnabled(in: context))

                Divider()
                // Session.
                Button("New Session") { actions.newSession() }
                    .keyboardShortcut(shortcut(for: .newSession))
                    .disabled(!PaletteCommand.newSession.isEnabled(in: context))
                Button("Open Directory…") { actions.openDirectory() }
                    .keyboardShortcut(shortcut(for: .openDirectory))
                    .disabled(!PaletteCommand.openDirectory.isEnabled(in: context))
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
                    .disabled(!PaletteCommand.reopenRecent.isEnabled(in: context))
                Button("Rename Session") { actions.renameActiveSession() }
                    .keyboardShortcut(shortcut(for: .renameSession))
                    .disabled(!PaletteCommand.renameSession.isEnabled(in: context))
                Button("Duplicate Session") { actions.duplicateActiveSession() }
                    .keyboardShortcut(shortcut(for: .duplicateSession))
                    .disabled(!PaletteCommand.duplicateSession.isEnabled(in: context))
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
                    // dismiss any cover (quick terminal / overlay / scratch) or close the active session; only
                    // when it handled nothing (no cover, no session) fall back to the window.
                    actions.closeActiveSessionOrWindow(NSApp.keyWindow)
                }
                .keyboardShortcut(shortcut(for: .closeSession))
                .disabled(!PaletteCommand.closeSession.isEnabled(in: context))
                Button("Reopen Closed Item") { actions.undoClose() }
                    .disabled(!PaletteCommand.undoClose.isEnabled(in: context))
                Button("Clear Status") { actions.clearActiveSessionStatus() }
                    .keyboardShortcut(shortcut(for: .clearStatus))
                    .disabled(!PaletteCommand.clearStatus.isEnabled(in: context))
                Divider()
                // open keymap.conf in $EDITOR in a 95% overlay over the active session; reloads when the
                // editor exits. keyless, like Reload Keymap.
                Button { actions.editKeymap() } label: { Label("Edit Keymap…", systemImage: "pencil") }
                    .disabled(!PaletteCommand.editKeymap.isEnabled(in: context))
                // re-read keymap.conf and apply — menu shortcuts, runner and palette rebuild. keyless.
                Button { actions.reloadKeymap() } label: { Label("Reload Keymap", systemImage: "keyboard") }
                    .disabled(!PaletteCommand.reloadKeymap.isEnabled(in: context))
                // open the agterm-scoped ghostty.conf in $EDITOR in a 95% overlay; reloads on editor exit.
                Button { actions.editGhosttyConfig() } label: { Label("Edit ghostty.conf…", systemImage: "slider.horizontal.3") }
                    .disabled(!PaletteCommand.editGhosttyConfig.isEnabled(in: context))
                // re-read ghostty.conf and rebroadcast to every surface; banner-warns on a malformed file.
                Button { actions.reloadGhosttyConfig() } label: { Label("Reload Config", systemImage: "arrow.clockwise") }
                    .disabled(!PaletteCommand.reloadConfig.isEnabled(in: context))
            }
            // View: font zoom (on the focused terminal), the status-bar toggle, split / quick terminal /
            // palettes. Every item needs an SF Symbol: one iconless item renders as a blank, indented slot
            // beside the icon column its neighbours reserve.
            CommandGroup(after: .toolbar) {
                // the File group's predicate, mirrored. Every item here has a palette row, so none needs the
                // bare modal term.
                let context = actions.paletteContext
                Button { actions.increaseFontSize() } label: { Label("Increase Font Size", systemImage: "textformat.size.larger") }
                    .keyboardShortcut(shortcut(for: .increaseFontSize))
                    .disabled(!PaletteCommand.increaseFontSize.isEnabled(in: context))
                Button { actions.decreaseFontSize() } label: { Label("Decrease Font Size", systemImage: "textformat.size.smaller") }
                    .keyboardShortcut(shortcut(for: .decreaseFontSize))
                    .disabled(!PaletteCommand.decreaseFontSize.isEnabled(in: context))
                Button { actions.resetFontSize() } label: { Label("Actual Size", systemImage: "textformat.size") }
                    .keyboardShortcut(shortcut(for: .resetFontSize))
                    .disabled(!PaletteCommand.resetFontSize.isEnabled(in: context))
                // open the live-preview theme picker (the .themes palette). keyless by default, rebindable
                // via select_theme; the control half is theme.set / theme.list.
                Button { actions.openThemePalette() } label: { Label("Select Theme…", systemImage: "paintpalette") }
                    .keyboardShortcut(shortcut(for: .selectTheme))
                    .disabled(!PaletteCommand.selectTheme.isEnabled(in: context))
                Divider()
                let sidebarShown = library.activeStore?.sidebarVisible ?? true
                Button { actions.toggleSidebar() } label: {
                    Label(sidebarShown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut(shortcut(for: .toggleSidebar))
                .disabled(!PaletteCommand.toggleSidebar.isEnabled(in: context))
                // expand every workspace / collapse all but the active one. plain keyless items, disabled
                // outside tree mode, where there are no workspace rows; control sidebar.expand/collapse.
                Button { actions.expandAllWorkspaces() } label: { Label("Expand Workspaces", systemImage: "chevron.down") }
                    .disabled(!PaletteCommand.expandWorkspaces.isEnabled(in: context))
                Button { actions.collapseOtherWorkspaces() } label: { Label("Collapse Workspaces", systemImage: "chevron.right") }
                    .disabled(!PaletteCommand.collapseWorkspaces.isEnabled(in: context))
                // fold the current workspace alone — the one row the two items above never fold, since
                // Collapse Workspaces keeps it open. keyless, rebindable via toggle_workspace_collapse;
                // control workspace.collapse/.expand. the label tracks the toggle.
                Button { actions.toggleActiveWorkspaceCollapse() } label: {
                    Label(PaletteCommand.toggleWorkspaceCollapse.title(in: context),
                          systemImage: context.activeWorkspaceCollapsed ? "chevron.down.square" : "chevron.right.square")
                }
                .keyboardShortcut(shortcut(for: .toggleWorkspaceCollapse))
                .disabled(!PaletteCommand.toggleWorkspaceCollapse.isEnabled(in: context))
                // flip the sidebar between the workspace tree and the flat flagged working-set list. one
                // 2-state item, keyless by default (rebindable via toggle_flagged_view); control sidebar.mode.
                // Disabled with nothing to show (tree mode + no flags), live in flagged mode so it can
                // always switch back to the tree.
                let flaggedMode = library.activeStore?.sidebarMode == .flagged
                Button { actions.toggleFlaggedView() } label: {
                    Label(flaggedMode ? "Show All Sessions" : "Show Flagged Sessions", systemImage: "flag")
                }
                .keyboardShortcut(shortcut(for: .toggleFlaggedView))
                .disabled(!PaletteCommand.toggleFlaggedView.isEnabled(in: context))
                let sessionFlagged = library.activeStore?.activeSession?.flagged == true
                Button { actions.toggleFlagActiveSession() } label: {
                    Label(sessionFlagged ? "Unflag Session" : "Flag Session", systemImage: "flag.badge.ellipsis")
                }
                .keyboardShortcut(shortcut(for: .toggleFlag))
                .disabled(!PaletteCommand.toggleFlag.isEnabled(in: context))
                Button { actions.clearFlags() } label: { Label("Clear Flagged", systemImage: "flag.slash") }
                    .disabled(!PaletteCommand.clearFlagged.isEnabled(in: context))
                // collapse the tree to the current workspace's subtree (or unfocus when already focused).
                // keyless, rebindable via focus_workspace; control workspace.focus. the label tracks the toggle.
                let focusStore = library.activeStore
                Button { actions.focusActiveWorkspace() } label: {
                    Label(focusStore?.isCurrentWorkspaceSoleFocus == true ? "Unfocus Workspace" : "Focus Workspace",
                          systemImage: "scope")
                }
                .keyboardShortcut(shortcut(for: .focusWorkspace))
                .disabled(!PaletteCommand.focusWorkspace.isEnabled(in: context))
                // the ADDITIVE sibling of Focus Workspace: mark the current workspace without dropping the
                // other members, so a working set can be built from the menu. plain keyless item; control
                // workspace.focus add. disabled once the workspace is marked, where it would be a silent
                // no-op (the row menu flips to "Remove from Focus", having a clicked row). membership is
                // NOT gated on sidebar mode here or in the palette, matching its focus siblings.
                Button { actions.addActiveWorkspaceToFocus() } label: {
                    Label("Add Workspace to Focus", systemImage: "square.grid.2x2")
                }
                .disabled(!PaletteCommand.addWorkspaceToFocus.isEnabled(in: context))
                // apply or suspend the filter without losing the marked set — the menu twin of the bottom-bar
                // grid toggle, disabled on an empty set (the store refuses one); control workspace.filter.
                Button { actions.toggleFocusFilter() } label: {
                    Label("Toggle Workspace Filter", systemImage: "square.grid.2x2")
                }
                .keyboardShortcut(shortcut(for: .toggleWorkspaceFilter))
                .disabled(!PaletteCommand.toggleWorkspaceFilter.isEnabled(in: context))
                // plain (non-BuiltinAction) clear, like Clear Flagged; the bottom-bar toggle is primary.
                Button { actions.clearFocus() } label: { Label("Clear Focus", systemImage: "scope") }
                    .disabled(!PaletteCommand.clearFocus.isEnabled(in: context))
                Button { actions.toggleSplit() } label: {
                    Label("Toggle Vertical Split", systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut(shortcut(for: .toggleSplit))
                .disabled(!PaletteCommand.toggleSplit.isEnabled(in: context))
                Button { actions.toggleHorizontalSplit() } label: {
                    Label("Toggle Horizontal Split", systemImage: "rectangle.split.1x2")
                }
                .keyboardShortcut(shortcut(for: .toggleHorizontalSplit))
                .disabled(!PaletteCommand.toggleHorizontalSplit.isEnabled(in: context))
                let scratchShown = library.activeStore?.activeSession?.scratchActive == true
                Button { actions.toggleScratch() } label: {
                    // static neutral icon like the Split menu item above; state is shown by the label text.
                    Label(scratchShown ? "Hide Scratch" : "Show Scratch", systemImage: "rectangle")
                }
                .keyboardShortcut(shortcut(for: .toggleScratch))
                .disabled(!PaletteCommand.toggleScratch.isEnabled(in: context))
                // search the focused terminal's scrollback. data-driven shortcut (⌘F default), no hardcoded
                // literal; the bar's open/close toggle lives in onSearchStart.
                Button { actions.toggleSearch() } label: { Label("Find…", systemImage: "magnifyingglass") }
                    .keyboardShortcut(shortcut(for: .toggleSearch))
                    .disabled(!PaletteCommand.find.isEnabled(in: context))
                Button { actions.toggleQuickTerminal() } label: { Label("Quick Terminal", systemImage: "terminal") }
                    .keyboardShortcut(shortcut(for: .quickTerminal))
                    .disabled(!PaletteCommand.quickTerminal.isEnabled(in: context))
                Button { actions.toggleTerminalZoom() } label: { Label("Toggle Terminal Zoom", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .keyboardShortcut(shortcut(for: .toggleTerminalZoom))
                    .disabled(!PaletteCommand.toggleTerminalZoom.isEnabled(in: context))
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
                // the File/View predicate and modal gate, mirrored.
                let context = actions.paletteContext
                let modalActive = context.modalActive
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
                    .disabled(!PaletteCommand.showAttention.isEnabled(in: context))
                Button { actions.toggleDashboard() } label: { Label("Dashboard", systemImage: "rectangle.split.2x2") }
                    .keyboardShortcut(shortcut(for: .dashboard))
                    // the predicate spares this one the dashboard's own term: its shortcut stays the open grid's
                    // close escape hatch, while zoom and a topmost native picker still block the toggle.
                    .disabled(!PaletteCommand.dashboard.isEnabled(in: context))
                Divider()
                // step between sessions in the sidebar's flattened order. prev/next ride ⌥⌘↑/↓, NOT bare
                // ⌘+arrows (which shadow text-field caret nav in rename/palette/settings fields), and
                // complement the ⌥⌘←/→ pane focus below. first/last get no key. real menu items, so AppKit
                // menu dispatch swallows the shortcut before libghostty and nothing leaks to the shell.
                Button { actions.selectPreviousSession() } label: { Label("Previous Session", systemImage: "chevron.up") }
                    .keyboardShortcut(shortcut(for: .previousSession))
                    .disabled(!PaletteCommand.previousSession.isEnabled(in: context))
                Button { actions.selectNextSession() } label: { Label("Next Session", systemImage: "chevron.down") }
                    .keyboardShortcut(shortcut(for: .nextSession))
                    .disabled(!PaletteCommand.nextSession.isEnabled(in: context))
                // step only through sessions needing attention (blocked/completed glyphs), wrapping.
                Button { actions.selectPreviousAttentionSession() } label: { Label("Previous Attention Session", systemImage: "chevron.up.circle") }
                    .keyboardShortcut(shortcut(for: .previousAttentionSession))
                    .disabled(!PaletteCommand.previousAttentionSession.isEnabled(in: context))
                Button { actions.selectNextAttentionSession() } label: { Label("Next Attention Session", systemImage: "chevron.down.circle") }
                    .keyboardShortcut(shortcut(for: .nextAttentionSession))
                    .disabled(!PaletteCommand.nextAttentionSession.isEnabled(in: context))
                Button { actions.selectFirstSession() } label: { Label("First Session", systemImage: "arrow.up.to.line") }
                    .keyboardShortcut(shortcut(for: .firstSession))
                    .disabled(!PaletteCommand.firstSession.isEnabled(in: context))
                Button { actions.selectLastSession() } label: { Label("Last Session", systemImage: "arrow.down.to.line") }
                    .keyboardShortcut(shortcut(for: .lastSession))
                    .disabled(!PaletteCommand.lastSession.isEnabled(in: context))
                // step between WORKSPACES, landing on each one's first session. keyless, rebindable via
                // previous_workspace/next_workspace; control workspace.go. tree mode only, like the
                // expansion items in View — flagged mode renders no workspace rows to step through.
                Button { actions.selectPreviousWorkspace() } label: {
                    Label("Previous Workspace", systemImage: "chevron.up.2")
                }
                .keyboardShortcut(shortcut(for: .previousWorkspace))
                .disabled(!PaletteCommand.previousWorkspace.isEnabled(in: context))
                Button { actions.selectNextWorkspace() } label: {
                    Label("Next Workspace", systemImage: "chevron.down.2")
                }
                .keyboardShortcut(shortcut(for: .nextWorkspace))
                .disabled(!PaletteCommand.nextWorkspace.isEnabled(in: context))
                Divider()
                let topBottom = library.activeStore?.activeSession?.splitAxis == .topBottom
                Button { actions.focusPane(.main) } label: {
                    Label(topBottom ? "Focus Top Pane" : "Focus Left Pane",
                          systemImage: topBottom ? "rectangle.tophalf.filled" : "rectangle.lefthalf.filled")
                }
                .keyboardShortcut(shortcut(for: .focusLeftPane))
                .disabled(!PaletteCommand.focusLeftPane.isEnabled(in: context))
                Button { actions.focusPane(.split) } label: {
                    Label(topBottom ? "Focus Bottom Pane" : "Focus Right Pane",
                          systemImage: topBottom ? "rectangle.bottomhalf.filled" : "rectangle.righthalf.filled")
                }
                .keyboardShortcut(shortcut(for: .focusRightPane))
                .disabled(!PaletteCommand.focusRightPane.isEnabled(in: context))
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
