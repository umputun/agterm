import Foundation

/// App-facing operations a host must provide for commands routed through `ControlDispatcher`.
/// The dispatcher owns command parsing and response shape; the host keeps target resolution and
/// platform-specific side effects.
@MainActor
public protocol ControlActions {
    func controlTree(window: String?) -> ControlResponse
    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse
    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse
    func expandSidebar(window: String?) -> ControlResponse
    func collapseSidebar(window: String?) -> ControlResponse
}

/// Routes the command groups that have been hoisted from the app control switch. Commands outside this
/// first migrated set return nil so the app can keep handling them in its existing switch.
@MainActor
public struct ControlDispatcher {
    private let actions: any ControlActions

    public init(actions: any ControlActions) {
        self.actions = actions
    }

    public func dispatch(_ request: ControlRequest) -> ControlResponse? {
        switch request.cmd {
        case .tree:
            return actions.controlTree(window: request.args?.window)
        case .sidebar:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarVisibility(mode)
        case .sidebarMode:
            guard let mode = ControlSidebarViewMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarViewMode(mode)
        case .sidebarExpand:
            return actions.expandSidebar(window: request.args?.window)
        case .sidebarCollapse:
            return actions.collapseSidebar(window: request.args?.window)
        default:
            return nil
        }
    }
}
