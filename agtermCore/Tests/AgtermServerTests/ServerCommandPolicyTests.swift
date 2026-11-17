import Testing
@testable import AgtermServerKit
import agtermCore

struct ServerCommandPolicyTests {
    @Test(arguments: [Command.tree, .version, .windowList, .eventsRead, .sessionMove, .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle,
                      .sessionOverlayFollow, .sessionOverlaySearch, .sessionOverlayWrap, .sessionOverlayExpand, .sessionOverlayChanges, .sessionOverlayFiles, .sessionPage,
                      .sessionCompanionPage, .sessionCompanionPageAttach, .surfaceCursor, .zmxList, .zmxScreen, .sessionFlag, .sessionTint,
                      .workspaceFlag, .workspaceTint, .sessionDuplicate, .sessionRestart,
                      .sessionCompanionDuplicate, .sessionCompanionConvert, .sessionCompanionMove, .zmxKill, .zmxPrune, .sessionTerminate, .zmxKillPane])
    func aServedCommandPasses(_ command: Command) {
        #expect(ServerCommandPolicy.refusal(command) == nil)
    }

    @Test func aWindowCommandIsRefusedWithTheWindowReason() {
        #expect(ServerCommandPolicy.refusal(.windowNew) == HeadlessCommandPolicy.physicalWindowRefusal(.windowNew))
    }

    private static let refusedByDesign: [String: Set<Command>] = [
        "Mac view state of a server window": [
            .sessionBackground, .sessionCollapse, .sessionExpand, .workspaceFocus, .workspaceFilter,
            .sessionDetach, .sessionReattach, .workspaceDetach, .workspaceReattach, .workspaceCollapse, .workspaceExpand,
            .windowRemoteDismiss,
        ],
        "Mac selection and clipboard": [.sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch, .sessionOverlayCopy, .sessionOverlayText],
        "moves what a Mac shows": [.sessionFocus, .sessionSelect, .sessionGo, .sessionLead, .sessionResize, .workspaceSelect, .workspaceGo],
        "Finder on the Mac": [.sessionReveal],
        "Mac app relaunch": [.restoreMode, .restoreCapture, .restoreClear, .zmxReset, .sessionRestore],
        "the Mac app's own updater": [.updateCheck],
        "makes a Mac viewer": [.zmxAttach, .zmxAttachGroup],
        "UI-test seam": [.debugAppearance],
        "deferred to docs/backlog/server-user-event-hooks.md": [.hooksList, .hooksReload],
    ]

    @Test func everyCommandIsServedWindowOnlyOrRefusedByDesign() {
        let misclassified = Command.allCases.filter { command in
            let places = [ServerCommandPolicy.served.contains(command), HeadlessCommandPolicy.physicalWindowRefusal(command) != nil]
                + Self.refusedByDesign.values.map { $0.contains(command) }
            return places.count { $0 } != 1
        }

        #expect(misclassified.map(\.rawValue) == [])
    }

    @Test func aCommandRefusedByDesignIsRefusedByName() {
        for command in Self.refusedByDesign.values.flatMap({ $0 }) {
            #expect(ServerCommandPolicy.refusal(command) == "\(command.rawValue) is not available on agterm-server")
        }
    }
}
