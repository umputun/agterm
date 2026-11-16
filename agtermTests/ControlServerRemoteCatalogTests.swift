import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemoteCatalogTests: XCTestCase {
    private var stateDir: URL!
    private var socketPath: String!
    private var library: WindowLibrary!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-open-tests-\(UUID().uuidString)", isDirectory: true)
        socketPath = "/tmp/agterm-ro-\(UUID().uuidString.prefix(8)).sock"
        library = WindowLibrary(directory: stateDir)
    }

    override func tearDown() async throws {
        unlink(socketPath + ".lock")
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func server(answering replies: [ControlResult]) throws -> (ControlServer, ScriptedRunner) {
        let runner = try ScriptedRunner(replies.map { result in
            let json = try JSONEncoder().encode(ControlResponse(ok: true, result: result))
            return RemoteCommandResult(status: 0, stdout: String(decoding: json, as: UTF8.self), stderr: "")
        })
        let server = ControlServer(library: library, actions: AppActions(library: library),
                                   settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                                   identity: AppIdentity(version: "9.9.9"), remoteRunner: runner, socketPath: socketPath)
        return (server, runner)
    }

    private func mac(live: Bool) -> ControlResult {
        var result = ControlResult()
        result.macCatalog = CatalogVersions(server: "9.9.9", protocolVersion: PresentationCodec.version, catalog: CatalogCodec.version,
                                            live: live)
        return result
    }

    private func windows(_ nodes: [ControlWindowNode]) -> ControlResult {
        var result = ControlResult()
        result.windows = nodes
        return result
    }

    func testAMacWithoutLiveSessionsIsRefusedBeforeAnyWindowIsMade() async throws {
        let (server, runner) = try server(answering: [mac(live: false)])

        let reply = await server.windowRemoteOpen(host: "mac", originWindow: nil)

        XCTAssertEqual(reply.error, "mac does not run Live sessions, which a remote window needs")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertFalse(library.windows.contains { $0.isRemote })
    }

    func testAMacWithSeveralOpenWindowsAndNoneNamedListsThem() async throws {
        let build = ControlWindowNode(id: "6F1C0D2E-0000-4000-8000-000000000001", name: "build", open: true, active: true)
        let notes = ControlWindowNode(id: "9A2B3C4D-0000-4000-8000-000000000002", name: "notes", open: true, active: false)
        let (server, runner) = try server(answering: [mac(live: true), windows([build, notes])])

        let reply = await server.windowRemoteOpen(host: "mac", originWindow: nil)

        XCTAssertEqual(reply.error, "mac has 2 open windows; name one with --origin-window: 6f1c0d2e build, 9a2b3c4d notes")
        let remote = runner.invocations.map { ($0.last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "") }
        XCTAssertEqual(remote.map { $0.contains("agtermctl version --json") }, [true, false])
        XCTAssertEqual(remote.map { $0.contains("agtermctl window list --json") }, [false, true])
        XCTAssertFalse(library.windows.contains { $0.isRemote })
    }

    func testAServerHostRefusesAnOriginWindow() async throws {
        var server = ControlResult()
        server.versions = CatalogVersions(server: "1.2.3", protocolVersion: PresentationCodec.version, catalog: CatalogCodec.version)
        let (control, runner) = try self.server(answering: [server])

        let reply = await control.windowRemoteOpen(host: "box", originWindow: "6f1c")

        XCTAssertEqual(reply.error, "box runs agterm-server, which has no windows to name")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertFalse(library.windows.contains { $0.isRemote })
    }

    func testAKnownMacThatDoesNotAnswerIsRefusedAndGetsNoOriginlessWindow() async throws {
        let known = library.newRemoteWindow(host: "mac", originWindow: UUID(), originName: "build")
        let runner = ScriptedRunner([RemoteCommandResult(status: 255, stdout: "", stderr: "ssh: connect timed out")])
        let server = ControlServer(library: library, actions: AppActions(library: library),
                                   settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                                   identity: AppIdentity(version: "9.9.9"), remoteRunner: runner, socketPath: socketPath)

        let reply = await server.windowRemoteOpen(host: "mac", originWindow: nil)

        XCTAssertEqual(reply.error, "mac did not answer")
        XCTAssertEqual(library.windows.filter(\.isRemote).map(\.id), [known.id])
    }
}
