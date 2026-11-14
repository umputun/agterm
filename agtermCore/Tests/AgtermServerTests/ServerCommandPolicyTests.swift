import Testing
@testable import AgtermServerKit
import agtermCore

struct ServerCommandPolicyTests {
    @Test(arguments: [Command.tree, .version, .windowList, .sessionMove, .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle,
                      .sessionOverlayFollow, .sessionOverlaySearch, .sessionOverlayWrap, .sessionOverlayChanges, .sessionOverlayFiles,
                      .sessionPage, .sessionCompanionPage, .sessionCompanionPageAttach])
    func aServedCommandPasses(_ command: Command) {
        #expect(ServerCommandPolicy.refusal(command) == nil)
    }

    @Test func aWindowCommandIsRefusedWithTheWindowReason() {
        #expect(ServerCommandPolicy.refusal(.windowNew) == HeadlessCommandPolicy.physicalWindowRefusal(.windowNew))
    }

    @Test(arguments: [Command.zmxPrune, .zmxReset, .restoreCapture, .eventsRead])
    func anyOtherCommandIsRefusedByName(_ command: Command) {
        #expect(ServerCommandPolicy.refusal(command) == "\(command.rawValue) is not available on agterm-server")
    }

    private static let undecided: Set<Command> = [
        .debugAppearance, .eventsRead, .hooksList, .hooksReload, .recentClear, .recentList, .recentOpen,
        .restoreCapture, .restoreClear, .restoreMode,
        .sessionBackground, .sessionCollapse, .sessionCompanionConvert, .sessionCompanionDuplicate, .sessionCopy, .sessionDetach,
        .sessionDuplicate, .sessionExpand, .sessionFlag, .sessionFocus, .sessionGo, .sessionInfo, .sessionLead,
        .sessionOverlayCopy, .sessionOverlayText, .sessionPaste, .sessionReattach, .sessionResize, .sessionRestart,
        .sessionRestore, .sessionReveal, .sessionSearch, .sessionSeen, .sessionSelect, .sessionSelectAll, .sessionTint,
        .windowRemoteDismiss,
        .workspaceCollapse, .workspaceDetach, .workspaceExpand, .workspaceFilter, .workspaceFlag, .workspaceFocus, .workspaceGo,
        .workspaceReattach, .workspaceSelect, .workspaceTint,
        .zmxAttach, .zmxAttachGroup, .zmxKill, .zmxList, .zmxPrune, .zmxReset, .zmxScreen,
    ]

    @Test func everyCommandIsServedWindowOnlyOrUndecided() {
        let misclassified = Command.allCases.filter { command in
            [ServerCommandPolicy.served.contains(command), HeadlessCommandPolicy.physicalWindowRefusal(command) != nil,
             Self.undecided.contains(command)].count { $0 } != 1
        }

        #expect(misclassified.map(\.rawValue) == [])
    }
}
