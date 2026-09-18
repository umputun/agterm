import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the HUD auto-hide timer. The scheduler is `ControlServer`'s and the panel lives in a
/// real store, so this cannot move to `agtermCore`.
@MainActor
final class ControlServerHudAutoHideTests: XCTestCase {
    private var stateDir: URL!
    private var servers: [ControlServer] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-hud-autohide-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers.removeAll()
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testAPanelWithNoAutoHideArmsNothing() throws {
        let fix = try fixture()

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "waiting"))

        XCTAssertNil(fix.server.hudAutoHide[fix.session.id])
    }

    func testRearmingSupersedesTheEarlierTimer() throws {
        let fix = try fixture()

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))
        let first = try XCTUnwrap(fix.server.hudAutoHide[fix.session.id]).revision
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "two", hideAfter: 30))
        let second = try XCTUnwrap(fix.server.hudAutoHide[fix.session.id]).revision

        XCTAssertGreaterThan(second, first, "an update restarts the interval without touching the slot generation")
    }

    func testRearmingWithoutAnAutoHideCancelsTheRunningOne() throws {
        let fix = try fixture()
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "two"))

        XCTAssertNil(fix.server.hudAutoHide[fix.session.id], "omitting it is how a caller cancels")
    }

    func testDiscardingTheHudDropsItsTimer() throws {
        let fix = try fixture()
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))

        fix.session.discardHudBody()

        XCTAssertNil(fix.server.hudAutoHide[fix.session.id], "every teardown routes through discardHudBody")
    }

    func testAnExpiredTimerClosesThePanel() async throws {
        let fix = try fixture()
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 0.05))

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(fix.session.hudActive)
        XCTAssertNil(fix.server.hudAutoHide[fix.session.id])
    }

    @MainActor
    private final class HudSink: PresentationSink {
        var huds: [PresentationHud?] = []
        var snapshot: PresentationSnapshot?
        func offer(_ frame: PresentationFrame) -> Bool {
            switch frame.body {
            case .hud(let hud): huds.append(hud)
            case .snapshot(let state): snapshot = state
            default: break
            }
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}
    }

    private func mirror(_ fix: (server: ControlServer, session: Session), at now: Date) throws -> HudSink {
        let store = try XCTUnwrap(fix.server.library.store(forSession: fix.session.id))
        let hub = try XCTUnwrap(store.presentationHub)
        let sink = HudSink()
        let id = fix.session.id
        try hub.subscribe(session: id, hello: PresentationHello(version: 1, kinds: ["hud"], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: id, now: now) }
        return sink
    }

    func testArmingPublishesThePanelWithItsDeadline() throws {
        let fix = try fixture()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        fix.server.hudClock = { start }
        let sink = try mirror(fix, at: start)

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))

        XCTAssertEqual(sink.huds.last??.remaining, 30)
        XCTAssertEqual(fix.server.hudAutoHide[fix.session.id]?.deadline, start.addingTimeInterval(30))
    }

    func testALateSubscriberGetsWhatIsLeftOfTheInterval() throws {
        let fix = try fixture()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        fix.server.hudClock = { start }
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))

        let late = try mirror(fix, at: start.addingTimeInterval(20))

        XCTAssertEqual(late.snapshot?.hud?.remaining, 10)
    }

    func testAPersistentPanelPublishesWithNoRemainingLifetime() throws {
        let fix = try fixture()
        let sink = try mirror(fix, at: Date())

        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "waiting"))

        XCTAssertEqual(sink.huds.count, 1)
        XCTAssertNil(sink.huds.last??.remaining)
    }

    func testResizingAPublishedPanelRepublishesItsWidthWithoutRestartingTheInterval() throws {
        let fix = try fixture()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        fix.server.hudClock = { start }
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 30))
        let sink = try mirror(fix, at: start)
        fix.server.hudClock = { start.addingTimeInterval(12) }

        let response = fix.server.resizeSessionOverlay(fix.session.id.uuidString, window: nil, sizePercent: 60)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(sink.huds.last??.spec.sizePercent, 60)
        XCTAssertEqual(sink.huds.last??.remaining, 18)
        XCTAssertEqual(fix.server.hudAutoHide[fix.session.id]?.deadline, start.addingTimeInterval(30))
    }

    func testAnExpiredTimerWithdrawsThePanelFromViewers() async throws {
        let fix = try fixture()
        let sink = try mirror(fix, at: Date())
        fix.server.armHudAutoHide(fix.session, spec: HudSpec(message: "one", hideAfter: 0.05))

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(sink.huds.count, 2)
        XCTAssertNil(sink.huds.last ?? nil)
    }

    private func fixture() throws -> (server: ControlServer, session: Session) {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: "/tmp/agterm-hud-\(UUID().uuidString.prefix(8)).sock"
        )
        servers.append(server)
        let store = try XCTUnwrap(library.activeStore)
        store.presentationHub = PresentationHub(staleTimeout: 30)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one", hideAfter: 30),
                      file: stateDir.appendingPathComponent("body").path,
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        return (server, session)
    }
}
