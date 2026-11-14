import Testing
@testable import AgtermServerKit
import agtermCore

struct ServerCommandPolicyTests {
    @Test(arguments: [Command.tree, .version, .windowList, .eventsRead, .sessionMove, .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle,
                      .sessionOverlayFollow, .sessionOverlaySearch, .sessionOverlayWrap, .sessionOverlayChanges, .sessionOverlayFiles, .sessionPage,
                      .sessionCompanionPage, .sessionCompanionPageAttach, .surfaceCursor, .zmxList, .zmxScreen])
    func aServedCommandPasses(_ command: Command) {
        #expect(ServerCommandPolicy.refusal(command) == nil)
    }

    @Test func aWindowCommandIsRefusedWithTheWindowReason() {
        #expect(ServerCommandPolicy.refusal(.windowNew) == HeadlessCommandPolicy.physicalWindowRefusal(.windowNew))
    }

    @Test(arguments: [Command.zmxPrune, .zmxReset, .restoreCapture, .hooksList])
    func anyOtherCommandIsRefusedByName(_ command: Command) {
        #expect(ServerCommandPolicy.refusal(command) == "\(command.rawValue) is not available on agterm-server")
    }

    private static let undecided: Set<Command> = [
        .debugAppearance, .hooksList, .hooksReload, .recentClear, .recentList, .recentOpen,
        .restoreCapture, .restoreClear, .restoreMode,
        .sessionBackground, .sessionCollapse, .sessionCompanionConvert, .sessionCompanionDuplicate, .sessionCopy, .sessionDetach,
        .sessionDuplicate, .sessionExpand, .sessionFlag, .sessionFocus, .sessionGo, .sessionLead,
        .sessionOverlayCopy, .sessionOverlayText, .sessionPaste, .sessionReattach, .sessionResize, .sessionRestart,
        .sessionRestore, .sessionReveal, .sessionSearch, .sessionSeen, .sessionSelect, .sessionSelectAll, .sessionTint,
        .windowRemoteDismiss,
        .workspaceCollapse, .workspaceDetach, .workspaceExpand, .workspaceFilter, .workspaceFlag, .workspaceFocus, .workspaceGo,
        .workspaceReattach, .workspaceSelect, .workspaceTint,
        .zmxAttach, .zmxAttachGroup, .zmxKill, .zmxPrune, .zmxReset,
    ]

    @Test func everyCommandIsServedWindowOnlyOrUndecided() {
        let misclassified = Command.allCases.filter { command in
            [ServerCommandPolicy.served.contains(command), HeadlessCommandPolicy.physicalWindowRefusal(command) != nil,
             Self.undecided.contains(command)].count { $0 } != 1
        }

        #expect(misclassified.map(\.rawValue) == [])
    }
}
