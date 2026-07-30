import Testing
@testable import agtermCore

struct PaletteCatalogTests {
    @Test func titlesMatchThePaletteSourceOrder() {
        #expect(PaletteCommand.allCases.map(\.title) == [
            "New Session",
            "New Workspace",
            "Open Directory…",
            "Rename Session",
            "Duplicate Session",
            "Rename Workspace",
            "Close Session",
            "Reopen Last Closed Item",
            "Reopen Closed Item",
            "Clear Status",
            "Previous Session",
            "Next Session",
            "Previous Attention Session",
            "Next Attention Session",
            "First Session",
            "Last Session",
            "Show Attention",
            "Toggle Split",
            "Toggle Scratch",
            "Toggle Terminal Zoom",
            "Toggle Sidebar",
            "Flag Session",
            "Focus Workspace",
            "Find…",
            "Quick Terminal",
            "Dashboard",
            "Toggle Full Screen",
            "Increase Font Size",
            "Decrease Font Size",
            "Actual Font Size",
            "Select Theme…",
            "Edit Keymap",
            "Reload Keymap",
            "Edit ghostty.conf",
            "Reload Config",
            "Delete Workspace",
            "Show Flagged Sessions",
            "Clear Flagged",
            "Clear Focus",
            "Add Workspace to Focus",
            "Toggle Workspace Filter",
            "Expand Workspaces",
            "Collapse Workspaces",
            "Focus Left Pane",
            "Focus Right Pane",
        ])
    }

    @Test func catalogHasTheExpectedStaticCommandCount() {
        #expect(PaletteCommand.allCases.count == 45)
    }

    @Test func idsRoundTripThroughRawValue() {
        for command in PaletteCommand.allCases {
            #expect(PaletteCommand(rawValue: command.rawValue) == command)
        }
    }

    @Test func contextTitlesMatchToggleState() {
        #expect(PaletteCommand.toggleFlag.title(in: PaletteContext(activeSessionFlagged: false)) == "Flag Session")
        #expect(PaletteCommand.toggleFlag.title(in: PaletteContext(activeSessionFlagged: true)) == "Unflag Session")
        #expect(PaletteCommand.toggleFlaggedView.title(in: PaletteContext(sidebarShowsFlaggedOnly: false)) == "Show Flagged Sessions")
        #expect(PaletteCommand.toggleFlaggedView.title(in: PaletteContext(sidebarShowsFlaggedOnly: true)) == "Show All Sessions")
    }

    @Test func clearFlaggedVisibleOnlyWhenSomethingIsFlagged() {
        #expect(!PaletteCommand.clearFlagged.isVisible(in: PaletteContext(hasFlaggedSessions: false)))
        #expect(PaletteCommand.clearFlagged.isVisible(in: PaletteContext(hasFlaggedSessions: true)))
    }

    @Test func flaggedToggleVisibleWithFlagsOrWhileAlreadyInFlaggedView() {
        #expect(!PaletteCommand.toggleFlaggedView.isVisible(in: PaletteContext()))
        #expect(PaletteCommand.toggleFlaggedView.isVisible(in: PaletteContext(hasFlaggedSessions: true)))
        #expect(PaletteCommand.toggleFlaggedView.isVisible(in: PaletteContext(sidebarShowsFlaggedOnly: true)))
    }

    @Test func treeExpansionCommandsShowOnlyInWorkspaceTreeMode() {
        #expect(PaletteCommand.expandWorkspaces.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: true)))
        #expect(PaletteCommand.collapseWorkspaces.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: true)))
        #expect(!PaletteCommand.expandWorkspaces.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: false)))
        #expect(!PaletteCommand.collapseWorkspaces.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: false)))
    }

    @Test func workspaceAndSplitCommandsFollowTheirPredicates() {
        #expect(!PaletteCommand.deleteWorkspace.isVisible(in: PaletteContext(canRemoveWorkspace: false)))
        #expect(PaletteCommand.deleteWorkspace.isVisible(in: PaletteContext(canRemoveWorkspace: true)))
        #expect(!PaletteCommand.clearFocus.isVisible(in: PaletteContext(hasMarkedWorkspaces: false)))
        #expect(PaletteCommand.clearFocus.isVisible(in: PaletteContext(hasMarkedWorkspaces: true)))
        #expect(!PaletteCommand.focusLeftPane.isVisible(in: PaletteContext(activeSessionHasSplit: false)))
        #expect(PaletteCommand.focusRightPane.isVisible(in: PaletteContext(activeSessionHasSplit: true)))
        #expect(!PaletteCommand.undoClose.isVisible(in: PaletteContext(hasPendingClose: false)))
        #expect(PaletteCommand.undoClose.isVisible(in: PaletteContext(hasPendingClose: true)))
        #expect(!PaletteCommand.reopenRecent.isVisible(in: PaletteContext(hasRecentClosed: false)))
        #expect(PaletteCommand.reopenRecent.isVisible(in: PaletteContext(hasRecentClosed: true)))
    }

    @Test func workspaceFocusEntriesFollowTheMarkedSet() {
        // membership is model state the tree applies as soon as it is shown, so marking is offered in
        // EITHER mode; the entry targets `currentWorkspaceID`, so on a member it would be a silent no-op.
        let tree = PaletteContext(sidebarShowsWorkspaceTree: true)
        let flagged = PaletteContext(sidebarShowsFlaggedOnly: true)
        #expect(PaletteCommand.addWorkspaceToFocus.isVisible(in: tree))
        #expect(PaletteCommand.addWorkspaceToFocus.isVisible(in: flagged))
        #expect(!PaletteCommand.addWorkspaceToFocus.isVisible(
            in: PaletteContext(sidebarShowsWorkspaceTree: true, activeWorkspaceMarked: true)))
        #expect(!PaletteCommand.addWorkspaceToFocus.isVisible(
            in: PaletteContext(sidebarShowsFlaggedOnly: true, activeWorkspaceMarked: true)))
        #expect(PaletteCommand.addWorkspaceToFocus.isVisible(
            in: PaletteContext(sidebarShowsWorkspaceTree: true, hasMarkedWorkspaces: true)))
        // the same empty-set rule the bottom-bar toggle renders as disabled.
        #expect(!PaletteCommand.toggleWorkspaceFilter.isVisible(in: PaletteContext(hasMarkedWorkspaces: false)))
        #expect(PaletteCommand.toggleWorkspaceFilter.isVisible(in: PaletteContext(hasMarkedWorkspaces: true)))
        // both titles are static — the marked set is read off the sidebar, not the palette row.
        #expect(PaletteCommand.addWorkspaceToFocus.title(in: tree) == "Add Workspace to Focus")
        #expect(PaletteCommand.toggleWorkspaceFilter.title(in: PaletteContext(hasMarkedWorkspaces: true)) == "Toggle Workspace Filter")
    }

    @Test func builtinMappingsCoverRebindableCommands() {
        #expect(PaletteCommand.newSession.builtinAction == .newSession)
        #expect(PaletteCommand.find.builtinAction == .toggleSearch)
        #expect(PaletteCommand.toggleTerminalZoom.builtinAction == .toggleTerminalZoom)
        #expect(PaletteCommand.resetFontSize.builtinAction == .resetFontSize)
        #expect(PaletteCommand.dashboard.builtinAction == .dashboard)
        #expect(PaletteCommand.reopenRecent.builtinAction == .reopenRecent)
        #expect(PaletteCommand.undoClose.builtinAction == .undoClose)
        #expect(PaletteCommand.toggleWorkspaceFilter.builtinAction == .toggleWorkspaceFilter)
        #expect(PaletteCommand.clearFlagged.builtinAction == nil)
        #expect(PaletteCommand.addWorkspaceToFocus.builtinAction == nil)
        #expect(PaletteCommand.expandWorkspaces.builtinAction == nil)
    }
}
