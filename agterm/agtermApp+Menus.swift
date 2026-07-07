import agtermCore
import AppKit
import SwiftUI

extension agtermApp {
    /// The active SwiftUI shortcut for a built-in action, driven by the keymap: the user override when
    /// one is `map`ped, else the action's shipped default. `nil` when neither exists (a keyless action,
    /// or one of the four arrow-bound actions whose default can't round-trip through the keymap grammar)
    /// — the menu drops the shortcut for those (the arrow actions supply their own hardcoded fallback).
    /// Because `keymap` is `@Observable`, reading it here re-renders the menu shortcut on a reload.
    private func shortcut(for action: BuiltinAction) -> KeyboardShortcut? {
        settingsModel.keymap.equivalent(for: action).map(Self.toShortcut)
    }

    /// The shortcut for one of the six arrow-bound actions: the user override when `map`ped, else the
    /// hardcoded arrow default. Those defaults can't round-trip through the keymap grammar (`parseKeybind`
    /// has no arrow keys), so `defaultChord` is nil and the fallback lives here in one place — keyed by
    /// action so every arrow call site reads uniformly and the fallback set has a single home.
    private func arrowShortcut(for action: BuiltinAction) -> KeyboardShortcut {
        if let override = shortcut(for: action) { return override }
        switch action {
        case .focusLeftPane: return KeyboardShortcut(.leftArrow, modifiers: [.command, .option])
        case .focusRightPane: return KeyboardShortcut(.rightArrow, modifiers: [.command, .option])
        case .previousSession: return KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .nextSession: return KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .previousAttentionSession: return KeyboardShortcut(.upArrow, modifiers: [.control, .option])
        case .nextAttentionSession: return KeyboardShortcut(.downArrow, modifiers: [.control, .option])
        default: return KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
    }

    /// Map a host-free `Chord` to a SwiftUI `KeyboardShortcut`. The base key is a single printable
    /// character (`Character`) or one of the named keys the grammar allows (`tab`/`space`/`return`/
    /// `delete`); the modifiers map one-for-one. This is the menu-side mirror of the runner's
    /// `NSEvent`→`Chord` mapping.
    private static func toShortcut(_ chord: Chord) -> KeyboardShortcut {
        let key: KeyEquivalent
        switch chord.key {
        case "tab": key = .tab
        case "space": key = .space
        case "return": key = .return
        case "delete": key = .delete
        default: key = KeyEquivalent(Character(chord.key))
        }
        var modifiers: EventModifiers = []
        if chord.mods.contains(.control) { modifiers.insert(.control) }
        if chord.mods.contains(.command) { modifiers.insert(.command) }
        if chord.mods.contains(.option) { modifiers.insert(.option) }
        if chord.mods.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    @CommandsBuilder
    var appCommands: some Commands {
            // App menu: replace the default "About Agterm" with one that opens the standard
            // panel enriched with a clickable repo link and, on release builds, the build commit.
            CommandGroup(replacing: .appInfo) {
                Button("About Agterm") { showAboutPanel() }
            }
            // File: replace the default "New" group with all of agterm's creation/management actions,
            // grouped by entity into three sections — Window, then Workspace, then Session. The
            // system Close / Close All commands stay below in their own group.
            CommandGroup(replacing: .newItem) {
                // Window: create/open/rename/delete the top-level window bundles. Open Window lists
                // the library with a checkmark on already-open ones (picking a closed one opens it,
                // an open one raises it). Delete is disabled with one window left (keep-at-least-one).
                Button("New Window") { actions.newWindow() }
                    .keyboardShortcut(shortcut(for: .newWindow))
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
                Button("Rename Window…") { actions.renameActiveWindow() }
                    .keyboardShortcut(shortcut(for: .renameWindow))
                Button("Delete Window") { actions.deleteActiveWindow() }
                    .keyboardShortcut(shortcut(for: .deleteWindow))
                    .disabled(!library.canRemoveWindow)

                Divider()
                // Workspace.
                Button("New Workspace") { actions.newWorkspace() }
                    .keyboardShortcut(shortcut(for: .newWorkspace))
                Button("Rename Workspace") { actions.renameActiveWorkspace() }
                    .keyboardShortcut(shortcut(for: .renameWorkspace))
                    .disabled(library.activeStore?.currentWorkspaceID == nil)
                Button("Delete Workspace") { actions.deleteActiveWorkspace() }
                    .keyboardShortcut(shortcut(for: .deleteWorkspace))
                    .disabled(library.activeStore?.canRemoveWorkspace != true)

                Divider()
                // Session. Open Directory… opens a new session rooted at a chosen folder; Close
                // Session is terminal-style ⌘W (closes the active session, or the window when none).
                Button("New Session") { actions.newSession() }
                    .keyboardShortcut(shortcut(for: .newSession))
                Button("Open Directory…") { actions.openDirectory() }
                    .keyboardShortcut(shortcut(for: .openDirectory))
                Button("Rename Session") { actions.renameActiveSession() }
                    .keyboardShortcut(shortcut(for: .renameSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button("Close Session") {
                    // closeActiveSession dismisses any cover (quick terminal / overlay / scratch) or closes the
                    // active session; only when it handled nothing (no cover, no session) fall back to the window.
                    if !actions.closeActiveSession() { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut(shortcut(for: .closeSession))
                Button("Clear Status") { actions.clearActiveSessionStatus() }
                    .keyboardShortcut(shortcut(for: .clearStatus))
                    .disabled(library.activeStore?.activeSession == nil)
                Divider()
                // open keymap.conf in $EDITOR in a 95% overlay over the active session; it reloads on the
                // editor exiting. Keyless, like Reload Keymap.
                Button { actions.editKeymap() } label: { Label("Edit Keymap…", systemImage: "pencil") }
                // re-read keymap.conf and apply (menu shortcuts re-render, the runner + palette rebuild).
                // Keyless — a future BuiltinAction could give it a default chord.
                Button { actions.reloadKeymap() } label: { Label("Reload Keymap", systemImage: "keyboard") }
                // open the agterm-scoped ghostty.conf in $EDITOR in a 95% overlay; it reloads the config on
                // the editor exiting. Keyless, like Edit Keymap.
                Button { actions.editGhosttyConfig() } label: { Label("Edit ghostty.conf…", systemImage: "slider.horizontal.3") }
                // re-read ghostty.conf and rebroadcast to every surface; warns with a banner on a
                // malformed file. Keyless, like Reload Keymap.
                Button { actions.reloadGhosttyConfig() } label: { Label("Reload Config", systemImage: "arrow.clockwise") }
            }
            // View: font zoom (drives ghostty on the focused terminal), the status-bar toggle, and
            // split / quick terminal / palettes. The menu reserves an icon column because the system
            // "Enter Full Screen" item has an icon, so every custom item carries an SF Symbol too —
            // otherwise they render as blank, indented slots.
            CommandGroup(after: .toolbar) {
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
                Divider()
                let sidebarShown = library.activeStore?.sidebarVisible ?? true
                Button { actions.toggleSidebar() } label: {
                    Label(sidebarShown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut(shortcut(for: .toggleSidebar))
                // expand every workspace / collapse all but the active one. plain (non-BuiltinAction)
                // keyless items like Reload Keymap; disabled with no active store or in flagged mode
                // (no workspace rows to expand/collapse). The control half is sidebar.expand/collapse.
                let treeMode = library.activeStore?.sidebarMode == .tree
                Button { actions.expandAllWorkspaces() } label: { Label("Expand Workspaces", systemImage: "chevron.down") }
                    .disabled(library.activeStore == nil || !treeMode)
                Button { actions.collapseOtherWorkspaces() } label: { Label("Collapse Workspaces", systemImage: "chevron.right") }
                    .disabled(library.activeStore == nil || !treeMode)
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
                .disabled(noFlaggedToShow)
                let sessionFlagged = library.activeStore?.activeSession?.flagged == true
                Button { actions.toggleFlagActiveSession() } label: {
                    Label(sessionFlagged ? "Unflag Session" : "Flag Session", systemImage: "flag.badge.ellipsis")
                }
                .keyboardShortcut(shortcut(for: .toggleFlag))
                .disabled(library.activeStore?.activeSession == nil)
                Button { actions.clearFlags() } label: { Label("Clear Flagged", systemImage: "flag.slash") }
                    .disabled(library.activeStore?.flaggedSessions.isEmpty ?? true)
                // collapse the tree to the current workspace's subtree (or unfocus when already focused).
                // keyless by default (rebindable via focus_workspace). The control half is workspace.focus.
                // the label tracks the toggle (Focus/Unfocus) like the workspace row's context-menu item.
                let focusStore = library.activeStore
                let currentFocused = focusStore?.focusedWorkspace?.id == focusStore?.currentWorkspaceID
                Button { actions.focusActiveWorkspace() } label: {
                    Label(currentFocused ? "Unfocus Workspace" : "Focus Workspace", systemImage: "scope")
                }
                .keyboardShortcut(shortcut(for: .focusWorkspace))
                .disabled(library.activeStore?.currentWorkspaceID == nil)
                // plain (non-BuiltinAction) clear, like Clear Flagged; the bottom-bar pill ✕ is primary.
                Button { actions.clearFocus() } label: { Label("Clear Focus", systemImage: "scope") }
                    .disabled(library.activeStore?.focusedWorkspaceID == nil)
                Button { actions.toggleSplit() } label: {
                    Label(library.activeStore?.activeSession?.isSplit == true ? "Hide Split" : "Split Right", systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut(shortcut(for: .toggleSplit))
                .disabled(library.activeStore?.activeSession == nil)
                let scratchShown = library.activeStore?.activeSession?.scratchActive == true
                Button { actions.toggleScratch() } label: {
                    // static neutral icon like the Split menu item above; state is shown by the label text.
                    Label(scratchShown ? "Hide Scratch" : "Show Scratch", systemImage: "rectangle")
                }
                .keyboardShortcut(shortcut(for: .toggleScratch))
                .disabled(library.activeStore?.activeSession == nil)
                // search the focused terminal's scrollback. data-driven shortcut (⌘F default) like the
                // toggles above — no hardcoded literal; the bar's open/close toggle lives in onSearchStart.
                Button { actions.toggleSearch() } label: { Label("Find…", systemImage: "magnifyingglass") }
                    .keyboardShortcut(shortcut(for: .toggleSearch))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.toggleQuickTerminal() } label: { Label("Quick Terminal", systemImage: "terminal") }
                    .keyboardShortcut(shortcut(for: .quickTerminal))
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
                Button { palette.toggle(.sessions) } label: { Label("Go to Session", systemImage: "rectangle.stack") }
                    .keyboardShortcut(shortcut(for: .sessionPalette))
                Button { palette.toggle(.actions) } label: { Label("Command Palette", systemImage: "command") }
                    .keyboardShortcut(shortcut(for: .commandPalette))
                Button { palette.toggle(.customCommands) } label: { Label("Custom Commands", systemImage: "terminal") }
                    .keyboardShortcut(shortcut(for: .customCommandPalette))
                Button { actions.toggleAttentionPalette() } label: { Label("Go to Attention…", systemImage: "bell") }
                    .keyboardShortcut(shortcut(for: .showAttention))
                Divider()
                // step between sessions in the sidebar's flattened order. Prev/Next ride ⌥⌘↑/↓ (NOT bare
                // ⌘+arrows, which shadow text-field caret nav in the rename/palette/settings fields); ⌥⌘↑/↓
                // sessions complements the ⌥⌘←/→ pane focus below (left/right = panes, up/down = sessions).
                // First/Last get no key (menu + palette + control only). Real menu items so AppKit menu
                // dispatch swallows the shortcut before libghostty — never leaked to the shell.
                Button { actions.selectPreviousSession() } label: { Label("Previous Session", systemImage: "chevron.up") }
                    .keyboardShortcut(arrowShortcut(for: .previousSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.selectNextSession() } label: { Label("Next Session", systemImage: "chevron.down") }
                    .keyboardShortcut(arrowShortcut(for: .nextSession))
                    .disabled(library.activeStore?.activeSession == nil)
                // step only through sessions needing attention (blocked/completed glyphs), wrapping. ⌃⌥↑/↓
                // are arrow-bound like the session nav above, so they ride arrowShortcut's hardcoded fallback.
                Button { actions.selectPreviousAttentionSession() } label: { Label("Previous Attention Session", systemImage: "chevron.up.circle") }
                    .keyboardShortcut(arrowShortcut(for: .previousAttentionSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.selectNextAttentionSession() } label: { Label("Next Attention Session", systemImage: "chevron.down.circle") }
                    .keyboardShortcut(arrowShortcut(for: .nextAttentionSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.selectFirstSession() } label: { Label("First Session", systemImage: "arrow.up.to.line") }
                    .keyboardShortcut(shortcut(for: .firstSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Button { actions.selectLastSession() } label: { Label("Last Session", systemImage: "arrow.down.to.line") }
                    .keyboardShortcut(shortcut(for: .lastSession))
                    .disabled(library.activeStore?.activeSession == nil)
                Divider()
                // arrow-bound actions: their default ⌘⌥←/→ can't round-trip through the keymap grammar
                // (parseKeybind has no arrow keys), so defaultChord is nil and the hardcoded arrow is the
                // FALLBACK — a user override (a parseable chord) wins. arrowShortcut(for:) owns the four
                // fallbacks in one place.
                Button { actions.focusPane(.main) } label: {
                    Label("Focus Left Pane", systemImage: "rectangle.lefthalf.filled")
                }
                .keyboardShortcut(arrowShortcut(for: .focusLeftPane))
                .disabled(library.activeStore?.activeSession?.hasSplit != true)
                Button { actions.focusPane(.split) } label: {
                    Label("Focus Right Pane", systemImage: "rectangle.righthalf.filled")
                }
                .keyboardShortcut(arrowShortcut(for: .focusRightPane))
                .disabled(library.activeStore?.activeSession?.hasSplit != true)
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
