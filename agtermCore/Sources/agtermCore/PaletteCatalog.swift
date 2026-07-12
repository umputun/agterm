import Foundation

/// The UI facts needed to decide which static action-palette rows are relevant right now.
public struct PaletteContext: Sendable, Equatable {
    public let canRemoveWorkspace: Bool
    public let hasFlaggedSessions: Bool
    public let sidebarShowsWorkspaceTree: Bool
    public let sidebarShowsFlaggedOnly: Bool
    public let activeSessionFlagged: Bool
    public let hasFocusedWorkspace: Bool
    public let activeSessionHasSplit: Bool
    public let hasPendingClose: Bool
    public let hasRecentClosed: Bool

    public init(canRemoveWorkspace: Bool = false,
                hasFlaggedSessions: Bool = false,
                sidebarShowsWorkspaceTree: Bool = false,
                sidebarShowsFlaggedOnly: Bool = false,
                activeSessionFlagged: Bool = false,
                hasFocusedWorkspace: Bool = false,
                activeSessionHasSplit: Bool = false,
                hasPendingClose: Bool = false,
                hasRecentClosed: Bool = false) {
        self.canRemoveWorkspace = canRemoveWorkspace
        self.hasFlaggedSessions = hasFlaggedSessions
        self.sidebarShowsWorkspaceTree = sidebarShowsWorkspaceTree
        self.sidebarShowsFlaggedOnly = sidebarShowsFlaggedOnly
        self.activeSessionFlagged = activeSessionFlagged
        self.hasFocusedWorkspace = hasFocusedWorkspace
        self.activeSessionHasSplit = activeSessionHasSplit
        self.hasPendingClose = hasPendingClose
        self.hasRecentClosed = hasRecentClosed
    }
}

/// Static action-palette rows, in the same order the macOS palette presents them before dynamic rows.
public enum PaletteCommand: String, CaseIterable, Sendable {
    case newSession, newWorkspace, openDirectory
    case renameSession, renameWorkspace, closeSession, reopenRecent, undoClose, clearStatus
    case previousSession, nextSession, previousAttentionSession, nextAttentionSession
    case firstSession, lastSession, showAttention
    case toggleSplit, toggleScratch, toggleTerminalZoom, toggleSidebar, toggleFlag, focusWorkspace
    case find, quickTerminal, dashboard, toggleFullscreen
    case increaseFontSize, decreaseFontSize, resetFontSize, selectTheme
    case editKeymap, reloadKeymap, editGhosttyConfig, reloadConfig
    case deleteWorkspace, toggleFlaggedView, clearFlagged, clearFocus
    case expandWorkspaces, collapseWorkspaces, focusLeftPane, focusRightPane

    public func isVisible(in context: PaletteContext) -> Bool {
        switch self {
        case .deleteWorkspace:
            return context.canRemoveWorkspace
        case .toggleFlaggedView:
            return context.sidebarShowsFlaggedOnly || context.hasFlaggedSessions
        case .clearFlagged:
            return context.hasFlaggedSessions
        case .clearFocus:
            return context.hasFocusedWorkspace
        case .expandWorkspaces, .collapseWorkspaces:
            return context.sidebarShowsWorkspaceTree
        case .focusLeftPane, .focusRightPane:
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
        case .renameWorkspace: return "Rename Workspace"
        case .closeSession: return "Close Session"
        case .reopenRecent: return "Reopen Last Closed Item"
        case .undoClose: return "Reopen Closed Item"
        case .clearStatus: return "Clear Status"
        case .previousSession: return "Previous Session"
        case .nextSession: return "Next Session"
        case .previousAttentionSession: return "Previous Attention Session"
        case .nextAttentionSession: return "Next Attention Session"
        case .firstSession: return "First Session"
        case .lastSession: return "Last Session"
        case .showAttention: return "Show Attention"
        case .toggleSplit: return "Toggle Split"
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
        case .expandWorkspaces: return "Expand Workspaces"
        case .collapseWorkspaces: return "Collapse Workspaces"
        case .focusLeftPane: return "Focus Left Pane"
        case .focusRightPane: return "Focus Right Pane"
        }
    }

    public var builtinAction: BuiltinAction? {
        switch self {
        case .newSession: return .newSession
        case .newWorkspace: return .newWorkspace
        case .openDirectory: return .openDirectory
        case .renameSession: return .renameSession
        case .renameWorkspace: return .renameWorkspace
        case .closeSession: return .closeSession
        case .reopenRecent: return .reopenRecent
        case .undoClose: return .undoClose
        case .clearStatus: return .clearStatus
        case .previousSession: return .previousSession
        case .nextSession: return .nextSession
        case .previousAttentionSession: return .previousAttentionSession
        case .nextAttentionSession: return .nextAttentionSession
        case .firstSession: return .firstSession
        case .lastSession: return .lastSession
        case .showAttention: return .showAttention
        case .toggleSplit: return .toggleSplit
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
        case .focusLeftPane: return .focusLeftPane
        case .focusRightPane: return .focusRightPane
        case .editKeymap, .reloadKeymap, .editGhosttyConfig, .reloadConfig,
             .clearFlagged, .clearFocus, .expandWorkspaces, .collapseWorkspaces:
            return nil
        }
    }
}
