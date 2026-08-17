import Foundation
import Testing
@testable import agtermCore

struct QuitReasonTests {
    /// The quit event AppKit hands `applicationShouldTerminate`, carrying `reason` under
    /// `kAEQuitReason`, or no reason attribute at all when `reason` is nil.
    private func quitEvent(reason: String?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            let code = reason.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            event.setAttribute(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(kAEQuitReason))
        }
        return event
    }

    /// Reads the reason off a real event, which is what a keyword built from a string cannot do:
    /// `AEKeyword("why?")` is `UInt32.init?(String)` and always nil, so the check it guarded never ran.
    @Test(arguments: ["shut", "rest", "rlgo"])
    func systemQuitEventSkipsConfirmation(reason: String) {
        #expect(QuitReason.isSystemQuit(quitEvent(reason: reason)))
    }

    @Test func scriptedQuitEventKeepsConfirmation() {
        #expect(!QuitReason.isSystemQuit(quitEvent(reason: "quia")))
    }

    @Test func anEventWithoutAReasonKeepsConfirmation() {
        #expect(!QuitReason.isSystemQuit(quitEvent(reason: nil)))
    }

    @Test func noEventKeepsConfirmation() {
        #expect(!QuitReason.isSystemQuit(nil))
    }

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
