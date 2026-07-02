import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherTests {
    @Test func treeRoutesThroughActionsWithWindowArgument() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let tree = ControlTree(workspaces: [
            ControlWorkspaceNode(id: "workspace", name: "Workspace", active: true, sessions: [])
        ])
        actions.nextTreeResponse = ControlResponse(ok: true, result: ControlResult(tree: tree))

        let response = dispatcher.dispatch(ControlRequest(cmd: .tree, args: ControlArgs(window: "abc")))

        #expect(response == ControlResponse(ok: true, result: ControlResult(tree: tree)))
        #expect(actions.calls == [.tree(window: "abc")])
    }

    @Test func sidebarVisibilityParsesModesAndKeepsExactResponse() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSidebarVisibilityResponse = ControlResponse(ok: true)

        let response = dispatcher.dispatch(ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "hide")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.sidebarVisibility(.off)])
    }

    @Test func sidebarVisibilityDefaultsToToggle() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = dispatcher.dispatch(ControlRequest(cmd: .sidebar))

        #expect(actions.calls == [.sidebarVisibility(.toggle)])
    }

    @Test func sidebarVisibilityRejectsInvalidModeWithoutCallingActions() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = dispatcher.dispatch(ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "yes")))

        #expect(response == ControlResponse(ok: false, error: "invalid sidebar mode: yes"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sidebarViewModeParsesModesAndKeepsExactResponse() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSidebarViewModeResponse = ControlResponse(ok: true)

        let response = dispatcher.dispatch(ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "flagged")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.sidebarViewMode(.flagged)])
    }

    @Test func sidebarViewModeDefaultsToToggle() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = dispatcher.dispatch(ControlRequest(cmd: .sidebarMode))

        #expect(actions.calls == [.sidebarViewMode(.toggle)])
    }

    @Test func sidebarViewModeRejectsInvalidModeWithoutCallingActions() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = dispatcher.dispatch(ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "wide")))

        #expect(response == ControlResponse(ok: false, error: "invalid sidebar mode: wide"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sidebarExpandAndCollapseRouteWithWindowArgument() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextExpandResponse = ControlResponse(ok: true)
        actions.nextCollapseResponse = ControlResponse(ok: false, error: "window not open - window.select it first")

        let expand = dispatcher.dispatch(ControlRequest(cmd: .sidebarExpand, args: ControlArgs(window: "win")))
        let collapse = dispatcher.dispatch(ControlRequest(cmd: .sidebarCollapse, args: ControlArgs(window: "win")))

        #expect(expand == ControlResponse(ok: true))
        #expect(collapse == ControlResponse(ok: false, error: "window not open - window.select it first"))
        #expect(actions.calls == [.expand(window: "win"), .collapse(window: "win")])
    }

    @Test func nonMigratedCommandFallsThrough() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = dispatcher.dispatch(ControlRequest(cmd: .sessionSelect))

        #expect(response == nil)
        #expect(actions.calls.isEmpty)
    }
}

@MainActor
private final class MockControlActions: ControlActions {
    enum Call: Equatable {
        case tree(window: String?)
        case sidebarVisibility(ControlToggleMode)
        case sidebarViewMode(ControlSidebarViewMode)
        case expand(window: String?)
        case collapse(window: String?)
    }

    var calls: [Call] = []
    var nextTreeResponse = ControlResponse(ok: false, error: "tree not stubbed")
    var nextSidebarVisibilityResponse = ControlResponse(ok: true)
    var nextSidebarViewModeResponse = ControlResponse(ok: true)
    var nextExpandResponse = ControlResponse(ok: true)
    var nextCollapseResponse = ControlResponse(ok: true)

    func controlTree(window: String?) -> ControlResponse {
        calls.append(.tree(window: window))
        return nextTreeResponse
    }

    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse {
        calls.append(.sidebarVisibility(mode))
        return nextSidebarVisibilityResponse
    }

    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse {
        calls.append(.sidebarViewMode(mode))
        return nextSidebarViewModeResponse
    }

    func expandSidebar(window: String?) -> ControlResponse {
        calls.append(.expand(window: window))
        return nextExpandResponse
    }

    func collapseSidebar(window: String?) -> ControlResponse {
        calls.append(.collapse(window: window))
        return nextCollapseResponse
    }
}
