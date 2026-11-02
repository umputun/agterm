import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerSessionInfoTests: XCTestCase {
    private var stateDir: URL!
    private var servers: [ControlServer] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-session-info-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers.removeAll()
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testASetReachesTheStoreAndArmsItsExpiry() throws {
        let fix = try fixture()

        let response = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("3 agents", hideAfter: 30))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(fix.session.info?.source, "3 agents")
        XCTAssertNotNil(fix.server.infoAutoHide[fix.session.id])
    }

    func testAnUntimedSetArmsNothing() throws {
        let fix = try fixture()

        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("idle", hideAfter: 0))

        XCTAssertEqual(fix.session.info?.source, "idle")
        XCTAssertNil(fix.server.infoAutoHide[fix.session.id])
    }

    func testAnIdenticalSetRestartsTheExpiry() throws {
        let fix = try fixture()
        let line = try info("3 agents", hideAfter: 30)
        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: line)
        let first = try XCTUnwrap(fix.server.infoAutoHide[fix.session.id]).revision

        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: line)

        XCTAssertGreaterThan(try XCTUnwrap(fix.server.infoAutoHide[fix.session.id]).revision, first)
    }

    func testAnExpiredLineIsCleared() async throws {
        let fix = try fixture()

        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("brief", hideAfter: 0.05))

        try await waitUntil { fix.session.info == nil }
        XCTAssertNil(fix.session.info)
        XCTAssertNil(fix.server.infoAutoHide[fix.session.id])
    }

    func testASupersededTimerIsInert() async throws {
        let fix = try fixture()
        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("brief", hideAfter: 0.05))

        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("long", hideAfter: 30))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(fix.session.info?.source, "long")
        XCTAssertNotNil(fix.server.infoAutoHide[fix.session.id])
    }

    func testASetWithoutHideAfterCancelsATimedLine() async throws {
        let fix = try fixture()
        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("brief", hideAfter: 0.05))

        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("stays", hideAfter: 0))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(fix.session.info?.source, "stays")
        XCTAssertNil(fix.server.infoAutoHide[fix.session.id])
    }

    func testARejectedWriteKeepsTheLineAndItsTimer() async throws {
        let fix = try fixture()
        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("kept", hideAfter: 30))
        let armed = try XCTUnwrap(fix.server.infoAutoHide[fix.session.id]).revision

        let response = await ControlDispatcher(actions: fix.server).dispatch(ControlRequest(
            cmd: .sessionInfo, target: fix.session.id.uuidString, args: ControlArgs(text: "x", mode: "set", hideAfter: -1)))

        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(fix.session.info?.source, "kept")
        XCTAssertEqual(fix.server.infoAutoHide[fix.session.id]?.revision, armed)
    }

    func testAClearCancelsTheTimer() throws {
        let fix = try fixture()
        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("brief", hideAfter: 30))

        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: nil)

        XCTAssertNil(fix.session.info)
        XCTAssertNil(fix.server.infoAutoHide[fix.session.id])
    }

    func testClosingTheSessionCancelsItsTimer() throws {
        let fix = try fixture()
        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("brief", hideAfter: 30))

        try XCTUnwrap(fix.server.library.activeStore).closeSession(fix.session.id)

        XCTAssertNil(fix.server.infoAutoHide[fix.session.id])
        XCTAssertNil(fix.session.info)
    }

    func testClosingAHudKeepsTheLineAndItsTimer() throws {
        let fix = try fixture()
        let store = try XCTUnwrap(fix.server.library.activeStore)
        store.openHud(fix.session.id, command: "hud.sh", spec: HudSpec(message: "one"),
                      file: stateDir.appendingPathComponent("body").path, size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        _ = fix.server.setSessionInfo(fix.session.id.uuidString, window: nil, info: try info("kept", hideAfter: 30))

        XCTAssertTrue(store.closeHud(fix.session.id))

        XCTAssertEqual(fix.session.info?.source, "kept")
        XCTAssertNotNil(fix.server.infoAutoHide[fix.session.id])
    }

    private func info(_ source: String, hideAfter: Double) throws -> SessionInfo {
        try SessionInfo.make(source: source, markdown: false, hideAfter: hideAfter).get()
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func fixture() throws -> (server: ControlServer, session: Session) {
        let library = WindowLibrary(directory: stateDir)
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: "/tmp/agterm-info-\(UUID().uuidString.prefix(8)).sock"
        )
        servers.append(server)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        return (server, session)
    }
}
