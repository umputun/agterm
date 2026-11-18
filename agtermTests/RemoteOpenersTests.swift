import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemoteOpenersTests: XCTestCase {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_789_000_000) }

    func testOnlyATransferStillReadingIsOverdueAndAStagingClickWaitsForItsSpawn() throws {
        let clock = Clock()
        let openers = RemoteOpeners()
        openers.now = { clock.now }
        openers.rules = { parseKeymap("open *.md mdview").0.openers }
        let (connection, session) = (UUID(), UUID())
        let surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        let reading = try XCTUnwrap(openers.record(raw: "/srv/a.md", connection: connection, session: session, pane: UUID(),
                                                   surface: surface))
        let staging = try XCTUnwrap(openers.record(raw: "/srv/b.md", connection: connection, session: session, pane: UUID(),
                                                   surface: surface))
        for (click, name) in [(reading, "a.md"), (staging, "b.md")] {
            XCTAssertNotNil(openers.accept(PresentationLinkSnapshot(click: click, token: "t", name: name, size: 1),
                                           connection: connection, session: session))
            openers.begin(click, channel: RemotePageChannel()) {}
        }
        openers.endTransfer(staging)

        clock.now = clock.now.addingTimeInterval(PendingOpenerClicks.readDeadline + 1)

        XCTAssertEqual(openers.overdue().map(\.click), [reading])
        XCTAssertTrue(openers.book.contains(staging))
        XCTAssertTrue(openers.surface(for: staging) === surface)
        XCTAssertTrue(openers.finish(staging))
        XCTAssertTrue(openers.isIdle)
    }
}
