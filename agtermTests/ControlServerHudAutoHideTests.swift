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
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one", hideAfter: 30),
                      file: stateDir.appendingPathComponent("body").path,
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        return (server, session)
    }
}
