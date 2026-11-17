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
        XCTAssertEqual(RemotePaneNotice.Kind(identity: pane, host: "mini"), .reconnecting(host: "mini", reason: nil))

        let due = RemoteReconnectBook.shared.due(now: .distantFuture)
        XCTAssertEqual(due, [pane])
        _ = RemoteReconnectBook.shared.finished(pane: pane, ok: false, stderr: "Connection refused\n", now: Date())

        XCTAssertEqual(RemotePaneNotice.Kind(identity: pane, host: "mini"),
                       .reconnecting(host: "mini", reason: "Connection refused"))
    }

    func testAnEndedPaneShowsTheEndedNoticeOnlyOnceShown() {
        RemoteEndBook.shared.settle(pane: pane, session: session, host: "mini", name: "build")
        XCTAssertNil(RemotePaneNotice.Kind(identity: pane, host: "mini"))

        RemoteEndBook.shared.resolved(session: session)

        XCTAssertEqual(RemotePaneNotice.Kind(identity: pane, host: "mini"), .ended(name: "build", host: "mini"))
    }

    func testAPaneWithNothingToSayShowsNoNotice() {
        XCTAssertNil(RemotePaneNotice.Kind(identity: pane, host: "mini"))
        XCTAssertNil(RemotePaneNotice.Kind(identity: nil, host: "mini"))
    }
}
