import Darwin
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class LiveResetConsumerTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var context: agtermApp.LaunchSpawnContext!
    private var store: LiveResetMarkerStore!
    private var invocations: [[String]] = []
    private var timeouts: [String: TimeInterval] = [:]
    private var listDelay: Duration = .zero
    private var rows: [String] = []
    private var listFails = false
    private var killFails = false
    private var alive: Set<pid_t> = []
    private var clock = ContinuousClock.Instant.now

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-live-reset-consumer-\(UUID().uuidString)", isDirectory: true)
            context = agtermApp.LaunchSpawnContext()
            let context = context!
            library = WindowLibrary(directory: stateDir, paneFinalizer: nil, launchInventorySink: { context.launchInventory = $0 })
            store = LiveResetMarkerStore(directory: stateDir)
            invocations = []
            timeouts = [:]
            listDelay = .zero
            rows = []
            listFails = false
            killFails = false
            alive = []
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    private func makeClient() -> ZmxClient {
        let marker = stateDir.appendingPathComponent(LiveReset.markerFilename)
        return ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { [self] invocation in
            invocations.append(invocation.arguments)
            timeouts[invocation.arguments[0]] = invocation.timeout
            switch invocation.arguments.first {
            case "list":
                clock = clock.advanced(by: listDelay)
                if listFails { throw ZmxClient.CommandError.timedOut }
                return rows.joined(separator: "\n")
            case "kill":
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the marker is consumed before any kill")
                if killFails { throw ZmxClient.CommandError.failed(1, "boom") }
                return ""
            default:
                return ""
            }
        }
    }

    private func dependencies() -> LiveResetConsumer.Dependencies {
        var deps = LiveResetConsumer.Dependencies(
            markerStore: store,
            probe: LiveAttributionProbe(responsible: { .live($0) }, hostPID: { _ in nil }, appPID: 300))
        deps.poll = ZmxClient.LeaderPoll(now: { [self] in clock }, sleep: { [self] in clock = clock.advanced(by: $0) })
        deps.isAlive = { [self] in alive.contains($0) }
        return deps
    }

    private func addSession() throws -> Session {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.workspaces.first)
        return try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
    }

    private func target(_ session: Session, leader: Int32) -> LiveReset.Target {
        LiveReset.Target(paneIdentity: session.paneIdentity, sessionID: session.id,
                         daemon: ZmxSupport.daemonName(for: session.paneIdentity), leaderPID: leader)
    }

    private func row(_ session: Session, leader: Int32) -> String {
        "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=\(leader)\tclients=0"
    }

    private func run() -> LiveReset.Outcome? {
        LiveResetConsumer.run(dependencies(), library: library, client: makeClient(), context: context)
    }

    private var kills: [[String]] { invocations.filter { $0.first == "kill" } }

    func testNoMarkerMeansNoZmxInvocation() {
        XCTAssertNil(run())
        XCTAssertTrue(invocations.isEmpty)
    }

    func testMarkerConsumedBeforeFirstKill() throws {
        let session = try addSession()
        rows = [row(session, leader: 10)]
        try store.write(LiveReset.Marker(targets: [target(session, leader: 10)]))

        let outcome = try XCTUnwrap(run())

        XCTAssertEqual(kills, [["kill", ZmxSupport.daemonName(for: session.paneIdentity), "--force"]])
        XCTAssertEqual(outcome.panes.killed, 1)
    }

    func testOnlyNarrowedTargetsKilledInOneInvocation() throws {
        let kept = try addSession()
        let changed = try addSession()
        let unclaimed = LiveReset.Target(paneIdentity: UUID(), sessionID: UUID(), daemon: "agterm-unclaimed", leaderPID: 30)
        rows = [row(kept, leader: 10), row(changed, leader: 21), "name=agterm-unclaimed\tpid=30\tclients=0"]
        try store.write(LiveReset.Marker(targets: [target(kept, leader: 10), target(changed, leader: 20), unclaimed]))

        let outcome = try XCTUnwrap(run())

        XCTAssertEqual(kills, [["kill", ZmxSupport.daemonName(for: kept.paneIdentity), "--force"]])
        XCTAssertEqual(outcome.panes, LiveReset.PaneCounts(confirmed: 3, killed: 1, gone: 0, skipped: 2))
    }

    func testFailedListingKillsNothing() throws {
        let session = try addSession()
        listFails = true
        try store.write(LiveReset.Marker(targets: [target(session, leader: 10)]))

        let outcome = try XCTUnwrap(run())

        XCTAssertTrue(kills.isEmpty)
        XCTAssertTrue(outcome.inventoryFailed)
        XCTAssertEqual(outcome.panes.skipped, 1)
    }

    func testFailedBatchStillPollsEveryLeader() throws {
        let exited = try addSession()
        let survivor = try addSession()
        rows = [row(exited, leader: 10), row(survivor, leader: 20)]
        killFails = true
        alive = [20]
        try store.write(LiveReset.Marker(targets: [target(exited, leader: 10), target(survivor, leader: 20)]))

        let outcome = try XCTUnwrap(run())

        XCTAssertEqual(kills.count, 1)
        XCTAssertEqual(outcome.panes.killed, 1)
        XCTAssertEqual(outcome.unconfirmed, [survivor.paneIdentity])
        XCTAssertEqual(context.suppressedLaunchPayloads, [survivor.paneIdentity])
    }

    func testSurvivingLeaderIsUnconfirmedAndSuppressed() throws {
        let session = try addSession()
        rows = [row(session, leader: 10)]
        alive = [10]
        try store.write(LiveReset.Marker(targets: [target(session, leader: 10)]))
        let start = clock

        let outcome = try XCTUnwrap(run())

        XCTAssertEqual(outcome.unconfirmed, [session.paneIdentity])
        XCTAssertEqual(outcome.sessions, LiveReset.SessionCounts(affected: 1, reset: 0, partial: 1, unconfirmed: 1))
        XCTAssertEqual(context.suppressedLaunchPayloads, [session.paneIdentity])
        XCTAssertGreaterThanOrEqual(clock, start.advanced(by: .seconds(15)))
        XCTAssertLessThan(clock, start.advanced(by: .seconds(16)))
    }

    func testInvalidMarkerRemovedAndKillsNothing() throws {
        try "not json".write(to: stateDir.appendingPathComponent(LiveReset.markerFilename), atomically: true, encoding: .utf8)

        XCTAssertNil(run())

        XCTAssertTrue(invocations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent(LiveReset.markerFilename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent(LiveReset.consumedFilename).path))
    }

    func testConsumedMarkerDeletedAfterOutcome() throws {
        let session = try addSession()
        rows = [row(session, leader: 10)]
        try store.write(LiveReset.Marker(targets: [target(session, leader: 10)]))

        XCTAssertNotNil(run())

        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent(LiveReset.consumedFilename).path))
    }

    func testBudgetClampsListingAndKill() throws {
        let session = try addSession()
        rows = [row(session, leader: 10)]
        listDelay = .milliseconds(1500)
        try store.write(LiveReset.Marker(targets: [target(session, leader: 10)]))
        var deps = dependencies()
        deps.budget = .seconds(2)

        let outcome = try XCTUnwrap(LiveResetConsumer.run(deps, library: library, client: makeClient(), context: context))

        XCTAssertEqual(outcome.panes.killed, 1)
        XCTAssertEqual(timeouts["list"], 2)
        XCTAssertEqual(try XCTUnwrap(timeouts["kill"]), 0.5, accuracy: 0.01)
    }

    func testExpiredBudgetSkipsTheBatchAndSuppresses() throws {
        let session = try addSession()
        rows = [row(session, leader: 10)]
        listDelay = .seconds(3)
        try store.write(LiveReset.Marker(targets: [target(session, leader: 10)]))
        var deps = dependencies()
        deps.budget = .seconds(2)

        let outcome = try XCTUnwrap(LiveResetConsumer.run(deps, library: library, client: makeClient(), context: context))

        XCTAssertTrue(kills.isEmpty, "a batch never starts after the budget expired")
        XCTAssertEqual(outcome.unconfirmed, [session.paneIdentity])
        XCTAssertEqual(context.suppressedLaunchPayloads, [session.paneIdentity])
    }

    func testFallbackLaunchDiscardsTheMarkerWithoutKilling() throws {
        let seeded = try addSession()
        library.saveAllOpen()
        library.saveIndex()
        let context = context!
        library = WindowLibrary(directory: stateDir, paneFinalizer: nil, launchInventorySink: { context.launchInventory = $0 })
        let session = try XCTUnwrap(library.activeStore?.workspaces.flatMap(\.sessions).first { $0.paneIdentity == seeded.paneIdentity })
        rows = [row(session, leader: 10)]
        try store.write(LiveReset.Marker(targets: [target(session, leader: 10)]))
        let resolver = ZmxForegroundResolver(leaderProvider: { _ in [:] }, leaderProbe: { .foreground($0) })
        let launch = LaunchOrchestration.Inputs(library: library, client: makeClient(), resolver: resolver, context: context,
                                                launchDecision: RestoreLaunchDecision(requested: .live, active: .rerun, liveUnavailableReason: "unsupported shell"))

        let outcome = LaunchOrchestration.run(launch, consumer: dependencies())

        XCTAssertNil(outcome)
        XCTAssertEqual(invocations.map(\.[0]), ["list"], "only the ordinary reap listed; the consumer never ran")
        XCTAssertTrue(context.suppressedLaunchPayloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent(LiveReset.markerFilename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir.appendingPathComponent(LiveReset.consumedFilename).path))
    }

    func testOrderingInventoryThenConsumerThenReap() throws {
        let seeded = try addSession()
        library.saveAllOpen()
        library.saveIndex()
        let context = context!
        library = WindowLibrary(directory: stateDir, paneFinalizer: nil, launchInventorySink: { context.launchInventory = $0 })
        let session = try XCTUnwrap(library.activeStore?.workspaces.flatMap(\.sessions).first { $0.paneIdentity == seeded.paneIdentity })
        rows = [row(session, leader: 10)]
        try store.write(LiveReset.Marker(targets: [target(session, leader: 10)]))
        let client = makeClient()
        let resolver = ZmxForegroundResolver(leaderProvider: { _ in [:] }, leaderProbe: { .foreground($0) })
        let decision = RestoreLaunchDecision(requested: .live, active: .live, liveUnavailableReason: nil)

        let launch = LaunchOrchestration.Inputs(library: library, client: client, resolver: resolver, context: context,
                                                launchDecision: decision)
        let outcome = LaunchOrchestration.run(launch, consumer: dependencies())

        XCTAssertNotNil(context.launchInventory, "the library handed its inventory to the context before anything ran")
        XCTAssertEqual(outcome?.panes.killed, 1)
        XCTAssertEqual(invocations.map(\.[0]), ["list", "kill", "list"], "consumer listing and kill, then the ordinary reap's listing")
        XCTAssertEqual(context.runningNames, [ZmxSupport.daemonName(for: session.paneIdentity)])
    }
}
