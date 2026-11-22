import Foundation
import Testing
@testable import agtermCore

struct ZmxLeadTests {
    @Test func attachmentEnvironmentCarriesTheClaimOnlyWhenAsked() {
        let claiming = ZmxLeadAttachment(nonce: "n1", claim: true)
        let recovering = ZmxLeadAttachment(nonce: "n2", claim: false)

        #expect(claiming.environment == ["ZMX_MANAGED": "n1", "ZMX_MANAGED_CLAIM": "1"])
        #expect(claiming.assignments == ["ZMX_MANAGED=n1", "ZMX_MANAGED_CLAIM=1"])
        #expect(recovering.environment == ["ZMX_MANAGED": "n2"])
    }

    @Test func attachmentEnvironmentNamesTheAttachItTakesTheLeadBackFrom() {
        let reconnecting = ZmxLeadAttachment(nonce: "n2", claim: false, reclaim: "n1")

        #expect(reconnecting.environment == ["ZMX_MANAGED": "n2", "ZMX_MANAGED_RECLAIM": "n1"])
        #expect(reconnecting.assignments == ["ZMX_MANAGED=n2", "ZMX_MANAGED_RECLAIM=n1"])
    }

    @Test func aDropReclaimsFromALeadingAttachOrTheOneAnUnreportedReconnectWasReclaiming() throws {
        var leading = ZmxLeadState(attachment: ZmxLeadAttachment(nonce: "n1", claim: false))
        #expect(leading.reclaimAfterDrop == nil)
        _ = leading.apply(try #require(ZmxLeadNotice(title: "zmx-role;n1:leader:2")))
        #expect(leading.reclaimAfterDrop == "n1")

        let claiming = ZmxLeadState(attachment: ZmxLeadAttachment(nonce: "n3", claim: true))
        #expect(claiming.reclaimAfterDrop == "n3")

        var following = ZmxLeadState(attachment: ZmxLeadAttachment(nonce: "n2", claim: false, reclaim: "n1"))
        #expect(following.reclaimAfterDrop == "n1")
        _ = following.apply(try #require(ZmxLeadNotice(title: "zmx-role;n2:follower:3")))
        #expect(following.reclaimAfterDrop == nil)
    }

    @Test func generatedNonceIsAPlainTokenZmxAccepts() {
        let nonce = ZmxLeadAttachment.makeNonce()

        #expect(nonce.count == 32)
        #expect(nonce.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLowercase) })
    }

    @Test(arguments: [
        ("zmx-role;n1:leader:7", ZmxLeadRole.leader, UInt32(7)),
        ("zmx-role;n1:follower:0", .follower, 0),
        ("zmx-role;n1:unowned:4294967295", .unowned, UInt32.max),
    ])
    func noticeParsesTheReservedTitle(title: String, role: ZmxLeadRole, generation: UInt32) throws {
        let notice = try #require(ZmxLeadNotice(title: title))

        #expect(notice.nonce == "n1")
        #expect(notice.role == role)
        #expect(notice.generation == generation)
    }

    @Test(arguments: [
        "vim README.md",
        "zmx-role",
        "my zmx-role;n1:leader:7",
        "zmx-role;n1:leader",
        "zmx-role;n1:owner:7",
        "zmx-role;n1:leader:-1",
        "zmx-role;:leader:7",
        "zmx-role;n1:leader:7:extra",
    ])
    func noticeLeavesEveryOtherTitleAlone(title: String) {
        #expect(ZmxLeadNotice(title: title) == nil)
    }

    @Test func stateStaysUnknownUntilTheFirstReport() throws {
        var state = ZmxLeadState(attachment: ZmxLeadAttachment(nonce: "n1", claim: true))
        #expect(state.role == nil)
        #expect(!state.covered)

        #expect(state.apply(try #require(ZmxLeadNotice(title: "zmx-role;n1:follower:3"))))
        #expect(state.covered)
        #expect(state.apply(try #require(ZmxLeadNotice(title: "zmx-role;n1:leader:4"))))
        #expect(!state.covered)
    }

    @Test func stateDropsAnotherAttachmentsReportAndAnOlderGeneration() throws {
        var state = ZmxLeadState(attachment: ZmxLeadAttachment(nonce: "n1", claim: true))
        #expect(state.apply(try #require(ZmxLeadNotice(title: "zmx-role;n1:leader:5"))))

        #expect(!state.apply(try #require(ZmxLeadNotice(title: "zmx-role;forged:follower:9"))))
        #expect(!state.apply(try #require(ZmxLeadNotice(title: "zmx-role;n1:follower:4"))))
        #expect(!state.apply(try #require(ZmxLeadNotice(title: "zmx-role;n1:leader:6"))))
        #expect(state.role == .leader)
    }

    @Test func reattachingStaysCoveredUntilItsFirstReportEvenWhenTheRoleRepeats() throws {
        var state = ZmxLeadState(attachment: ZmxLeadAttachment(nonce: "n2", claim: true), reattaching: true)
        #expect(state.covered)

        #expect(state.apply(try #require(ZmxLeadNotice(title: "zmx-role;n2:leader:8"))))
        #expect(!state.reattaching)
        #expect(!state.covered)
    }

    @MainActor
    @Test func bookReportsEveryChangeAndNothingElse() throws {
        let book = ZmxLeadBook()
        var changes = 0
        book.onChange = { changes += 1 }
        let pane = UUID()
        let leader = try #require(ZmxLeadNotice(title: "zmx-role;a:leader:1"))

        book.begin(ZmxLeadAttachment(nonce: "a", claim: true), pane: pane)
        _ = book.apply(leader, pane: pane)
        _ = book.apply(leader, pane: pane)
        _ = book.apply(leader, pane: UUID())
        book.forget(pane: pane)

        #expect(changes == 3)
    }

    @MainActor
    @Test func bookTracksEachPaneAndCountsAttachments() throws {
        let book = ZmxLeadBook()
        let left = UUID(), right = UUID()
        book.begin(ZmxLeadAttachment(nonce: "a", claim: true), pane: left)
        book.begin(ZmxLeadAttachment(nonce: "b", claim: true), pane: right)

        let follower = try #require(ZmxLeadNotice(title: "zmx-role;a:follower:1"))
        #expect(book.apply(follower, pane: left) == .follower)
        #expect(book.apply(follower, pane: right) == nil)
        #expect(book.apply(follower, pane: UUID()) == nil)
        #expect(book.covered(pane: left))
        #expect(!book.covered(pane: right))
        #expect(book.role(pane: nil) == nil)

        // a fresh attach starts over: the old surface's late report no longer matches
        book.begin(ZmxLeadAttachment(nonce: "c", claim: true), pane: left, reattaching: true)
        #expect(book.attachments == 3)
        #expect(book.reattaching(pane: left))
        #expect(book.apply(follower, pane: left) == nil)

        book.forget(pane: left)
        #expect(!book.covered(pane: left))
    }

    @Test func screenParsesTheHeaderAndKeepsTheTextVerbatim() throws {
        let screen = try #require(ZmxScreen(output: "42 89 60 2 17 1\n> draft\n\nstatus line\n\n   \n"))

        #expect(screen.revision == 42)
        #expect(screen.columns == 89)
        #expect(screen.rows == 60)
        #expect(screen.cursorColumn == 2)
        #expect(screen.cursorRow == 17)
        #expect(screen.alternate)
        #expect(screen.text == "> draft\n\nstatus line\n\n   \n")
        #expect(screen.lastLines(2) == "\nstatus line")
        #expect(screen.lastLines(50) == "> draft\n\nstatus line")
    }

    @Test func blankScreenIsAnEmptyTextNotAFailure() throws {
        #expect(try #require(ZmxScreen(output: "0 80 24 0 0 0\n")).text.isEmpty)
        #expect(try #require(ZmxScreen(output: "0 80 24 0 0 0")).text.isEmpty)
    }

    @Test(arguments: ["", "80 24\ntext", "a b c d e f\ntext", "1 2 3 4 5 -6\ntext", "error: session is unresponsive"])
    func screenRejectsAMalformedReply(output: String) {
        #expect(ZmxScreen(output: output) == nil)
    }

    @MainActor
    @Test func aClaimOnReportIsTakenOnceAndForgottenWithItsPane() {
        let book = ZmxLeadBook()
        let pane = UUID(), gone = UUID()
        book.claimOnReport(pane: pane)
        book.claimOnReport(pane: gone)

        book.forget(pane: gone)

        #expect(book.takeClaim(pane: pane))
        #expect(!book.takeClaim(pane: pane))
        #expect(!book.takeClaim(pane: gone))
    }

    @MainActor
    @Test func anArmedLeadWaitsForThePanesNextAttachAndIsSavedUntilThen() throws {
        let book = ZmxLeadBook()
        let pane = UUID(), gone = UUID(), unused = UUID()
        book.arm([pane: "n1", gone: "n2", unused: "n3"])

        #expect(book.pendingReclaim(pane: pane) == "n1")
        #expect(book.savedLead(pane: pane) == "n1")

        let attach = ZmxLeadAttachment(nonce: "n4", claim: false, reclaim: "n1")
        book.begin(attach, pane: pane)
        book.forget(pane: gone)
        book.disarm([unused])

        #expect(book.pendingReclaim(pane: pane) == nil)
        #expect(book.savedLead(pane: pane) == "n1")
        _ = book.apply(try #require(ZmxLeadNotice(title: "zmx-role;n4:follower:1")), pane: pane)
        book.arm([pane: "n1"])
        #expect(book.savedLead(pane: pane) == nil)
        #expect(book.savedLead(pane: gone) == nil)
        #expect(book.savedLead(pane: unused) == nil)
    }

    @MainActor
    @Test func aPaneParkedToReconnectSavesTheLeadItWillTakeBack() {
        let book = ZmxLeadBook()
        let pane = UUID()
        RemoteReconnectBook.shared.wait(pane: pane, session: UUID(), host: "box", cover: true, reclaim: "n1", now: Date())
        defer { RemoteReconnectBook.shared.cancel(pane: pane) }

        #expect(book.savedLead(pane: pane) == "n1")
    }
}
