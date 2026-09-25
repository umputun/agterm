import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class PaneLeadTests: XCTestCase {
    private var panes: [UUID] = []
    private var reattached: [(view: GhosttySurfaceView, claim: Bool)] = []

    override func setUp() async throws {
        try await super.setUp()
        PaneLead.reattach = { [unowned self] view, claim in reattached.append((view, claim)) }
    }

    override func tearDown() async throws {
        panes.forEach(ZmxLeadBook.shared.forget)
        PaneLead.reattach = nil
        PaneLead.roleChanged = nil
        panes.forEach(RemoteReconnectBook.shared.cancel)
        PaneLead.waitToReconnect = nil
        try await super.tearDown()
    }

    private func pane(nonce: String = "n") -> (GhosttySurfaceView, UUID) {
        let identity = UUID()
        panes.append(identity)
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                      env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: nonce, claim: true), pane: identity)
        return (view, identity)
    }

    private func notice(_ body: String) throws -> ZmxLeadNotice {
        try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;" + body))
    }

    private func key(_ type: NSEvent.EventType, code: UInt16, repeating: Bool = false,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "a",
                                       charactersIgnoringModifiers: "a", isARepeat: repeating, keyCode: code))
    }

    func testAReportCoversThePaneAndALeaderReportUncoversIt() throws {
        let (view, _) = pane()
        var changed = 0
        PaneLead.roleChanged = { _ in changed += 1 }

        PaneLead.report(try notice("n:follower:1"), from: view)
        XCTAssertTrue(view.leadCovered)
        PaneLead.report(try notice("n:follower:1"), from: view)
        PaneLead.report(try notice("n:leader:2"), from: view)

        XCTAssertFalse(view.leadCovered)
        XCTAssertEqual(changed, 2, "a repeated report changes nothing")
        XCTAssertTrue(reattached.isEmpty)
    }

    func testAnUnownedSessionIsReattachedWithoutTheClaim() throws {
        let (view, _) = pane()

        PaneLead.report(try notice("n:unowned:3"), from: view)

        XCTAssertEqual(reattached.map(\.claim), [false],
                       "so it cannot take a lead someone claimed while it was on its way")
        XCTAssertTrue(reattached.first?.view === view)
    }

    func testAReportFromAReplacedOrForgedAttachmentIsDropped() throws {
        let (view, _) = pane(nonce: "current")

        PaneLead.report(try notice("previous:unowned:9"), from: view)

        XCTAssertFalse(view.leadCovered)
        XCTAssertTrue(reattached.isEmpty)
    }

    func testTheFirstKeyOnACoveredPaneTakesTheLeadAndIsSwallowedUntilReleased() throws {
        let (view, identity) = pane()
        PaneLead.report(try notice("n:follower:1"), from: view)

        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0), in: view))
        XCTAssertEqual(reattached.map(\.claim), [true])

        // the app's re-attach starts a fresh attachment, covered until its first report
        let fresh = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                       env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "fresh", claim: true), pane: identity, reattaching: true)
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 1), in: fresh), "typed while taking over is not replayed")
        XCTAssertEqual(reattached.count, 1, "and asks for no second attach")

        PaneLead.report(try notice("fresh:leader:2"), from: fresh)
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0, repeating: true), in: fresh))
        XCTAssertTrue(PaneLead.consumes(try key(.keyUp, code: 0), in: fresh))
        XCTAssertFalse(PaneLead.consumes(try key(.keyDown, code: 0), in: fresh), "the next press is the program's")
        XCTAssertFalse(PaneLead.consumes(try key(.keyUp, code: 0), in: fresh))
    }

    // the release can land on the destroyed old view and never reach `consumes`.
    func testATakeoverKeyWhoseReleaseWasNeverSeenDoesNotSwallowItsNextPress() throws {
        let (view, identity) = pane()
        PaneLead.report(try notice("n:follower:1"), from: view)
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0), in: view))
        let fresh = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                       env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "fresh", claim: true), pane: identity)
        PaneLead.report(try notice("fresh:leader:2"), from: fresh)

        XCTAssertFalse(PaneLead.consumes(try key(.keyDown, code: 0), in: fresh))
        XCTAssertFalse(PaneLead.consumes(try key(.keyDown, code: 0, repeating: true), in: fresh))
        XCTAssertFalse(PaneLead.consumes(try key(.keyUp, code: 0), in: fresh))
    }

    func testACommandChordOnACoveredPaneIsSwallowedWithoutTakingTheLead() throws {
        let (view, _) = pane()
        PaneLead.report(try notice("n:follower:1"), from: view)

        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 9, flags: .command), in: view))

        XCTAssertTrue(reattached.isEmpty)
    }

    func testAnUncoveredPanesKeysAreItsOwn() throws {
        let (view, _) = pane()
        PaneLead.report(try notice("n:leader:1"), from: view)

        XCTAssertFalse(PaneLead.consumes(try key(.keyDown, code: 0), in: view))
        XCTAssertFalse(PaneLead.consumes(try key(.keyUp, code: 0), in: view))
    }

    func testALostLinkFromTheCurrentAttachmentParksThePaneCoveredWhenItHadReportedARole() throws {
        var parked: [(GhosttySurfaceView, Bool)] = []
        PaneLead.waitToReconnect = { parked.append(($0, $1)) }
        let (reporting, _) = pane(nonce: "a")
        PaneLead.report(try notice("a:leader:1"), from: reporting)
        let (silent, _) = pane(nonce: "b")

        PaneLead.linkLost(try XCTUnwrap(RemoteLinkNotice(title: "agterm-remote;a:lost")), from: reporting)
        PaneLead.linkLost(try XCTUnwrap(RemoteLinkNotice(title: "agterm-remote;b:lost")), from: silent)

        XCTAssertEqual(parked.map(\.0), [reporting, silent])
        XCTAssertEqual(parked.map(\.1), [true, false])
    }

    func testAReconnectThatLostTheLinkBeforeItsFirstReportStillParksCovered() throws {
        var parked: [Bool] = []
        PaneLead.waitToReconnect = { parked.append($1) }
        let (view, identity) = pane(nonce: "old")
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "fresh", claim: false), pane: identity, reattaching: true)

        PaneLead.linkLost(try XCTUnwrap(RemoteLinkNotice(title: "agterm-remote;fresh:lost")), from: view)

        XCTAssertEqual(parked, [true])
    }

    func testALostLinkWithAnotherAttachmentsNonceIsDropped() throws {
        var parked = 0
        PaneLead.waitToReconnect = { _, _ in parked += 1 }
        let (view, _) = pane(nonce: "current")

        PaneLead.linkLost(try XCTUnwrap(RemoteLinkNotice(title: "agterm-remote;forged:lost")), from: view)

        XCTAssertEqual(parked, 0)
    }

    func testAKeyOnAWaitingPaneRetriesNowAndNeverReachesTheTerminal() throws {
        let (view, identity) = pane()
        let book = RemoteReconnectBook.shared
        book.wait(pane: identity, session: UUID(), host: "mini", cover: false, now: Date())
        _ = book.due(now: Date())
        _ = book.finished(pane: identity, ok: false, now: Date().addingTimeInterval(3600))

        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0), in: view))
        XCTAssertTrue(PaneLead.consumes(try key(.keyUp, code: 0), in: view))
        XCTAssertFalse(PaneLead.consumes(try key(.keyDown, code: 13, flags: .command), in: view), "a Command chord reaches Ghostty's keybinds")

        XCTAssertEqual(book.due(now: Date()), [identity])
        XCTAssertTrue(reattached.isEmpty, "a retry is a probe, never a claim")
    }
}
