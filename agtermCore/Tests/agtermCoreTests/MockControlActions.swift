import Foundation
import Testing
@testable import agtermCore

/// The shared `ControlActions` test double for the dispatcher suites — it records every routed call as a
/// `Call` value and hands back a per-command canned `ControlResponse`, so a dispatcher test asserts on
/// WHAT was routed (and with which arguments) without any app host. Lives in its own file because it is a
/// fixture shared by `ControlDispatcherTests` and `ControlDispatcherDashboardTests`, not a test suite.
@MainActor
final class MockControlActions: ControlActions {
    enum Call: Equatable {
        case tree(window: String?)
        case eventsRead(ControlEventReadOptions)
        case sessionNew(ControlSessionCreateOptions)
        case sessionDuplicate(target: String?, window: String?)
        case sessionSelect(target: String?, window: String?)
        case sessionGo(window: String?, SessionNavigation)
        case sessionClose(target: String?, window: String?)
        case sessionCloseBatch(targets: [String], window: String?)
        case sessionRename(target: String?, window: String?, String)
        case sessionReveal(target: String?, window: String?)
        case workspaceNew(window: String?, String?, collapsed: Bool)
        case workspaceSelect(target: String?, window: String?)
        case workspaceRename(target: String?, window: String?, String)
        case workspaceDelete(target: String?, window: String?)
        case sessionMove(target: String?, window: String?, ControlSessionMove)
        case sessionMoveBatch(targets: [String], window: String?, ControlSessionMove)
        case workspaceMove(target: String?, window: String?, ReorderDirection)
        case workspaceFocus(target: String?, window: String?, String?)
        case workspaceExpansion(target: String?, window: String?, expanded: Bool)
        case sessionFlag(target: String?, window: String?, String?)
        case markSessionSeen(target: String?, window: String?)
        case sessionStatus(target: String?, window: String?, ControlSessionStatusUpdate)
        case sessionRestore(target: String?, window: String?, ControlSessionRestoreUpdate)
        case sessionSplit(target: String?, window: String?, String?)
        case sessionScratch(target: String?, window: String?, String?, command: String?)
        case sessionFocus(target: String?, window: String?, String?)
        case sessionResize(target: String?, window: String?, ControlSplitResize)
        case surfaceZoom(target: String?, window: String?, ControlToggleMode)
        case dashboard(targets: [String], window: String?, close: Bool, fontMode: DashboardFontMode, mru: Bool)
        case font(target: String?, window: String?, pane: String?, String)
        case keymapReload
        case configReload
        case notify(target: String?, window: String?, title: String?, body: String)
        case themeSet(String?)
        case themeList
        case sidebarVisibility(ControlToggleMode)
        case sidebarViewMode(ControlSidebarViewMode)
        case expand(window: String?)
        case collapse(window: String?)
        case quick(String?)
        case quickType(text: String)
        case quickText(all: Bool, lines: Int?)
        case sessionType(target: String?, window: String?, ControlSessionTypeOptions)
        case sessionCopy(target: String?, window: String?)
        case sessionPaste(target: String?, window: String?)
        case sessionSelectAll(target: String?, window: String?)
        case sessionSearch(target: String?, window: String?, text: String?, to: String?)
        case overlayOpen(target: String?, window: String?, ControlSessionOverlayOpenOptions)
        case overlayClose(target: String?, window: String?)
        case overlayResize(target: String?, window: String?, sizePercent: Int?)
        case overlayResult(target: String?, window: String?)
        case sessionBackground(target: String?, window: String?, ControlSessionBackgroundOptions)
        case sessionText(target: String?, window: String?, ControlSessionTextOptions)
        case windowNew(String?)
        case windowList
        case windowSelect(target: String?)
        case windowClose(target: String?)
        case windowRename(target: String?, String)
        case windowDelete(target: String?)
        case windowResize(target: String?, width: Int, height: Int)
        case windowMove(target: String?, x: Int, y: Int, display: Int?)
        case windowZoom(target: String?)
        case windowFullscreen(target: String?)
        case restoreClear
    }

    var calls: [Call] = []
    var nextTreeResponse = ControlResponse(ok: false, error: "tree not stubbed")
    var nextEventsReadResponse = ControlResponse(ok: false, error: "events.read not stubbed")
    var nextSessionNewResponse = ControlResponse(ok: true)
    var nextSessionDuplicateResponse = ControlResponse(ok: true)
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
    var nextQuickResponse = ControlResponse(ok: true)
    var nextQuickTypeResponse = ControlResponse(ok: true)
    var nextQuickTextResponse = ControlResponse(ok: true)
    var nextSessionTypeResponse = ControlResponse(ok: true)
    var nextSessionCopyResponse = ControlResponse(ok: true)
    var nextSessionPasteResponse = ControlResponse(ok: true)
    var nextSessionSelectAllResponse = ControlResponse(ok: true)
    var nextSessionSearchResponse = ControlResponse(ok: true)
    var nextOverlayOpenResponse = ControlResponse(ok: true)
    var nextOverlayCloseResponse = ControlResponse(ok: true)
    var nextOverlayResizeResponse = ControlResponse(ok: true)
    var nextOverlayResultResponse = ControlResponse(ok: true)
    var nextSessionBackgroundResponse = ControlResponse(ok: true)
    var nextSessionTextResponse = ControlResponse(ok: true)
    var nextSurfaceZoomResponse = ControlResponse(ok: true)
    var nextDashboardResponse = ControlResponse(ok: true)
    var nextWindowNewResponse = ControlResponse(ok: true)
    var nextWindowListResponse = ControlResponse(ok: true)
    var nextWindowSelectResponse = ControlResponse(ok: true)
    var nextWindowCloseResponse = ControlResponse(ok: true)
    var nextWindowRenameResponse = ControlResponse(ok: true)
    var nextWindowDeleteResponse = ControlResponse(ok: true)
    var nextWindowResizeResponse = ControlResponse(ok: true)
    var nextWindowMoveResponse = ControlResponse(ok: true)
    var nextWindowZoomResponse = ControlResponse(ok: true)
    var nextWindowFullscreenResponse = ControlResponse(ok: true)
    var nextRestoreClearResponse = ControlResponse(ok: true)
    var nextSessionRestoreResponse = ControlResponse(ok: true)

    func controlTree(window: String?) -> ControlResponse {
        calls.append(.tree(window: window))
        return nextTreeResponse
    }

    func readEvents(_ options: ControlEventReadOptions) -> ControlResponse {
        calls.append(.eventsRead(options))
        return nextEventsReadResponse
    }

    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse {
        calls.append(.sessionNew(options))
        return nextSessionNewResponse
    }

    func duplicateSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionDuplicate(target: target, window: window))
        return nextSessionDuplicateResponse
    }

    func selectSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionSelect(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func goSession(window: String?, direction: SessionNavigation) -> ControlResponse {
        calls.append(.sessionGo(window: window, direction))
        return ControlResponse(ok: true)
    }

    func closeSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionClose(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func closeSessions(_ targets: [String], window: String?) -> ControlResponse {
        calls.append(.sessionCloseBatch(targets: targets, window: window))
        return ControlResponse(ok: true)
    }

    func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse {
        calls.append(.sessionRename(target: target, window: window, name))
        return ControlResponse(ok: true)
    }

    func revealSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionReveal(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse {
        calls.append(.workspaceNew(window: window, name, collapsed: collapsed))
        return ControlResponse(ok: true)
    }

    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.workspaceSelect(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse {
        calls.append(.workspaceRename(target: target, window: window, name))
        return ControlResponse(ok: true)
    }

    func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.workspaceDelete(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        calls.append(.sessionMove(target: target, window: window, move))
        return ControlResponse(ok: true)
    }

    func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse {
        calls.append(.sessionMoveBatch(targets: targets, window: window, move))
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

    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        calls.append(.workspaceExpansion(target: target, window: window, expanded: expanded))
        return ControlResponse(ok: true)
    }

    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        calls.append(.sessionFlag(target: target, window: window, mode))
        return ControlResponse(ok: true)
    }

    func markSessionSeen(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.markSessionSeen(target: target, window: window))
        return ControlResponse(ok: true)
    }

    func setSessionStatus(_ target: String?, window: String?,
                          update: ControlSessionStatusUpdate) -> ControlResponse {
        calls.append(.sessionStatus(target: target, window: window, update))
        return ControlResponse(ok: true)
    }

    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse {
        calls.append(.sessionRestore(target: target, window: window, update))
        return nextSessionRestoreResponse
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

    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        calls.append(.surfaceZoom(target: target, window: window, mode))
        return nextSurfaceZoomResponse
    }

    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse {
        calls.append(.dashboard(targets: targets, window: window, close: close, fontMode: fontMode, mru: mru))
        return nextDashboardResponse
    }

    func font(_ target: String?, window: String?, pane: String?, action: String) -> ControlResponse {
        calls.append(.font(target: target, window: window, pane: pane, action))
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

    func setTheme(args: ControlArgs?) -> ControlResponse {
        calls.append(.themeSet(args?.name))
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

    func setQuickTerminal(mode: String?) -> ControlResponse {
        calls.append(.quick(mode))
        return nextQuickResponse
    }

    func typeQuick(text: String) async -> ControlResponse {
        calls.append(.quickType(text: text))
        return nextQuickTypeResponse
    }

    func readQuickText(all: Bool, lines: Int?) async -> ControlResponse {
        calls.append(.quickText(all: all, lines: lines))
        return nextQuickTextResponse
    }

    func typeSession(_ target: String?, window: String?,
                     options: ControlSessionTypeOptions) async -> ControlResponse {
        calls.append(.sessionType(target: target, window: window, options))
        return nextSessionTypeResponse
    }

    func copySessionSelection(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionCopy(target: target, window: window))
        return nextSessionCopyResponse
    }

    func pasteSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionPaste(target: target, window: window))
        return nextSessionPasteResponse
    }

    func selectAllSession(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.sessionSelectAll(target: target, window: window))
        return nextSessionSelectAllResponse
    }

    func searchSession(_ target: String?, window: String?,
                       text: String?, to: String?) async -> ControlResponse {
        calls.append(.sessionSearch(target: target, window: window, text: text, to: to))
        return nextSessionSearchResponse
    }

    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        calls.append(.overlayOpen(target: target, window: window, options))
        return nextOverlayOpenResponse
    }

    func closeSessionOverlay(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.overlayClose(target: target, window: window))
        return nextOverlayCloseResponse
    }

    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse {
        calls.append(.overlayResize(target: target, window: window, sizePercent: sizePercent))
        return nextOverlayResizeResponse
    }

    func sessionOverlayResult(_ target: String?, window: String?) -> ControlResponse {
        calls.append(.overlayResult(target: target, window: window))
        return nextOverlayResultResponse
    }

    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse {
        calls.append(.sessionBackground(target: target, window: window, options))
        return nextSessionBackgroundResponse
    }

    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse {
        calls.append(.sessionText(target: target, window: window, options))
        return nextSessionTextResponse
    }

    func windowNew(name: String?) -> ControlResponse {
        calls.append(.windowNew(name))
        return nextWindowNewResponse
    }

    func windowList() -> ControlResponse {
        calls.append(.windowList)
        return nextWindowListResponse
    }

    func windowSelect(_ target: String?) async -> ControlResponse {
        calls.append(.windowSelect(target: target))
        return nextWindowSelectResponse
    }

    func windowClose(_ target: String?) async -> ControlResponse {
        calls.append(.windowClose(target: target))
        return nextWindowCloseResponse
    }

    func windowRename(_ target: String?, name: String) -> ControlResponse {
        calls.append(.windowRename(target: target, name))
        return nextWindowRenameResponse
    }

    func windowDelete(_ target: String?) -> ControlResponse {
        calls.append(.windowDelete(target: target))
        return nextWindowDeleteResponse
    }

    func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse {
        calls.append(.windowResize(target: target, width: width, height: height))
        return nextWindowResizeResponse
    }

    func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse {
        calls.append(.windowMove(target: target, x: x, y: y, display: display))
        return nextWindowMoveResponse
    }

    func windowZoom(_ target: String?) -> ControlResponse {
        calls.append(.windowZoom(target: target))
        return nextWindowZoomResponse
    }

    func windowFullscreen(_ target: String?) -> ControlResponse {
        calls.append(.windowFullscreen(target: target))
        return nextWindowFullscreenResponse
    }

    func clearRestoreCommands() -> ControlResponse {
        calls.append(.restoreClear)
        return nextRestoreClearResponse
    }
}
