import Testing
@testable import AgtermServerKit
import agtermCore

struct ServerCommandPolicyTests {
    @Test(arguments: [Command.tree, .version, .windowList, .sessionMove, .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle,
                      .sessionOverlayFollow, .sessionOverlaySearch, .sessionOverlayWrap, .sessionOverlayChanges, .sessionPage,
                      .sessionCompanionPage, .sessionCompanionPageAttach])
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
}
