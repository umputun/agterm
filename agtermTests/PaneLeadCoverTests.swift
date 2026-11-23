import XCTest
@testable import agterm
@testable import agtermCore

@MainActor
final class PaneLeadCoverTests: XCTestCase {
    private let pane = UUID()
    private let session = UUID()

    override func tearDown() async throws {
        RemoteReconnectBook.shared.cancel(pane: pane)
        RemoteEndBook.shared.clear(pane: pane)
    }

    func testAPaneWaitingToReconnectShowsTheReconnectingNoticeWithItsReason() {
        RemoteReconnectBook.shared.wait(pane: pane, session: session, host: "mini", cover: false, now: Date())
        XCTAssertEqual(RemotePaneNotice.Kind(identity: pane, host: "mini", keyCloses: true), .reconnecting(host: "mini", reason: nil))

        let due = RemoteReconnectBook.shared.due(now: .distantFuture)
        XCTAssertEqual(due, [pane])
        _ = RemoteReconnectBook.shared.finished(pane: pane, ok: false, stderr: "Connection refused\n", now: Date())

        XCTAssertEqual(RemotePaneNotice.Kind(identity: pane, host: "mini", keyCloses: true),
                       .reconnecting(host: "mini", reason: "Connection refused"))
    }

    func testAnEndedPaneShowsTheEndedNoticeOnlyOnceShown() {
        RemoteEndBook.shared.settle(pane: pane, session: session, host: "mini", name: "build")
        XCTAssertNil(RemotePaneNotice.Kind(identity: pane, host: "mini", keyCloses: true))

        RemoteEndBook.shared.resolved(session: session)

        XCTAssertEqual(RemotePaneNotice.Kind(identity: pane, host: "mini", keyCloses: true), .ended(name: "build", host: "mini", keyCloses: true))
        XCTAssertEqual(RemotePaneNotice.Kind(identity: pane, host: "mini", keyCloses: false),
                       .ended(name: "build", host: "mini", keyCloses: false))
    }

    func testTheCoverTitleSaysTakingOverOnlyForAnAttachThatClaimsTheLead() throws {
        let reconnect = ZmxLeadState(attachment: ZmxLeadAttachment(claim: false), reattaching: true)
        XCTAssertEqual(PaneLeadCover.title(state: reconnect, remote: true), "Reconnecting…")

        var takeover = ZmxLeadState(attachment: ZmxLeadAttachment(claim: true), reattaching: true)
        XCTAssertEqual(PaneLeadCover.title(state: takeover, remote: true), "Taking over…")

        let report = try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;\(takeover.attachment.nonce):follower:1"))
        XCTAssertTrue(takeover.apply(report))
        XCTAssertEqual(PaneLeadCover.title(state: takeover, remote: true), "In use on the Mac it runs on")
        XCTAssertEqual(PaneLeadCover.title(state: takeover, remote: false), "In use from another Mac")

        var unowned = ZmxLeadState(attachment: ZmxLeadAttachment(claim: false))
        let left = try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;\(unowned.attachment.nonce):unowned:2"))
        XCTAssertTrue(unowned.apply(left))
        XCTAssertEqual(PaneLeadCover.title(state: unowned, remote: true), "Reconnecting…")
    }

    func testTheCoverOffersTheTakeoverOnlyWhereAKeyOrClickCanTakeIt() {
        let offer = "Press any key or click to use it here"
        let follower = ZmxLeadState(attachment: ZmxLeadAttachment(claim: true))
        XCTAssertEqual(PaneLeadCover.hint(state: follower, interactive: true), offer)
        XCTAssertEqual(PaneLeadCover.hint(state: nil, interactive: true), offer)

        let reconnect = ZmxLeadState(attachment: ZmxLeadAttachment(claim: false), reattaching: true)
        XCTAssertEqual(PaneLeadCover.hint(state: reconnect, interactive: true), offer)

        let takeover = ZmxLeadState(attachment: ZmxLeadAttachment(claim: true), reattaching: true)
        XCTAssertNil(PaneLeadCover.hint(state: takeover, interactive: true))

        XCTAssertNil(PaneLeadCover.hint(state: follower, interactive: false), "a dashboard cell owns the click and the keys")
    }

    func testAPaneWithNothingToSayShowsNoNotice() {
        XCTAssertNil(RemotePaneNotice.Kind(identity: pane, host: "mini", keyCloses: true))
        XCTAssertNil(RemotePaneNotice.Kind(identity: nil, host: "mini", keyCloses: true))
    }
}
