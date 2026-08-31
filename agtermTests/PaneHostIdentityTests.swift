import agtermCore
import Observation
import XCTest
@testable import agterm

@MainActor
final class PaneHostIdentityTests: XCTestCase {
    private final class InvalidationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }

    private final class Surface: PaneRoleMutableSurface {
        let paneToken: String
        var isRealized = true

        init(_ paneToken: String) {
            self.paneToken = paneToken
        }

        func teardown() {}
        func promoteToPrimaryPane() {}
        func setPaneRole(_: SwappablePaneRole) {}
    }

    private struct Fixture {
        let directory: URL
        let store: AppStore
        let session: Session
        let primary: Surface
        let split: Surface
        let leftOverlay: Surface
        let rightOverlay: Surface
        let scratch: Surface
        let overlay: Surface
    }

    private func makeFixture() -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-pane-host-tests-\(UUID().uuidString)", isDirectory: true)
        let store = AppStore(persistence: PersistenceStore(directory: directory))
        let workspace = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/left")!
        let primary = Surface("primary")
        let split = Surface("split")
        let leftOverlay = Surface("overlay-left")
        let rightOverlay = Surface("overlay-right")
        let scratch = Surface("scratch")
        let overlay = Surface("overlay")
        session.surface = primary
        session.splitSurface = split
        session.hasSplit = true
        session.leftOverlaySurface = leftOverlay
        session.rightOverlaySurface = rightOverlay
        session.scratchSurface = scratch
        session.overlaySurface = overlay
        return Fixture(directory: directory, store: store, session: session, primary: primary, split: split,
                       leftOverlay: leftOverlay, rightOverlay: rightOverlay, scratch: scratch, overlay: overlay)
    }

    private func token(_ surface: TerminalZoomSurface, in session: Session) -> String {
        PaneHostIdentity.token(for: surface, in: session)
    }

    func testDeckOccupantTokensExchangeWithThePanes() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let primary = token(.primary, in: fixture.session)
        let split = token(.split, in: fixture.session)

        XCTAssertNil(fixture.store.swapPanes(fixture.session.id))

        XCTAssertEqual(token(.primary, in: fixture.session), split)
        XCTAssertEqual(token(.split, in: fixture.session), primary)
    }

    func testPaneOverlayOccupantTokensExchangeWithThePanes() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let left = token(.overlayLeft, in: fixture.session)
        let right = token(.overlayRight, in: fixture.session)

        XCTAssertNil(fixture.store.swapPanes(fixture.session.id))

        XCTAssertEqual(token(.overlayLeft, in: fixture.session), right)
        XCTAssertEqual(token(.overlayRight, in: fixture.session), left)
    }

    func testZoomHostInvalidationFiresWhenPanesSwap() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let invalidations = InvalidationCounter()
        withObservationTracking {
            _ = token(.split, in: fixture.session)
        } onChange: {
            invalidations.increment()
        }

        fixture.session.oscTitle = "unrelated"
        XCTAssertEqual(invalidations.value, 0)
        let before = token(.split, in: fixture.session)
        XCTAssertNil(fixture.store.swapPanes(fixture.session.id))

        XCTAssertEqual(invalidations.value, 1)
        XCTAssertNotEqual(token(.split, in: fixture.session), before)
    }

    func testZoomKeepsUnswappedOccupantTokensStable() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let scratch = token(.scratch, in: fixture.session)
        let overlay = token(.overlay, in: fixture.session)

        XCTAssertNil(fixture.store.swapPanes(fixture.session.id))

        XCTAssertEqual(token(.scratch, in: fixture.session), scratch)
        XCTAssertEqual(token(.overlay, in: fixture.session), overlay)
    }

    func testDashboardMembersResolveTheNewSlotOccupants() {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let members = [DashboardMember(session: fixture.session.id, surface: .primary),
                       DashboardMember(session: fixture.session.id, surface: .split)]
        let before = members.map { token($0.surface, in: fixture.session) }

        XCTAssertNil(fixture.store.swapPanes(fixture.session.id))

        XCTAssertEqual(members.map { token($0.surface, in: fixture.session) }, before.reversed())
    }

    func testEmptySlotHasStableToken() {
        let session = Session(initialCwd: "/tmp")
        XCTAssertEqual(token(.primary, in: session), "none")
        XCTAssertEqual(token(.primary, in: session), "none")
    }
}
