import Foundation
import Testing
@testable import agtermCore

struct LaunchHandoffTests {
    #if canImport(Darwin)
    private static let getURL: UInt32 = 0x4755_524C

    private static func event(_ eventClass: UInt32, _ eventID: UInt32) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(eventClass), eventID: AEEventID(eventID), targetDescriptor: nil,
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    @Test(arguments: [
        (getURL, getURL, false, true),
        (getURL, getURL, true, false),
        (UInt32(kCoreEventClass), UInt32(kAEOpenDocuments), false, true),
        (UInt32(kCoreEventClass), UInt32(kAEOpenDocuments), true, false),
        (UInt32(kCoreEventClass), UInt32(kAEQuitApplication), false, false),
        (getURL, UInt32(kAEOpenDocuments), false, false),
    ])
    func onlyAnOpenEventBeforeLaunchFinishesIsAHandoff(eventClass: UInt32, eventID: UInt32, finished: Bool, expected: Bool) {
        #expect(LaunchHandoff.isHandoff(event: Self.event(eventClass, eventID), launchFinished: finished) == expected)
    }

    @Test func noEventIsNoHandoff() {
        #expect(!LaunchHandoff.isHandoff(event: nil, launchFinished: false))
    }
    #endif
}
