import Testing
@testable import agtermCore

struct PaletteCatalogTests {
    @Test func titlesMatchThePaletteSourceOrder() {
        #expect(PaletteCommand.allCases.map(\.title) == [
            "New Session",
            "New Workspace",
            "Open Directory…",
            "Rename Session",
            "Rename Workspace",
            "Close Session",
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
            "Toggle Sidebar",
            "Flag Session",
            "Focus Workspace",
            "Find…",
            "Quick Terminal",
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
            "Expand Workspaces",
            "Collapse Workspaces",
            "Focus Left Pane",
            "Focus Right Pane",
        ])
    }

    @Test func catalogHasTheExpectedStaticCommandCount() {
        #expect(PaletteCommand.allCases.count == 37)
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
        #expect(!PaletteCommand.clearFocus.isVisible(in: PaletteContext(hasFocusedWorkspace: false)))
        #expect(PaletteCommand.clearFocus.isVisible(in: PaletteContext(hasFocusedWorkspace: true)))
        #expect(!PaletteCommand.focusLeftPane.isVisible(in: PaletteContext(activeSessionHasSplit: false)))
        #expect(PaletteCommand.focusRightPane.isVisible(in: PaletteContext(activeSessionHasSplit: true)))
    }

    @Test func builtinMappingsCoverRebindableCommands() {
        #expect(PaletteCommand.newSession.builtinAction == .newSession)
        #expect(PaletteCommand.find.builtinAction == .toggleSearch)
        #expect(PaletteCommand.resetFontSize.builtinAction == .resetFontSize)
        #expect(PaletteCommand.clearFlagged.builtinAction == nil)
        #expect(PaletteCommand.expandWorkspaces.builtinAction == nil)
    }
}
