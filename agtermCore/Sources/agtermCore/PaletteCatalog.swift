/// The UI facts behind `PaletteCommand.isVisible(in:)` (which rows are relevant at all) and
/// `isEnabled(in:)` (which of them can run right now).
public struct PaletteContext: Sendable, Equatable {
    public let canRemoveWorkspace: Bool
    public let hasFlaggedSessions: Bool
    public let sidebarShowsWorkspaceTree: Bool
    public let sidebarShowsFlaggedOnly: Bool
    public let activeSessionFlagged: Bool
    /// Whether ANY workspace is MARKED in the focus set — membership, NOT whether the filter is applied
    /// (`workspaceFilter`): the marked set is what Clear Focus empties and Toggle Workspace Filter applies.
    public let hasMarkedWorkspaces: Bool
    /// Whether the CURRENT workspace is already marked, so "Add Workspace to Focus" can hide instead of
    /// offering a silent no-op (the sidebar row's item has a clicked row and flips to "Remove from Focus").
    /// The ONLY term that entry keys on, matching the View-menu twin — marking is offered in either mode.
    public let activeWorkspaceMarked: Bool
    /// Whether the CURRENT workspace's sidebar subtree is folded, so the collapse toggle can name what the
    /// keystroke will do. `AppStore.isCurrentWorkspaceCollapsed`: what the ROW shows, deliberately not the
    /// persisted `!isExpanded` the `collapsed` tree read-back reports.
    public let activeWorkspaceCollapsed: Bool
    /// Whether more than one workspace is visible, i.e. whether a workspace step has anywhere to go.
    /// `navigateWorkspace` no-ops below that, so without this term the menu item and the mapped key stay
    /// live while provably doing nothing.
    public let canStepWorkspaces: Bool
    public let activeSessionHasSplit: Bool
    public let activeSplitAxis: SplitAxis?
    public let hasPendingClose: Bool
    public let hasRecentClosed: Bool
    /// Whether the frontmost window has an active session at all.
    public let hasActiveSession: Bool
    /// Whether it has a current workspace — nil only with no store, since a window always keeps one.
    public let hasCurrentWorkspace: Bool
    public let terminalZoomActive: Bool
    public let dashboardOpen: Bool
    /// Whether a control-API native picker is pending over the window.
    public let pickerActive: Bool

    /// Any cover over the deck. Behind it a keystroke or a menu pick must not mutate what it hides, so all
    /// but a handful of commands go dead; `PaletteCommand.isEnabled(in:)` owns which.
    public var modalActive: Bool { terminalZoomActive || dashboardOpen || pickerActive }

    public init(canRemoveWorkspace: Bool = false,
                hasFlaggedSessions: Bool = false,
                sidebarShowsWorkspaceTree: Bool = false,
                sidebarShowsFlaggedOnly: Bool = false,
                activeSessionFlagged: Bool = false,
                hasMarkedWorkspaces: Bool = false,
                activeWorkspaceMarked: Bool = false,
                activeWorkspaceCollapsed: Bool = false,
                canStepWorkspaces: Bool = false,
                activeSessionHasSplit: Bool = false,
                activeSplitAxis: SplitAxis? = nil,
                hasPendingClose: Bool = false,
                hasRecentClosed: Bool = false,
                hasActiveSession: Bool = false,
                hasCurrentWorkspace: Bool = false,
                terminalZoomActive: Bool = false,
                dashboardOpen: Bool = false,
                pickerActive: Bool = false) {
        self.canRemoveWorkspace = canRemoveWorkspace
        self.hasFlaggedSessions = hasFlaggedSessions
        self.sidebarShowsWorkspaceTree = sidebarShowsWorkspaceTree
        self.sidebarShowsFlaggedOnly = sidebarShowsFlaggedOnly
        self.activeSessionFlagged = activeSessionFlagged
        self.hasMarkedWorkspaces = hasMarkedWorkspaces
        self.activeWorkspaceMarked = activeWorkspaceMarked
        self.activeWorkspaceCollapsed = activeWorkspaceCollapsed
        self.canStepWorkspaces = canStepWorkspaces
        self.activeSessionHasSplit = activeSessionHasSplit
        self.activeSplitAxis = activeSplitAxis
        self.hasPendingClose = hasPendingClose
        self.hasRecentClosed = hasRecentClosed
        self.hasActiveSession = hasActiveSession
        self.hasCurrentWorkspace = hasCurrentWorkspace
        self.terminalZoomActive = terminalZoomActive
        self.dashboardOpen = dashboardOpen
        self.pickerActive = pickerActive
    }
}

/// Static action-palette rows, in the same order the macOS palette presents them before dynamic rows.
public enum PaletteCommand: String, CaseIterable, Sendable {
    case newSession, newWorkspace, openDirectory
    case renameSession, duplicateSession, renameWorkspace, closeSession, reopenRecent, undoClose, clearStatus
    case previousSession, nextSession, previousAttentionSession, nextAttentionSession
    case previousWorkspace, nextWorkspace
    case firstSession, lastSession, showAttention
    case toggleSplit, toggleHorizontalSplit, closeSplit, swapPanes, toggleScratch, toggleTerminalZoom
    case toggleSidebar, toggleFlag, focusWorkspace
    case find, quickTerminal, dashboard, toggleFullscreen
    case increaseFontSize, decreaseFontSize, resetFontSize, selectTheme
    case editKeymap, reloadKeymap, editGhosttyConfig, reloadConfig
    case deleteWorkspace, toggleFlaggedView, clearFlagged, clearFocus
    case addWorkspaceToFocus, toggleWorkspaceFilter
    case expandWorkspaces, collapseWorkspaces, toggleWorkspaceCollapse, focusLeftPane, focusRightPane

    /// Whether the command can RUN right now — the single owner of menu enablement, read by the menu item's
    /// `.disabled(…)`, by the palette row (which stays listed but renders inert) and by the key monitor's
    /// `AppActions.perform(_:in:)`, so a built-in's menu chord and its `keymap.conf` alternatives cannot
    /// diverge. Relevance, then the modal cover, then the presence terms.
    public func isEnabled(in context: PaletteContext) -> Bool {
        guard isVisible(in: context), !isCoveredByModal(context) else { return false }
        switch self {
        case .renameSession, .duplicateSession, .clearStatus, .toggleFlag, .toggleSplit,
             .toggleHorizontalSplit, .toggleScratch,
             .find, .previousSession, .nextSession, .previousAttentionSession, .nextAttentionSession,
             .firstSession, .lastSession:
            return context.hasActiveSession
        case .swapPanes:
            return context.hasActiveSession && context.activeSessionHasSplit
        case .renameWorkspace, .focusWorkspace, .addWorkspaceToFocus, .toggleWorkspaceCollapse:
            return context.hasCurrentWorkspace
        case .previousWorkspace, .nextWorkspace:
            // a step needs somewhere to go, so a lone visible workspace disables rather than no-ops
            return context.hasCurrentWorkspace && context.canStepWorkspaces
        default:
            return true
        }
    }

    /// Whether a cover blocks the command. Most menu items mirror the whole cover; the font sizes, both
    /// reloads, terminal zoom and Close Session carry no modal term at all, and Dashboard carries every
    /// cover but its own grid, its item being that grid's escape hatch.
    private func isCoveredByModal(_ context: PaletteContext) -> Bool {
        switch self {
        case .increaseFontSize, .decreaseFontSize, .resetFontSize,
             .reloadKeymap, .reloadConfig, .toggleTerminalZoom, .closeSession:
            return false
        case .dashboard:
            return context.terminalZoomActive || context.pickerActive
        case .swapPanes:
            return context.pickerActive
        default:
            return context.modalActive
        }
    }

    /// Whether the command's row is worth listing at all. Deliberately WIDER than `isEnabled(in:)`: the
    /// palette lists Rename Session with no session open, showing it inert, while the menu item disables.
    public func isVisible(in context: PaletteContext) -> Bool {
        switch self {
        case .deleteWorkspace:
            return context.canRemoveWorkspace
        case .toggleFlaggedView:
            return context.sidebarShowsFlaggedOnly || context.hasFlaggedSessions
        case .clearFlagged:
            return context.hasFlaggedSessions
        case .clearFocus, .toggleWorkspaceFilter:
            // nothing marked means nothing to clear and nothing to filter to, and the store refuses to enable
            // an empty set — the state the bottom-bar toggle renders disabled in, so the two surfaces agree.
            return context.hasMarkedWorkspaces
        case .addWorkspaceToFocus:
            // hidden only where it would be a silent no-op: the current workspace is already a member (the
            // row menu flips to "Remove from Focus" instead, having a clicked row, while this keyless entry
            // targets `currentWorkspaceID`). NOT gated on sidebar mode — membership is model state the tree
            // applies the moment it is shown again, and every sibling is mode-agnostic: the View-menu item,
            // Focus Workspace, Toggle Workspace Filter, Clear Focus, the `focus_workspace` keybind,
            // `workspace.focus`/`workspace.filter`. the tree-mode gate belongs to expand/collapse, whose rows
            // flagged mode never renders.
            return !context.activeWorkspaceMarked
        case .expandWorkspaces, .collapseWorkspaces, .toggleWorkspaceCollapse,
             .previousWorkspace, .nextWorkspace:
            // the tree-mode gate the sibling comment on `addWorkspaceToFocus` describes: these five act on
            // workspace ROWS, which flagged mode's flat list does not render, and `navigateWorkspace` no-ops
            // there for the same reason.
            return context.sidebarShowsWorkspaceTree
        case .focusLeftPane, .focusRightPane, .closeSplit:
            // `hasSplit`, not `isSplit`: a hidden pane is alive and still reported, the state Close Split
            // exists for.
            return context.activeSessionHasSplit
        case .undoClose:
            return context.hasPendingClose
        case .reopenRecent:
            return context.hasRecentClosed
        default:
            return true
        }
    }

    public var title: String {
        title(in: PaletteContext())
    }

    public func title(in context: PaletteContext) -> String {
        switch self {
        case .newSession: return "New Session"
        case .newWorkspace: return "New Workspace"
        case .openDirectory: return "Open Directory…"
        case .renameSession: return "Rename Session"
        case .duplicateSession: return "Duplicate Session"
        case .renameWorkspace: return "Rename Workspace"
        case .closeSession: return "Close Session"
        case .reopenRecent: return "Reopen Last Closed Item"
        case .undoClose: return "Reopen Closed Item"
        case .clearStatus: return "Clear Status"
        case .previousSession: return "Previous Session"
        case .nextSession: return "Next Session"
        case .previousAttentionSession: return "Previous Attention Session"
        case .nextAttentionSession: return "Next Attention Session"
        case .previousWorkspace: return "Previous Workspace"
        case .nextWorkspace: return "Next Workspace"
        case .firstSession: return "First Session"
        case .lastSession: return "Last Session"
        case .showAttention: return "Show Attention"
        case .toggleSplit: return "Toggle Vertical Split"
        case .toggleHorizontalSplit: return "Toggle Horizontal Split"
        case .closeSplit: return "Close Split"
        case .swapPanes: return "Swap Panes"
        case .toggleScratch: return "Toggle Scratch"
        case .toggleTerminalZoom: return "Toggle Terminal Zoom"
        case .toggleSidebar: return "Toggle Sidebar"
        case .toggleFlag: return context.activeSessionFlagged ? "Unflag Session" : "Flag Session"
        case .focusWorkspace: return "Focus Workspace"
        case .find: return "Find…"
        case .quickTerminal: return "Quick Terminal"
        case .dashboard: return "Dashboard"
        case .toggleFullscreen: return "Toggle Full Screen"
        case .increaseFontSize: return "Increase Font Size"
        case .decreaseFontSize: return "Decrease Font Size"
        case .resetFontSize: return "Actual Font Size"
        case .selectTheme: return "Select Theme…"
        case .editKeymap: return "Edit Keymap"
        case .reloadKeymap: return "Reload Keymap"
        case .editGhosttyConfig: return "Edit ghostty.conf"
        case .reloadConfig: return "Reload Config"
        case .deleteWorkspace: return "Delete Workspace"
        case .toggleFlaggedView: return context.sidebarShowsFlaggedOnly ? "Show All Sessions" : "Show Flagged Sessions"
        case .clearFlagged: return "Clear Flagged"
        case .clearFocus: return "Clear Focus"
        case .addWorkspaceToFocus: return "Add Workspace to Focus"
        case .toggleWorkspaceFilter: return "Toggle Workspace Filter"
        case .expandWorkspaces: return "Expand Workspaces"
        case .collapseWorkspaces: return "Collapse Workspaces"
        case .toggleWorkspaceCollapse: return context.activeWorkspaceCollapsed ? "Expand Workspace" : "Collapse Workspace"
        case .focusLeftPane: return context.activeSplitAxis == .topBottom ? "Focus Top Pane" : "Focus Left Pane"
        case .focusRightPane: return context.activeSplitAxis == .topBottom ? "Focus Bottom Pane" : "Focus Right Pane"
        }
    }

    public var builtinAction: BuiltinAction? {
        switch self {
        case .newSession: return .newSession
        case .newWorkspace: return .newWorkspace
        case .openDirectory: return .openDirectory
        case .renameSession: return .renameSession
        case .duplicateSession: return .duplicateSession
        case .renameWorkspace: return .renameWorkspace
        case .closeSession: return .closeSession
        case .reopenRecent: return .reopenRecent
        case .undoClose: return .undoClose
        case .clearStatus: return .clearStatus
        case .previousSession: return .previousSession
        case .nextSession: return .nextSession
        case .previousAttentionSession: return .previousAttentionSession
        case .nextAttentionSession: return .nextAttentionSession
        case .previousWorkspace: return .previousWorkspace
        case .nextWorkspace: return .nextWorkspace
        case .toggleWorkspaceCollapse: return .toggleWorkspaceCollapse
        case .firstSession: return .firstSession
        case .lastSession: return .lastSession
        case .showAttention: return .showAttention
        case .toggleSplit: return .toggleSplit
        case .toggleHorizontalSplit: return .toggleHorizontalSplit
        case .toggleScratch: return .toggleScratch
        case .toggleTerminalZoom: return .toggleTerminalZoom
        case .toggleSidebar: return .toggleSidebar
        case .toggleFlag: return .toggleFlag
        case .focusWorkspace: return .focusWorkspace
        case .find: return .toggleSearch
        case .quickTerminal: return .quickTerminal
        case .dashboard: return .dashboard
        case .toggleFullscreen: return .toggleFullscreen
        case .increaseFontSize: return .increaseFontSize
        case .decreaseFontSize: return .decreaseFontSize
        case .resetFontSize: return .resetFontSize
        case .selectTheme: return .selectTheme
        case .deleteWorkspace: return .deleteWorkspace
        case .toggleFlaggedView: return .toggleFlaggedView
        case .toggleWorkspaceFilter: return .toggleWorkspaceFilter
        case .focusLeftPane: return .focusLeftPane
        case .focusRightPane: return .focusRightPane
        case .editKeymap, .reloadKeymap, .editGhosttyConfig, .reloadConfig,
             .clearFlagged, .clearFocus, .addWorkspaceToFocus, .expandWorkspaces, .collapseWorkspaces,
             .closeSplit, .swapPanes:
            return nil
        }
    }
}
