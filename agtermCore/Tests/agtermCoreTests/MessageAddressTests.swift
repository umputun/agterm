import Foundation
import Testing
@testable import agtermCore

struct MessageAddressTests {
    private static let session = "C8A3AD57-5ABC-4715-9EF1-62DBFD03F541"
    private static let pane = UUID(uuidString: "DA8C8908-18DD-4A3F-BCA4-3C90C80BEF78")!

    @Test func aRecipientTakesAPaneID() throws {
        let address = try MessageAddress.recipient("\(Self.session):\(Self.pane.uuidString)")
        #expect(address == MessageAddress(session: Self.session, pane: .id(Self.pane)))
    }

    @Test func aPaneIDMatchesInAnyCase() throws {
        let address = try MessageAddress.identity("\(Self.session):\(Self.pane.uuidString.lowercased())")
        #expect(address.pane == .id(Self.pane))
    }

    @Test(arguments: [("left", StatusPane.left), ("right", .right), ("scratch", .scratch), ("primary", .left)])
    func aRecipientTakesARole(name: String, role: StatusPane) throws {
        #expect(try MessageAddress.recipient("\(Self.session):\(name)").pane == .role(role))
    }

    @Test func anIdentityRefusesARole() {
        #expect(throws: MessageAddressError.roleIdentity("\(Self.session):right")) {
            try MessageAddress.identity("\(Self.session):right")
        }
    }

    @Test func aBareSessionIsRefused() {
        #expect(throws: MessageAddressError.bareSession(Self.session)) { try MessageAddress.recipient(Self.session) }
        #expect(throws: MessageAddressError.bareSession(Self.session)) { try MessageAddress.identity(Self.session) }
    }

    @Test(arguments: [":left", "\(session):", "\(session):nope", "\(session):left:extra", ""])
    func aMalformedAddressIsRefused(text: String) {
        #expect(throws: MessageAddressError.malformed(text)) { try MessageAddress.recipient(text) }
    }

    @Test func theCanonicalFormNamesSessionAndPaneID() {
        #expect(MessageAddress.canonical(session: UUID(uuidString: Self.session)!, pane: Self.pane)
            == "\(Self.session):\(Self.pane.uuidString)")
    }
}
