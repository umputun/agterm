import Testing
@testable import agtermCore

struct ControlResponseTests {
    @Test func anUndecodableCommandIsTheOnlyRefusalOfAnUnknownCommand() {
        let decodeError = "invalid request: Cannot initialize Command from invalid String value session.companion.new"
        #expect(ControlResponse(ok: false, error: decodeError).refusesUnknown(.sessionCompanionNew))
        let others = ["no session matching p1", "companions of a remote session are not supported yet",
                      "invalid request: Cannot initialize Command from invalid String value session.nope"]
        for error in others {
            #expect(!ControlResponse(ok: false, error: error).refusesUnknown(.sessionCompanionNew), "\(error)")
        }
        #expect(!ControlResponse(ok: true).refusesUnknown(.sessionCompanionNew))
    }
}
