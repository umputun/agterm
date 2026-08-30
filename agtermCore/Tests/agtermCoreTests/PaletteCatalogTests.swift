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
            "Previous Workspace",
            "Next Workspace",
            "First Session",
            "Last Session",
            "Show Attention",
            "Toggle Vertical Split",
            "Toggle Horizontal Split",
            "Close Split",
            "Swap Panes",
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
            "Collapse Workspace",
            "Focus Left Pane",
            "Focus Right Pane",
        ])
    }

    @Test func catalogHasTheExpectedStaticCommandCount() {
        #expect(PaletteCommand.allCases.count == 51)
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
        #expect(PaletteCommand.focusLeftPane.title(in: PaletteContext(activeSplitAxis: .topBottom)) == "Focus Top Pane")
        #expect(PaletteCommand.focusRightPane.title(in: PaletteContext(activeSplitAxis: .topBottom)) == "Focus Bottom Pane")
        #expect(PaletteCommand.toggleWorkspaceCollapse.title(in: PaletteContext(activeWorkspaceCollapsed: false)) == "Collapse Workspace")
        #expect(PaletteCommand.toggleWorkspaceCollapse.title(in: PaletteContext(activeWorkspaceCollapsed: true)) == "Expand Workspace")
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
        for command in [PaletteCommand.toggleWorkspaceCollapse, .previousWorkspace, .nextWorkspace] {
            #expect(command.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: true)))
            #expect(!command.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: false)))
            #expect(!command.isEnabled(in: PaletteContext(sidebarShowsWorkspaceTree: true, hasCurrentWorkspace: false)))
        }
    }

    // a step below two visible workspaces cannot move, and `isEnabled` is the single run-now predicate, so
    // it has to say so rather than leaving a live item that no-ops. Folding one workspace still works.
    @Test func workspaceStepsDisableWithNowhereToStep() {
        let alone = PaletteContext(sidebarShowsWorkspaceTree: true, canStepWorkspaces: false, hasCurrentWorkspace: true)
        let several = PaletteContext(sidebarShowsWorkspaceTree: true, canStepWorkspaces: true, hasCurrentWorkspace: true)
        for command in [PaletteCommand.previousWorkspace, .nextWorkspace] {
            #expect(!command.isEnabled(in: alone))
            #expect(command.isEnabled(in: several))
            #expect(command.isVisible(in: alone), "still listed, just inert")
        }
        #expect(PaletteCommand.toggleWorkspaceCollapse.isEnabled(in: alone))
    }

    @Test func workspaceAndSplitCommandsFollowTheirPredicates() {
        #expect(!PaletteCommand.deleteWorkspace.isVisible(in: PaletteContext(canRemoveWorkspace: false)))
        #expect(PaletteCommand.deleteWorkspace.isVisible(in: PaletteContext(canRemoveWorkspace: true)))
        #expect(!PaletteCommand.clearFocus.isVisible(in: PaletteContext(hasMarkedWorkspaces: false)))
        #expect(PaletteCommand.clearFocus.isVisible(in: PaletteContext(hasMarkedWorkspaces: true)))
        #expect(!PaletteCommand.focusLeftPane.isVisible(in: PaletteContext(activeSessionHasSplit: false)))
        #expect(PaletteCommand.focusRightPane.isVisible(in: PaletteContext(activeSessionHasSplit: true)))
        #expect(!PaletteCommand.closeSplit.isVisible(in: PaletteContext(activeSessionHasSplit: false)))
        #expect(PaletteCommand.closeSplit.isVisible(in: PaletteContext(activeSessionHasSplit: true)))
        #expect(PaletteCommand.swapPanes.isVisible(in: PaletteContext()))
        #expect(!PaletteCommand.swapPanes.isEnabled(
            in: PaletteContext(activeSessionHasSplit: false, hasActiveSession: true)))
        #expect(PaletteCommand.swapPanes.isEnabled(
            in: PaletteContext(activeSessionHasSplit: true, hasActiveSession: true)))
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

    /// Everything present, nothing covering: every command's menu item is live here.
    private static let live = PaletteContext(canRemoveWorkspace: true, hasFlaggedSessions: true,
                                             sidebarShowsWorkspaceTree: true, hasMarkedWorkspaces: true,
                                             canStepWorkspaces: true,
                                             activeSessionHasSplit: true, hasPendingClose: true,
                                             hasRecentClosed: true, hasActiveSession: true,
                                             hasCurrentWorkspace: true)

    /// The commands whose menu item carries no `modalActive` term at all.
    private static let coverProof: Set<PaletteCommand> = [
        .closeSession, .reloadKeymap, .reloadConfig,
        .increaseFontSize, .decreaseFontSize, .resetFontSize, .toggleTerminalZoom,
    ]

    private static let needSession: Set<PaletteCommand> = [
        .renameSession, .duplicateSession, .clearStatus, .toggleFlag, .toggleSplit, .toggleHorizontalSplit,
        .swapPanes, .toggleScratch, .find,
        .previousSession, .nextSession, .previousAttentionSession, .nextAttentionSession,
        .firstSession, .lastSession,
    ]

    @Test func everyCommandIsLiveWhenNothingIsMissingOrCovering() {
        for command in PaletteCommand.allCases {
            #expect(command.isEnabled(in: Self.live), "\(command) should be live")
        }
    }

    @Test func sessionPresenceGatesTheSameCommandsTheMenuDoes() {
        let context = PaletteContext(canRemoveWorkspace: true, hasFlaggedSessions: true,
                                     sidebarShowsWorkspaceTree: true, hasMarkedWorkspaces: true,
                                     canStepWorkspaces: true,
                                     activeSessionHasSplit: true, hasPendingClose: true,
                                     hasRecentClosed: true, hasActiveSession: false,
                                     hasCurrentWorkspace: true)
        for command in PaletteCommand.allCases {
            #expect(command.isEnabled(in: context) == !Self.needSession.contains(command), "\(command)")
        }
    }

    @Test func workspacePresenceGatesTheWorkspaceEntries() {
        let context = PaletteContext(canRemoveWorkspace: true, hasFlaggedSessions: true,
                                     sidebarShowsWorkspaceTree: true, hasMarkedWorkspaces: true,
                                     canStepWorkspaces: true,
                                     activeSessionHasSplit: true, hasPendingClose: true,
                                     hasRecentClosed: true, hasActiveSession: true,
                                     hasCurrentWorkspace: false)
        let needWorkspace: Set<PaletteCommand> = [.renameWorkspace, .focusWorkspace, .addWorkspaceToFocus,
                                                  .previousWorkspace, .nextWorkspace, .toggleWorkspaceCollapse]
        for command in PaletteCommand.allCases {
            #expect(command.isEnabled(in: context) == !needWorkspace.contains(command), "\(command)")
        }
    }

    @Test func terminalZoomLeavesOnlyTheItemsCarryingNoModalTerm() {
        let context = PaletteContext(canRemoveWorkspace: true, hasFlaggedSessions: true,
                                     sidebarShowsWorkspaceTree: true, hasMarkedWorkspaces: true,
                                     canStepWorkspaces: true,
                                     activeSessionHasSplit: true, hasPendingClose: true,
                                     hasRecentClosed: true, hasActiveSession: true,
                                     hasCurrentWorkspace: true, terminalZoomActive: true)
        for command in PaletteCommand.allCases {
            let expected = Self.coverProof.contains(command) || command == .swapPanes
            #expect(command.isEnabled(in: context) == expected, "\(command)")
        }
    }

    @Test func aPendingPickerLeavesTheSameSet() {
        let context = PaletteContext(canRemoveWorkspace: true, hasFlaggedSessions: true,
                                     sidebarShowsWorkspaceTree: true, hasMarkedWorkspaces: true,
                                     canStepWorkspaces: true,
                                     activeSessionHasSplit: true, hasPendingClose: true,
                                     hasRecentClosed: true, hasActiveSession: true,
                                     hasCurrentWorkspace: true, pickerActive: true)
        for command in PaletteCommand.allCases {
            #expect(command.isEnabled(in: context) == Self.coverProof.contains(command), "\(command)")
        }
    }

    // Navigate ▸ Dashboard is the open grid's own escape hatch, so its item alone survives that one cover.
    @Test func theOpenDashboardSparesItsOwnToggle() {
        let context = PaletteContext(canRemoveWorkspace: true, hasFlaggedSessions: true,
                                     sidebarShowsWorkspaceTree: true, hasMarkedWorkspaces: true,
                                     canStepWorkspaces: true,
                                     activeSessionHasSplit: true, hasPendingClose: true,
                                     hasRecentClosed: true, hasActiveSession: true,
                                     hasCurrentWorkspace: true, dashboardOpen: true)
        for command in PaletteCommand.allCases {
            let expected = Self.coverProof.contains(command) || command == .dashboard || command == .swapPanes
            #expect(command.isEnabled(in: context) == expected, "\(command)")
        }
        #expect(!PaletteCommand.dashboard.isEnabled(
            in: PaletteContext(hasActiveSession: true, hasCurrentWorkspace: true,
                               terminalZoomActive: true, dashboardOpen: true)))
    }

    // the palette lists rows the menu disables, so a missing session must not remove them from the catalog.
    @Test func rowsStayVisibleWhereTheMenuItemGoesDisabled() {
        let context = PaletteContext(hasActiveSession: false, hasCurrentWorkspace: false)
        for command in Self.needSession.union([.renameWorkspace, .focusWorkspace]) {
            #expect(command.isVisible(in: context), "\(command) stays listed")
            #expect(!command.isEnabled(in: context), "\(command) stays inert")
        }
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
        #expect(PaletteCommand.swapPanes.builtinAction == nil)
        #expect(PaletteCommand.clearFlagged.builtinAction == nil)
        #expect(PaletteCommand.addWorkspaceToFocus.builtinAction == nil)
        #expect(PaletteCommand.expandWorkspaces.builtinAction == nil)
    }
}
