import agtermCore
import AppKit
import SwiftUI

extension agtermApp {
    /// The active SwiftUI shortcut for a built-in action, driven by the keymap: the user override when
    /// one is `map`ped, else the action's shipped default. `nil` only for a keyless action, which stays
    /// keyless until the user maps a chord.
    /// `keymap` is `@Observable`, but SwiftUI does not rebuild the menu when it changes — it defers to the
    /// next app activation, so a reload leaves the live key equivalents stale until then.
    /// ⌘W is asserted from AppKit instead, by `AppDelegate.applyCloseSessionChord`.
    private func shortcut(for action: BuiltinAction) -> KeyboardShortcut? {
        settingsModel.keymap.equivalent(for: action).map(Self.toShortcut)
    }

    /// Map a host-free `Chord` to a SwiftUI `KeyboardShortcut`. The base key is a single printable
    /// character (`Character`) or one of the named keys the grammar allows (`tab`/`space`/`return`/
    /// `delete` and the four arrows); the modifiers map one-for-one. This is the menu-side mirror of the
    /// runner's `NSEvent`→`Chord` mapping.
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

    private func recentTitle(_ item: RecentClosedItem) -> String {
        guard let subtitle = item.subtitle, !subtitle.isEmpty else { return item.title }
        return "\(item.title) - \(subtitle)"
    }

    @CommandsBuilder
    var appCommands: some Commands {
            // App menu: replace the default "About Agterm" with one that opens the standard
            // panel enriched with a clickable repo link and, on release builds, the build commit.
            CommandGroup(replacing: .appInfo) {
                Button("About Agterm") { showAboutPanel() }
            }
            // Edit: drop SwiftUI's stock Undo/Redo. agterm registers no NSUndoManager, so they are dead for
            // the terminal, and the ⌘Z they advertise is already owned by File ▸ Reopen Closed Item
            // (`BuiltinAction.undoClose`), whose menu precedes Edit and wins the key-equivalent search — the
            // Undo item could only ever be CLICKED, never invoked by its own shortcut. The one place AppKit
            // enabled it was the sidebar's inline rename field (its field editor supplies an undo manager),
            // too narrow to justify a permanently-greyed item that duplicates another menu's shortcut.
            // The rest of the Edit menu stays stock: Cut/Copy/Paste/Delete/Select All share the `.pasteboard`
            // group, and replacing that would take ⌘C/⌘V/⌘A away from the text fields that need them.
            CommandGroup(replacing: .undoRedo) {}
            // File: replace the default "New" group with all of agterm's creation/management actions,
            // grouped by entity into three sections — Window, then Workspace, then Session. The
            // system Close / Close All commands stay below in their own group.
            CommandGroup(replacing: .newItem) {
                // While terminal zoom OR the dashboard grid is up the UI is modal (the AppActions gate already
                // no-ops these); the .disabled mirrors that gate so the items read as unavailable instead of
                // dead. modalActive folds the dashboard into the same gate so its menu key-equivalents
                // (which route through performKeyEquivalent, PAST the grid's keyDown-only key-catcher) can't
                // mutate the deck behind the grid — the Dashboard toggle itself stays zoomed-only so ⌘⇧D can
                // still close the grid.
                let zoomed = actions.terminalZoomActive
                let modalActive = zoomed || (actions.frontmostDashboard?.isOpen ?? false)
                // Window: create/open/rename/delete the top-level window bundles. Open Window lists
                // the library with a checkmark on already-open ones (picking a closed one opens it,
                // an open one raises it). Delete is disabled with one window left (keep-at-least-one).
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
                // Session. Open Directory… opens a new session rooted at a chosen folder; Close
                // Session is terminal-style ⌘W (closes the active session, or the window when none).
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
                // open keymap.conf in $EDITOR in a 95% overlay over the active session; it reloads on the
                // editor exiting. Keyless, like Reload Keymap.
                Button { actions.editKeymap() } label: { Label("Edit Keymap…", systemImage: "pencil") }
                    .disabled(modalActive)
                // re-read keymap.conf and apply (menu shortcuts re-render, the runner + palette rebuild).
                // Keyless — a future BuiltinAction could give it a default chord.
                Button { actions.reloadKeymap() } label: { Label("Reload Keymap", systemImage: "keyboard") }
                // open the agterm-scoped ghostty.conf in $EDITOR in a 95% overlay; it reloads the config on
                // the editor exiting. Keyless, like Edit Keymap.
                Button { actions.editGhosttyConfig() } label: { Label("Edit ghostty.conf…", systemImage: "slider.horizontal.3") }
                    .disabled(modalActive)
                // re-read ghostty.conf and rebroadcast to every surface; warns with a banner on a
                // malformed file. Keyless, like Reload Keymap.
                Button { actions.reloadGhosttyConfig() } label: { Label("Reload Config", systemImage: "arrow.clockwise") }
            }
            // View: font zoom (drives ghostty on the focused terminal), the status-bar toggle, and
            // split / quick terminal / palettes. The menu reserves an icon column because the system
            // "Enter Full Screen" item has an icon, so every custom item carries an SF Symbol too —
            // otherwise they render as blank, indented slots.
            CommandGroup(after: .toolbar) {
                // same modal-while-zoomed/dashboard mirror as the File group: grey out what the action gate
                // no-ops (modalActive = zoomed OR the frontmost dashboard grid open).
                let zoomed = actions.terminalZoomActive
                let modalActive = zoomed || (actions.frontmostDashboard?.isOpen ?? false)
                Button { actions.increaseFontSize() } label: { Label("Increase Font Size", systemImage: "textformat.size.larger") }
                    .keyboardShortcut(shortcut(for: .increaseFontSize))
                Button { actions.decreaseFontSize() } label: { Label("Decrease Font Size", systemImage: "textformat.size.smaller") }
                    .keyboardShortcut(shortcut(for: .decreaseFontSize))
                Button { actions.resetFontSize() } label: { Label("Actual Size", systemImage: "textformat.size") }
                    .keyboardShortcut(shortcut(for: .resetFontSize))
                // open the live-preview theme picker (the .themes palette). Keyless by default like Edit
                // Keymap; rebindable via select_theme. The control half is theme.set / theme.list.
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
                // expand every workspace / collapse all but the active one. plain (non-BuiltinAction)
                // keyless items like Reload Keymap; disabled with no active store or in flagged mode
                // (no workspace rows to expand/collapse). The control half is sidebar.expand/collapse.
                let treeMode = library.activeStore?.sidebarMode == .tree
                Button { actions.expandAllWorkspaces() } label: { Label("Expand Workspaces", systemImage: "chevron.down") }
                    .disabled(library.activeStore == nil || !treeMode || modalActive)
                Button { actions.collapseOtherWorkspaces() } label: { Label("Collapse Workspaces", systemImage: "chevron.right") }
                    .disabled(library.activeStore == nil || !treeMode || modalActive)
                // flip the sidebar between the workspace tree and the flat flagged working-set list.
                // single 2-state item like the sidebar/scratch toggles; keyless by default (rebindable
                // via toggle_flagged_view). The control half is sidebar.mode.
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
                // keyless by default (rebindable via focus_workspace). The control half is workspace.focus.
                // the label tracks the toggle (Focus/Unfocus) like the workspace row's context-menu item.
                let focusStore = library.activeStore
                Button { actions.focusActiveWorkspace() } label: {
                    Label(focusStore?.isCurrentWorkspaceSoleFocus == true ? "Unfocus Workspace" : "Focus Workspace",
                          systemImage: "scope")
                }
                .keyboardShortcut(shortcut(for: .focusWorkspace))
                .disabled(focusStore?.currentWorkspaceID == nil || modalActive)
                // the ADDITIVE sibling of Focus Workspace: mark the current workspace without dropping the
                // other members, so a working set can be built from the menu. Plain (non-BuiltinAction)
                // keyless item like Clear Focus below. The control half is workspace.focus add. Disabled
                // once the current workspace is already marked — it would be a silent no-op (the row menu
                // flips to "Remove from Focus" instead, which it can do because it has a clicked row).
                // Membership is NOT gated on the sidebar mode here or in the palette (unlike Expand/Collapse
                // Workspaces above), matching the focus siblings and the control modes.
                Button { actions.addActiveWorkspaceToFocus() } label: {
                    Label("Add Workspace to Focus", systemImage: "square.grid.2x2")
                }
                .disabled(focusStore?.currentWorkspaceID == nil
                    || focusStore?.isCurrentWorkspaceFocusMember == true || modalActive)
                // apply or suspend the filter without losing the marked set — the menu twin of the
                // bottom-bar grid toggle, disabled in the same empty-set state (the store refuses to
                // enable an empty set, so the item would be a no-op). The control half is workspace.filter.
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
                // search the focused terminal's scrollback. data-driven shortcut (⌘F default) like the
                // toggles above — no hardcoded literal; the bar's open/close toggle lives in onSearchStart.
                Button { actions.toggleSearch() } label: { Label("Find…", systemImage: "magnifyingglass") }
                    .keyboardShortcut(shortcut(for: .toggleSearch))
                    .disabled(library.activeStore?.activeSession == nil || modalActive)
                Button { actions.toggleQuickTerminal() } label: { Label("Quick Terminal", systemImage: "terminal") }
                    .keyboardShortcut(shortcut(for: .quickTerminal))
                    .disabled(modalActive)
                Button { actions.toggleTerminalZoom() } label: { Label("Toggle Terminal Zoom", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .keyboardShortcut(shortcut(for: .toggleTerminalZoom))
                Divider()
                // native macOS full screen for the key window (⌃⌘F default, rebindable). Toggles: a second
                // invocation exits. The green traffic-light button drives the same NSWindow.toggleFullScreen.
                Button { actions.toggleFullscreen() } label: {
                    Label("Toggle Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut(shortcut(for: .toggleFullscreen))
            }
            // a dedicated Navigate menu keeps the View menu scannable: moving the selection/focus between
            // existing sessions and split panes lives here — the palettes that jump to a session/command,
            // the spatial session stepping, and the pane focus. all drive the SAME AppActions the View items
            // did; only their menu home changed (the control API / palette / keymap surfaces are untouched).
            CommandMenu("Navigate") {
                // same modal-while-zoomed/dashboard mirror as the File/View groups (modalActive = zoomed OR
                // the frontmost dashboard grid open); the Dashboard toggle below stays zoomed-only.
                let zoomed = actions.terminalZoomActive
                let modalActive = zoomed || (actions.frontmostDashboard?.isOpen ?? false)
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
                Button { actions.toggleDashboard() } label: { Label("Dashboard", systemImage: "square.split.2x2") }
                    .keyboardShortcut(shortcut(for: .dashboard))
                    // stays zoomed-only, NOT modalActive: ⌘⇧D must still CLOSE an open dashboard, so this
                    // toggle is the escape hatch and is never disabled by the dashboard being open
                    // (toggleDashboard guards on !terminalZoomActive only, so it stays callable too).
                    .disabled(zoomed)
                Divider()
                // step between sessions in the sidebar's flattened order. Prev/Next ride ⌥⌘↑/↓ (NOT bare
                // ⌘+arrows, which shadow text-field caret nav in the rename/palette/settings fields); ⌥⌘↑/↓
                // sessions complements the ⌥⌘←/→ pane focus below (left/right = panes, up/down = sessions).
                // First/Last get no key (menu + palette + control only). Real menu items so AppKit menu
                // dispatch swallows the shortcut before libghostty — never leaked to the shell.
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
                    if let url = URL(string: "https://github.com/umputun/agterm#scripting-agterm") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Install Command Line Tool…") { CLIInstaller.run() }
                Button("Install Agent Status Hooks…") { AgentHooksInstaller.run() }
                Button("Install Agent Skill…") { SkillInstaller.run() }
            }
    }

    /// Opens the standard About panel, enriched with a clickable agterm.com link and — on release
    /// builds, where `GIT_COMMIT` is baked into the bundle — the short build commit shown in the
    /// version's parenthetical. Dev builds (no baked commit) fall back to the plain version.
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
