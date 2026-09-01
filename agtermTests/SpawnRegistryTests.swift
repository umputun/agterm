import XCTest
@testable import agterm
@testable import agtermCore

/// The pacer knows only keys, so the registry is what turns a grant into a spawn. Its weak entries are the
/// contract that matters: a queued pane the user closed must not be resurrected by its own grant.
@MainActor
final class SpawnRegistryTests: XCTestCase {
    private var registry: SpawnRegistry!
    private var key: UUID!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            registry = SpawnRegistry(pacer: SpawnPacer())
            key = UUID()
            registry.pacer.arm(order: [key], burst: [])
        }
    }

    override func tearDown() async throws {
        await MainActor.run { registry = nil; key = nil }
        try await super.tearDown()
    }

    /// The view stays at its zero init size, so the re-entered `createSurface` parks on the size guard
    /// instead of spawning a shell; the drop registration it runs first is the proof it was re-entered.
    func testAGrantSpawnsTheRegisteredPane() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        enqueue(view)
        XCTAssertFalse(view.requestSpawnPermit())
        view.unregisterDraggedTypes()

        registry.pacer.expedite(key)

        XCTAssertFalse(view.registeredDraggedTypes.isEmpty, "the grant never reached createSurface")
    }

    func testARegisteredPaneIsForgottenOnceGranted() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        enqueue(view)
        _ = registry.pacer.request(key)
        XCTAssertTrue(registry.view(for: key) === view)

        registry.pacer.expedite(key)

        XCTAssertNil(registry.view(for: key), "a key is granted once")
    }

    func testQueueingPointsThePaneAtThePacer() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())

        enqueue(view)

        XCTAssertFalse(view.requestSpawnPermit(), "a queued pane must ask the armed pacer")
        XCTAssertTrue(view.awaitingSpawnPermit)
    }

    func testAPaneThatReplaysNothingIsDiscardedRatherThanQueued() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())

        registry.enqueue(view, key: key, provider: LaunchSeedProvider(shouldPace: false) { _ in
            LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        })

        XCTAssertNil(registry.view(for: key))
        XCTAssertTrue(registry.pacer.isPassthrough, "a discarded key must not hold the queue open")
        XCTAssertTrue(view.requestSpawnPermit())
    }

    func testAPaneWithNoKeyIsNeverQueued() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())

        registry.enqueue(view, key: nil, provider: LaunchSeedProvider(shouldPace: true) { _ in
            LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        })

        XCTAssertTrue(view.requestSpawnPermit(), "a fresh or runtime split was never expected")
    }

    func testABurstGrantIsConsumedByTheRequesterNotReplayedThroughTheRegistry() {
        registry.pacer.arm(order: [key], burst: [key])
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        enqueue(view)
        view.unregisterDraggedTypes()

        XCTAssertTrue(view.requestSpawnPermit(), "a burst key is granted on request")

        XCTAssertTrue(view.registeredDraggedTypes.isEmpty, "the grant re-entered createSurface under the requester")
        XCTAssertNil(registry.view(for: key))
    }

    func testAPreExpeditedGrantIsConsumedByTheRequesterNotReplayedThroughTheRegistry() {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        enqueue(view)
        registry.pacer.expedite(key)
        view.unregisterDraggedTypes()

        XCTAssertTrue(view.requestSpawnPermit(), "an expedited key is granted on request")

        XCTAssertTrue(view.registeredDraggedTypes.isEmpty, "the grant re-entered createSurface under the requester")
        XCTAssertNil(registry.view(for: key))
    }

    private func enqueue(_ view: GhosttySurfaceView) {
        registry.enqueue(view, key: key, provider: LaunchSeedProvider(shouldPace: true) { _ in
            LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        })
    }

    func testTheRegistryHoldsThePaneWeakly() {
        weak var released: GhosttySurfaceView?
        autoreleasepool {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            enqueue(view)
            released = view
        }

        XCTAssertNil(released, "a registry entry must not keep a closed pane alive")
        XCTAssertNil(registry.view(for: key))
    }

    func testAGrantForADeallocatedPaneIsDropped() {
        autoreleasepool {
            let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
            enqueue(view)
        }
        _ = registry.pacer.request(key)

        registry.pacer.expedite(key)

        XCTAssertNil(registry.view(for: key))
    }

    func testAGrantForAnUnknownKeyIsIgnored() {
        let stray = UUID()

        registry.grant(stray)

        XCTAssertNil(registry.view(for: stray))
    }
}
