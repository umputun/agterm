import Foundation
import Testing
@testable import agtermCore

struct NotificationsTests {
    @Test func identityRoundTripsForEveryPane() {
        let windowID = UUID()
        let sessionID = UUID()
        for pane in PaneRole.allCases {
            let identity = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: pane)
            let parsed = TerminalNotification.parseIdentity(identity)
            #expect(parsed?.windowID == windowID)
            #expect(parsed?.sessionID == sessionID)
            #expect(parsed?.pane == pane)
        }
    }

    @Test func identityFormatIsWindowColonSessionColonRole() {
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let identity = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: .split)
        #expect(identity == "00000000-0000-0000-0000-000000000000:11111111-1111-1111-1111-111111111111:split")
    }

    @Test func controlIdentityFormatIsWindowColonSessionColonNotify() {
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let identity = TerminalNotification.controlIdentity(windowID: windowID, sessionID: sessionID)
        #expect(identity == "00000000-0000-0000-0000-000000000000:11111111-1111-1111-1111-111111111111:notify")
    }

    @Test func controlIdentityIsStableAndNeverCollidesWithPaneIdentities() {
        let windowID = UUID()
        let sessionID = UUID()
        let control = TerminalNotification.controlIdentity(windowID: windowID, sessionID: sessionID)
        #expect(control == TerminalNotification.controlIdentity(windowID: windowID, sessionID: sessionID))
        for pane in PaneRole.allCases {
            #expect(control != TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: pane))
        }
    }

    @Test func controlIdentityParsesToTheMainPane() {
        let windowID = UUID()
        let sessionID = UUID()
        let parsed = TerminalNotification.parseIdentity(TerminalNotification.controlIdentity(windowID: windowID, sessionID: sessionID))
        #expect(parsed?.windowID == windowID)
        #expect(parsed?.sessionID == sessionID)
        #expect(parsed?.pane == .main)
    }

    @Test func sessionIdentitiesCoverEveryPaneAndTheControlSlot() {
        let windowID = UUID()
        let sessionID = UUID()
        let expected = PaneRole.allCases.map { TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: $0) }
            + [TerminalNotification.controlIdentity(windowID: windowID, sessionID: sessionID)]
        let identities = TerminalNotification.sessionIdentities(windowID: windowID, sessionID: sessionID)
        #expect(identities.count == 4)
        #expect(Set(identities) == Set(expected))
    }

    @Test func parseRejectsMalformed() {
        let win = UUID().uuidString
        let sess = UUID().uuidString
        #expect(TerminalNotification.parseIdentity("\(win):not-a-uuid:main") == nil)
        #expect(TerminalNotification.parseIdentity("\(win):\(sess):bogus") == nil)
        #expect(TerminalNotification.parseIdentity("\(win):\(sess):notify:1") == nil)
        #expect(TerminalNotification.parseIdentity("\(win):not-a-uuid:notify") == nil)
        #expect(TerminalNotification.parseIdentity("not-a-uuid:\(sess):main") == nil)
        #expect(TerminalNotification.parseIdentity("\(sess):main") == nil) // missing windowID
        #expect(TerminalNotification.parseIdentity("no-colon") == nil)
        #expect(TerminalNotification.parseIdentity("") == nil)
    }

    @Test func shouldDeliverSuppressesOnlyTheFocusedActivePane() {
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: true, appActive: true) == false)
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: true, appActive: false) == true)
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: false, appActive: true) == true)
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: false, appActive: false) == true)
    }
}
