import Testing
@testable import agtermCore

struct QuitReasonTests {
    @Test(arguments: ["shut", "rest", "rlgo"])
    func systemQuitSkipsConfirmation(reason: String) {
        let typeCode = reason.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(QuitReason.skipsConfirmation(typeCode: typeCode))
    }

    @Test func scriptedQuitKeepsConfirmation() {
        let quitAll = "quia".utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(!QuitReason.skipsConfirmation(typeCode: quitAll))
    }
}
