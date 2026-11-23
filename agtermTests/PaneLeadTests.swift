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

    func testAKeyOnAReconnectThatClaimsNothingTakesTheLeadOnItsFirstReport() throws {
        let identity = UUID()
        panes.append(identity)
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                      env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: false), pane: identity, reattaching: true)

        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0), in: view))
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0, repeating: true), in: view))
        XCTAssertTrue(reattached.isEmpty, "the reattach on its way is not replaced")

        PaneLead.report(try notice("n:follower:1"), from: view)
        XCTAssertEqual(reattached.map(\.claim), [true])
        XCTAssertTrue(PaneLead.consumes(try key(.keyUp, code: 0), in: view), "the press stays swallowed until released")
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

    func testAClickOnAnUnfocusedCoveredPaneFocusesItBeforeTheTakeover() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let identity = UUID()
        panes.append(identity)
        let focused = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        let covered = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat",
                                         env: ["AGTERM_PANE_ID": identity.uuidString])
        defer {
            focused.teardown()
            covered.teardown()
        }
        focused.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        covered.frame = CGRect(x: 300, y: 0, width: 300, height: 300)
        window.contentView?.addSubview(focused)
        window.contentView?.addSubview(covered)
        focused.createSurface()
        covered.createSurface()
        XCTAssertNotNil(covered.surface)
        window.makeFirstResponder(focused)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: identity)
        PaneLead.report(try notice("n:follower:1"), from: covered)
        var heldFocus: [Bool] = []
        PaneLead.reattach = { view, _ in heldFocus.append(view.window?.firstResponder === view) }

        PaneLead.coverClicked(covered)

        XCTAssertEqual(heldFocus, [true], "the replacement takes focus only from a surface that holds it")
    }

    func testAClickOnACoveredPaneTakesTheLeadOnceWhileTheTakeoverIsOnItsWay() throws {
        let (view, identity) = pane()
        PaneLead.report(try notice("n:follower:1"), from: view)

        PaneLead.coverClicked(view)
        XCTAssertEqual(reattached.map(\.claim), [true])

        let fresh = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                       env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "fresh", claim: true), pane: identity, reattaching: true)
        PaneLead.coverClicked(fresh)
        XCTAssertEqual(reattached.count, 1)
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 1), in: fresh))
        XCTAssertEqual(reattached.count, 1)

        PaneLead.report(try notice("fresh:leader:2"), from: fresh)
        XCTAssertFalse(PaneLead.consumes(try key(.keyDown, code: 1), in: fresh), "the next press is the program's")
    }

    func testAClickOnALeadingPaneTakesNothing() throws {
        let (view, _) = pane()
        PaneLead.report(try notice("n:leader:1"), from: view)

        PaneLead.coverClicked(view)

        XCTAssertTrue(reattached.isEmpty)
    }

    func testAClickOnAReconnectThatClaimsNothingTakesTheLeadOnItsFirstReport() throws {
        let identity = UUID()
        panes.append(identity)
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                      env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: false), pane: identity, reattaching: true)

        PaneLead.coverClicked(view)
        XCTAssertTrue(reattached.isEmpty)

        PaneLead.report(try notice("n:follower:1"), from: view)
        XCTAssertEqual(reattached.map(\.claim), [true])
    }

    func testAClickOnACoveredPaneWaitingToReconnectRetriesNowWithoutTakingTheLead() throws {
        let (view, identity) = pane()
        PaneLead.report(try notice("n:follower:1"), from: view)
        let book = RemoteReconnectBook.shared
        book.wait(pane: identity, session: UUID(), host: "mini", cover: true, now: Date())
        _ = book.due(now: Date())
        _ = book.finished(pane: identity, ok: false, now: Date().addingTimeInterval(3600))
        XCTAssertTrue(view.leadCovered)

        PaneLead.coverClicked(view)

        XCTAssertEqual(book.due(now: Date()), [identity])
        XCTAssertTrue(reattached.isEmpty, "a retry is a probe, never a claim")
    }

    func testAClickOnTheReconnectNoticeRetriesNow() {
        let (view, identity) = pane()
        let book = RemoteReconnectBook.shared
        book.wait(pane: identity, session: UUID(), host: "mini", cover: false, now: Date())
        _ = book.due(now: Date())
        _ = book.finished(pane: identity, ok: false, now: Date().addingTimeInterval(3600))

        PaneLead.noticeClicked(view)

        XCTAssertEqual(book.due(now: Date()), [identity])
        XCTAssertTrue(reattached.isEmpty)
    }

    func testAClickOnTheReconnectNoticeOfAPaneNoLongerWaitingTakesNothing() throws {
        let (view, _) = pane()
        PaneLead.report(try notice("n:follower:1"), from: view)

        PaneLead.noticeClicked(view)

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
        PaneLead.waitToReconnect = { view, cover, _ in parked.append((view, cover)) }
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
        PaneLead.waitToReconnect = { _, cover, _ in parked.append(cover) }
        let (view, identity) = pane(nonce: "old")
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "fresh", claim: false), pane: identity, reattaching: true)

        PaneLead.linkLost(try XCTUnwrap(RemoteLinkNotice(title: "agterm-remote;fresh:lost")), from: view)

        XCTAssertEqual(parked, [true])
    }

    func testALostLinkParksWithTheNonceOfTheAttachThatLed() throws {
        var reclaims: [String?] = []
        PaneLead.waitToReconnect = { _, _, reclaim in reclaims.append(reclaim) }
        let (leading, _) = pane(nonce: "a")
        PaneLead.report(try notice("a:leader:1"), from: leading)
        let (following, _) = pane(nonce: "b")
        PaneLead.report(try notice("b:follower:1"), from: following)

        PaneLead.linkLost(try XCTUnwrap(RemoteLinkNotice(title: "agterm-remote;a:lost")), from: leading)
        PaneLead.linkLost(try XCTUnwrap(RemoteLinkNotice(title: "agterm-remote;b:lost")), from: following)

        XCTAssertEqual(reclaims, ["a", nil])
    }

    func testALostLinkWithAnotherAttachmentsNonceIsDropped() throws {
        var parked = 0
        PaneLead.waitToReconnect = { _, _, _ in parked += 1 }
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

    func testARetryKeyStillHeldThroughTheSwapCannotTakeTheLead() throws {
        let (view, identity) = pane()
        let book = RemoteReconnectBook.shared
        book.wait(pane: identity, session: UUID(), host: "mini", cover: true, now: Date())
        _ = book.due(now: Date())
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0), in: view), "pressed while a probe already runs")
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0, repeating: true), in: view))

        // the host answered: the fresh attach is covered and then reports as a follower
        _ = book.finished(pane: identity, ok: true, now: Date())
        let fresh = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                       env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "fresh", claim: false), pane: identity, reattaching: true)
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0, repeating: true), in: fresh))
        PaneLead.report(try notice("fresh:follower:2"), from: fresh)
        XCTAssertTrue(fresh.leadCovered)

        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0, repeating: true), in: fresh))
        XCTAssertTrue(reattached.isEmpty, "a held retry key never claims the lead")
        XCTAssertTrue(PaneLead.consumes(try key(.keyUp, code: 0), in: fresh))
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0), in: fresh), "a fresh press is the takeover the cover asks for")
        XCTAssertEqual(reattached.map(\.claim), [true])
    }

    func testAKeyHeldSinceBeforeTheDropCannotTakeTheLeadAfterTheSwap() throws {
        let (view, identity) = pane()
        PaneLead.report(try notice("n:leader:1"), from: view)
        XCTAssertFalse(PaneLead.consumes(try key(.keyDown, code: 0), in: view), "pressed while the pane still leads")

        let book = RemoteReconnectBook.shared
        book.wait(pane: identity, session: UUID(), host: "mini", cover: true, now: Date())
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0, repeating: true), in: view), "only repeats arrive while waiting")

        _ = book.due(now: Date())
        _ = book.finished(pane: identity, ok: true, now: Date())
        let fresh = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                       env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "fresh", claim: false), pane: identity, reattaching: true)
        PaneLead.report(try notice("fresh:follower:2"), from: fresh)
        XCTAssertTrue(fresh.leadCovered)

        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0, repeating: true), in: fresh))
        XCTAssertTrue(reattached.isEmpty, "a repeat is never the press the cover asks for")
        XCTAssertTrue(PaneLead.consumes(try key(.keyUp, code: 0), in: fresh))
        XCTAssertTrue(PaneLead.consumes(try key(.keyDown, code: 0), in: fresh))
        XCTAssertEqual(reattached.map(\.claim), [true], "a fresh press still claims")
    }

    func testAPaneOwedAClaimTakesItOnItsFirstReportAsAFollower() throws {
        let (view, identity) = pane()
        ZmxLeadBook.shared.claimOnReport(pane: identity)

        PaneLead.report(try notice("n:follower:1"), from: view)

        XCTAssertEqual(reattached.map(\.claim), [true])
        XCTAssertTrue(reattached.first?.view === view)
        XCTAssertFalse(ZmxLeadBook.shared.takeClaim(pane: identity))
    }

    func testAPaneOwedAClaimThatAlreadyLeadsSpendsIt() throws {
        let (view, identity) = pane()
        ZmxLeadBook.shared.claimOnReport(pane: identity)

        PaneLead.report(try notice("n:leader:1"), from: view)

        XCTAssertTrue(reattached.isEmpty)
        XCTAssertFalse(ZmxLeadBook.shared.takeClaim(pane: identity))
    }
}
