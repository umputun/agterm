import agtermCore

/// The requirements agterm-server does not serve. `ServerCommandPolicy` refuses their commands before dispatch,
/// so these answer only a caller that reaches the actions directly.
extension ServerActions {
    public func readEvents(_ options: ControlEventReadOptions) -> ControlResponse { unserved("readEvents") }
    public func duplicateSession(_ target: String?, window: String?) -> ControlResponse { unserved("duplicateSession") }
    public func attachCompanionPage(_ target: String?, window: String?) -> ControlResponse { unserved("attachCompanionPage") }
    public func selectSession(_ target: String?, window: String?) -> ControlResponse { unserved("selectSession") }
    public func goSession(window: String?, direction: SessionNavigation) -> ControlResponse { unserved("goSession") }
    public func revealSession(_ target: String?, window: String?) -> ControlResponse { unserved("revealSession") }
    public func selectWorkspace(_ target: String?, window: String?) -> ControlResponse { unserved("selectWorkspace") }
    public func goWorkspace(window: String?, direction: WorkspaceNavigation) -> ControlResponse { unserved("goWorkspace") }
    public func focusWorkspace(_ target: String?, window: String?, mode: ControlWorkspaceFocusMode) -> ControlResponse { unserved("focusWorkspace") }
    public func setWorkspaceFilter(window: String?, mode: ControlToggleMode) -> ControlResponse { unserved("setWorkspaceFilter") }
    public func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse { unserved("setWorkspaceExpansion") }
    public func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse { unserved("setSessionFlag") }
    public func markSessionSeen(_ target: String?, window: String?) -> ControlResponse { unserved("markSessionSeen") }
    public func setSessionRestore(_ target: String?, window: String?, update: ControlSessionRestoreUpdate) -> ControlResponse { unserved("setSessionRestore") }
    public func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse { unserved("scratchSession") }
    public func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse { unserved("focusSessionPane") }
    public func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse { unserved("resizeSplit") }
    public func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse { unserved("setSurfaceZoom") }
    public func readSurfaceCursor(_ target: String?, window: String?) -> ControlResponse { unserved("readSurfaceCursor") }
    public func setDashboard(targets: [String], window: String?, close: Bool, fontMode: DashboardFontMode, mru: Bool) -> ControlResponse { unserved("setDashboard") }
    public func font(_ target: String?, window: String?, pane: StatusPane?, action: String) -> ControlResponse { unserved("font") }
    public func reloadKeymap() -> ControlResponse { unserved("reloadKeymap") }
    public func listKeymap() -> ControlResponse { unserved("listKeymap") }
    public func reloadGhosttyConfig() -> ControlResponse { unserved("reloadGhosttyConfig") }
    public func setTheme(args: ControlArgs?) -> ControlResponse { unserved("setTheme") }
    public func listThemes() -> ControlResponse { unserved("listThemes") }
    public func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse { unserved("setSidebarVisibility") }
    public func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse { unserved("setSidebarViewMode") }
    public func expandSidebar(window: String?) -> ControlResponse { unserved("expandSidebar") }
    public func collapseSidebar(window: String?) -> ControlResponse { unserved("collapseSidebar") }
    public func setQuickTerminal(mode: String?) -> ControlResponse { unserved("setQuickTerminal") }
    public func typeQuick(text: String) async -> ControlResponse { unserved("typeQuick") }
    public func readQuickText(all: Bool, lines: Int?) async -> ControlResponse { unserved("readQuickText") }
    public func copySessionSelection(_ target: String?, window: String?) -> ControlResponse { unserved("copySessionSelection") }
    public func pasteSession(_ target: String?, window: String?, pane: StatusPane?) -> ControlResponse { unserved("pasteSession") }
    public func selectAllSession(_ target: String?, window: String?) -> ControlResponse { unserved("selectAllSession") }
    public func searchSession(_ target: String?, window: String?, text: String?, to: String?) async -> ControlResponse { unserved("searchSession") }
    public func copySessionOverlaySelection(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse { unserved("copySessionOverlaySelection") }
    public func readSessionOverlayText(_ target: String?, window: String?, options: ControlSessionOverlayTextOptions) -> ControlResponse { unserved("readSessionOverlayText") }
    public func setSessionBackground(_ target: String?, window: String?, options: ControlSessionBackgroundOptions) -> ControlResponse { unserved("setSessionBackground") }
    public func windowNew(name: String?, minimized: Bool) async -> ControlResponse { unserved("windowNew") }
    public func windowSelect(_ target: String?) async -> ControlResponse { unserved("windowSelect") }
    public func windowClose(_ target: String?) async -> ControlResponse { unserved("windowClose") }
    public func windowRename(_ target: String?, name: String) -> ControlResponse { unserved("windowRename") }
    public func windowDelete(_ target: String?) -> ControlResponse { unserved("windowDelete") }
    public func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse { unserved("windowResize") }
    public func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse { unserved("windowMove") }
    public func windowZoom(_ target: String?) -> ControlResponse { unserved("windowZoom") }
    public func windowFullscreen(_ target: String?) -> ControlResponse { unserved("windowFullscreen") }
    public func windowMinimize(_ target: String?, mode: ControlToggleMode) async -> ControlResponse { unserved("windowMinimize") }
    public func clearRestoreCommands() -> ControlResponse { unserved("clearRestoreCommands") }
    public func captureRestoreCommands() -> ControlResponse { unserved("captureRestoreCommands") }

    private func unserved(_ name: String) -> ControlResponse {
        ControlResponse(ok: false, error: "\(name) is not available on agterm-server")
    }
}
