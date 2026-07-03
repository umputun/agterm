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

    @Test func sessionNewRoutesValidatedOptions() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionNewResponse = ControlResponse(ok: true, result: ControlResult(id: "new-session"))

        let response = dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(name: "api", cwd: "/tmp", workspaceName: "servers", createWorkspace: true,
                              command: "top", window: "win")
        ))

        let options = ControlSessionCreateOptions(window: "win", cwd: "/tmp", workspace: nil,
                                                  workspaceName: "servers", createWorkspace: true,
                                                  command: "top", name: "api")
        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "new-session")))
        #expect(actions.calls == [.sessionNew(options)])
    }

    @Test func sessionNewRejectsAmbiguousWorkspaceArguments() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(workspace: "active", workspaceName: "servers")
        ))

        #expect(response == ControlResponse(ok: false, error: "use either --workspace or --workspace-name, not both"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionNewRejectsCreateWorkspaceWithoutName() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew,
            args: ControlArgs(createWorkspace: true)
        ))

        #expect(response == ControlResponse(ok: false, error: "--create-workspace requires --workspace-name"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionMoveRoutesReorderAndWorkspaceForms() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let reorder = dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "session",
            args: ControlArgs(window: "win", to: "top")
        ))
        let workspace = dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "session",
            args: ControlArgs(workspace: "dest")
        ))

        #expect(reorder == ControlResponse(ok: true))
        #expect(workspace == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionMove(target: "session", window: "win", .reorder(.top)),
            .sessionMove(target: "session", window: nil, .workspace("dest"))
        ])
    }

    @Test func sessionMoveRejectsInvalidForms() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = dispatcher.dispatch(ControlRequest(cmd: .sessionMove, target: "active"))
        let both = dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(workspace: "active", to: "up")
        ))
        let badDirection = dispatcher.dispatch(ControlRequest(
            cmd: .sessionMove,
            target: "active",
            args: ControlArgs(to: "sideways")
        ))

        #expect(missing == ControlResponse(ok: false, error: "session.move requires --to or a workspace"))
        #expect(both == ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both"))
        #expect(badDirection == ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceMoveRoutesDirectionAndRejectsInvalidForms() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let moved = dispatcher.dispatch(ControlRequest(
            cmd: .workspaceMove,
            target: "workspace",
            args: ControlArgs(window: "win", to: "bottom")
        ))
        let missing = dispatcher.dispatch(ControlRequest(cmd: .workspaceMove, target: "workspace"))
        let bad = dispatcher.dispatch(ControlRequest(
            cmd: .workspaceMove,
            target: "workspace",
            args: ControlArgs(to: "sideways")
        ))

        #expect(moved == ControlResponse(ok: true))
        #expect(missing == ControlResponse(ok: false, error: "workspace.move requires --to"))
        #expect(bad == ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom"))
        #expect(actions.calls == [.workspaceMove(target: "workspace", window: "win", .bottom)])
    }

    @Test func workspaceFocusRoutesModeForHostSideValidation() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let focused = dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus,
            target: "workspace",
            args: ControlArgs(mode: "on", window: "win")
        ))

        #expect(focused == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceFocus(target: "workspace", window: "win", "on")])
    }

    @Test func sessionFlagRoutesModeForHostSideValidation() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let flagged = dispatcher.dispatch(ControlRequest(
            cmd: .sessionFlag,
            target: "session",
            args: ControlArgs(mode: "on", window: "win")
        ))
        let cleared = dispatcher.dispatch(ControlRequest(cmd: .sessionFlag, args: ControlArgs(mode: "clear")))

        #expect(flagged == ControlResponse(ok: true))
        #expect(cleared == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionFlag(target: "session", window: "win", "on"),
            .sessionFlag(target: nil, window: nil, "clear")
        ])
    }

    @Test func sessionStatusRoutesParsedStatusAndRejectsInvalidStatus() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let status = dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(window: "win", status: "blocked", blink: true,
                              autoReset: true, sound: "default")
        ))
        let bad = dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(status: "bogus")
        ))

        #expect(status == ControlResponse(ok: true))
        #expect(bad == ControlResponse(ok: false, error: "invalid status"))
        #expect(actions.calls == [
            .sessionStatus(target: "session", window: "win",
                           ControlSessionStatusUpdate(status: .blocked, blink: true,
                                                      autoReset: true, sound: "default"))
        ])
    }

    @Test func splitScratchFocusAndResizeRouteParsedInputs() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let split = dispatcher.dispatch(ControlRequest(
            cmd: .sessionSplit,
            target: "session",
            args: ControlArgs(mode: "off", window: "win")
        ))
        let scratch = dispatcher.dispatch(ControlRequest(
            cmd: .sessionScratch,
            target: "session",
            args: ControlArgs(mode: "on", command: "htop")
        ))
        let focus = dispatcher.dispatch(ControlRequest(
            cmd: .sessionFocus,
            target: "session",
            args: ControlArgs(pane: "right")
        ))
        let resize = dispatcher.dispatch(ControlRequest(
            cmd: .sessionResize,
            target: "session",
            args: ControlArgs(window: "win", ratioDelta: -0.1)
        ))

        #expect(split == ControlResponse(ok: true))
        #expect(scratch == ControlResponse(ok: true))
        #expect(focus == ControlResponse(ok: true))
        #expect(resize == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionSplit(target: "session", window: "win", "off"),
            .sessionScratch(target: "session", window: nil, "on", command: "htop"),
            .sessionFocus(target: "session", window: nil, "right"),
            .sessionResize(target: "session", window: "win", .delta(-0.1))
        ])
    }

    @Test func resizeRejectsInvalidInputs() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missingResize = dispatcher.dispatch(ControlRequest(cmd: .sessionResize, args: ControlArgs()))
        let bothResize = dispatcher.dispatch(ControlRequest(
            cmd: .sessionResize,
            args: ControlArgs(ratio: 0.7, ratioDelta: 0.1)
        ))

        #expect(missingResize == ControlResponse(
            ok: false,
            error: "session.resize requires --split-ratio, --grow-left, or --grow-right"
        ))
        #expect(bothResize == ControlResponse(
            ok: false,
            error: "session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right"
        ))
        #expect(actions.calls.isEmpty)
    }

    @Test func fontCommandsRouteActionsWithTargetAndWindow() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextFontResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let inc = dispatcher.dispatch(ControlRequest(
            cmd: .fontInc,
            target: "session",
            args: ControlArgs(window: "win")
        ))
        let dec = dispatcher.dispatch(ControlRequest(cmd: .fontDec, target: "session"))
        let reset = dispatcher.dispatch(ControlRequest(cmd: .fontReset, target: "session"))

        #expect(inc == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(dec == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(reset == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [
            .font(target: "session", window: "win", "increase_font_size:1"),
            .font(target: "session", window: nil, "decrease_font_size:1"),
            .font(target: "session", window: nil, "reset_font_size")
        ])
    }

    @Test func keymapAndConfigReloadWrapDiagnosticCounts() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextKeymapResponse = ControlResponse(ok: true, result: ControlResult(count: 2))
        actions.nextConfigResponse = ControlResponse(ok: true, result: ControlResult(count: 3))

        let keymap = dispatcher.dispatch(ControlRequest(cmd: .keymapReload))
        let config = dispatcher.dispatch(ControlRequest(cmd: .configReload))

        #expect(keymap == ControlResponse(ok: true, result: ControlResult(count: 2)))
        #expect(config == ControlResponse(ok: true, result: ControlResult(count: 3)))
        #expect(actions.calls == [.keymapReload, .configReload])
    }

    @Test func notifyRequiresBodyBeforeCallingActions() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = dispatcher.dispatch(ControlRequest(cmd: .notify, target: "session"))
        let empty = dispatcher.dispatch(ControlRequest(
            cmd: .notify,
            target: "session",
            args: ControlArgs(body: "")
        ))

        #expect(missing == ControlResponse(ok: false, error: "notify requires a body"))
        #expect(empty == ControlResponse(ok: false, error: "notify requires a body"))
        #expect(actions.calls.isEmpty)
    }

    @Test func notifyRoutesBodyTitleTargetAndWindow() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextNotifyResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let response = dispatcher.dispatch(ControlRequest(
            cmd: .notify,
            target: "session",
            args: ControlArgs(window: "win", title: "Build", body: "done")
        ))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [
            .notify(target: "session", window: "win", title: "Build", body: "done")
        ])
    }

    @Test func themeSetRoutesAndEchoesActionResponse() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextThemeSetResponse = ControlResponse(ok: true, result: ControlResult(theme: "Dracula"))

        let set = dispatcher.dispatch(ControlRequest(
            cmd: .themeSet,
            args: ControlArgs(name: "Dracula")
        ))

        #expect(set == ControlResponse(ok: true, result: ControlResult(theme: "Dracula")))
        #expect(actions.calls == [.themeSet("Dracula")])
    }

    @Test func themeSetKeepsExactActionErrorResponse() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextThemeSetResponse = ControlResponse(ok: false, error: "unknown theme: NotARealTheme")

        let response = dispatcher.dispatch(ControlRequest(
            cmd: .themeSet,
            args: ControlArgs(name: "NotARealTheme")
        ))

        #expect(response == ControlResponse(ok: false, error: "unknown theme: NotARealTheme"))
        #expect(actions.calls == [.themeSet("NotARealTheme")])
    }

    @Test func themeListReturnsCurrentThemeAndAvailableThemes() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextThemeListResponse = ControlResponse(
            ok: true,
            result: ControlResult(theme: "Dracula", themes: ["Dracula", "Nord"])
        )

        let response = dispatcher.dispatch(ControlRequest(cmd: .themeList))

        #expect(response == ControlResponse(
            ok: true,
            result: ControlResult(theme: "Dracula", themes: ["Dracula", "Nord"])
        ))
        #expect(actions.calls == [.themeList])
    }

    @Test func nonMigratedCommandFallsThrough() {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = dispatcher.dispatch(ControlRequest(cmd: .sessionType))

        #expect(response == nil)
        #expect(actions.calls.isEmpty)
    }
}

@MainActor
private final class MockControlActions: ControlActions {
    enum Call: Equatable {
        case tree(window: String?)
        case sessionNew(ControlSessionCreateOptions)
        case sessionMove(target: String?, window: String?, ControlSessionMove)
        case workspaceMove(target: String?, window: String?, ReorderDirection)
        case workspaceFocus(target: String?, window: String?, String?)
        case sessionFlag(target: String?, window: String?, String?)
        case sessionStatus(target: String?, window: String?, ControlSessionStatusUpdate)
        case sessionSplit(target: String?, window: String?, String?)
        case sessionScratch(target: String?, window: String?, String?, command: String?)
        case sessionFocus(target: String?, window: String?, String?)
        case sessionResize(target: String?, window: String?, ControlSplitResize)
        case font(target: String?, window: String?, String)
        case keymapReload
        case configReload
        case notify(target: String?, window: String?, title: String?, body: String)
        case themeSet(String?)
        case themeList
        case sidebarVisibility(ControlToggleMode)
        case sidebarViewMode(ControlSidebarViewMode)
        case expand(window: String?)
        case collapse(window: String?)
    }

    var calls: [Call] = []
    var nextTreeResponse = ControlResponse(ok: false, error: "tree not stubbed")
    var nextSessionNewResponse = ControlResponse(ok: true)
    var nextSidebarVisibilityResponse = ControlResponse(ok: true)
    var nextSidebarViewModeResponse = ControlResponse(ok: true)
    var nextExpandResponse = ControlResponse(ok: true)
    var nextCollapseResponse = ControlResponse(ok: true)
    var nextFontResponse = ControlResponse(ok: true)
    var nextNotifyResponse = ControlResponse(ok: true)
    var nextKeymapResponse = ControlResponse(ok: true)
    var nextConfigResponse = ControlResponse(ok: true)
    var nextThemeSetResponse = ControlResponse(ok: true)
    var nextThemeListResponse = ControlResponse(ok: true)

    func controlTree(window: String?) -> ControlResponse {
        calls.append(.tree(window: window))
        return nextTreeResponse
    }

    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse {
        calls.append(.sessionNew(options))
        return nextSessionNewResponse
    }

    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        calls.append(.sessionMove(target: target, window: window, move))
        return ControlResponse(ok: true)
    }

    func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse {
        calls.append(.workspaceMove(target: target, window: window, direction))
        return ControlResponse(ok: true)
    }

    func focusWorkspace(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.workspaceFocus(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.sessionFlag(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func setSessionStatus(_ target: String?, window: String?,
                          update: ControlSessionStatusUpdate) -> ControlResponse {
        calls.append(.sessionStatus(target: target, window: window, update))
        return ControlResponse(ok: true)
    }

    func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.sessionSplit(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func scratchSession(_ target: String?, window: String?, mode: String?,
                        command: String?) -> ControlResponse {
        calls.append(.sessionScratch(target: target, window: window, mode, command: command))
        return ControlResponse(ok: true)
    }

    func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse {
        calls.append(.sessionFocus(target: target, window: window, pane))
        return ControlResponse(ok: true)
    }

    func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse {
        calls.append(.sessionResize(target: target, window: window, resize))
        return ControlResponse(ok: true)
    }

    func font(_ target: String?, window: String?, action: String) -> ControlResponse {
        calls.append(.font(target: target, window: window, action))
        return nextFontResponse
    }

    func reloadKeymap() -> ControlResponse {
        calls.append(.keymapReload)
        return nextKeymapResponse
    }

    func reloadGhosttyConfig() -> ControlResponse {
        calls.append(.configReload)
        return nextConfigResponse
    }

    func sendNotification(_ target: String?, window: String?,
                          title: String?, body: String) -> ControlResponse {
        calls.append(.notify(target: target, window: window, title: title, body: body))
        return nextNotifyResponse
    }

    func setTheme(name: String?) -> ControlResponse {
        calls.append(.themeSet(name))
        return nextThemeSetResponse
    }

    func listThemes() -> ControlResponse {
        calls.append(.themeList)
        return nextThemeListResponse
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
