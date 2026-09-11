import AppKit
import XCTest
@testable import agterm
import agtermCore
import AgtermResponsibility

/// Hosted coverage for the Live sessions reset's app arms on `ControlServer`.
@MainActor
final class ControlServerLiveResetTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-live-reset-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            settingsModel = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    private func makeServer(runner: @escaping ZmxClient.Runner, probe: LiveAttributionProbe) -> ControlServer {
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", runner: runner)
        let resolver = ZmxForegroundResolver(leaderProvider: { _ in [:] }, leaderProbe: { .foreground($0) })
        return ControlServer(library: library, actions: AppActions(library: library), settingsModel: settingsModel,
                             identity: AppIdentity(version: "test", commit: "test"), zmxForegroundResolver: resolver,
                             zmxClient: client, liveAttributionProbe: probe,
                             socketPath: stateDir.appendingPathComponent("reset.sock").path)
    }

    func testLiveResetSelectionJoinsClaimsAndRecords() throws {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.workspaces.first)
        let orphaned = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let supervised = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let rows = [
            "name=\(ZmxSupport.daemonName(for: orphaned.paneIdentity))\tpid=200\tclients=0",
            "name=\(ZmxSupport.daemonName(for: supervised.paneIdentity))\tpid=210\tclients=1",
        ].joined(separator: "\n")
        let probe = LiveAttributionProbe(responsible: { pid in pid == 210 ? .live(100) : .live(pid) },
                                         hostPID: { _ in 100 }, appPID: 300)

        let selection = try XCTUnwrap(makeServer(runner: { _ in rows }, probe: probe).liveResetSelection())

        XCTAssertEqual(selection.targets, [LiveReset.Target(paneIdentity: orphaned.paneIdentity, sessionID: orphaned.id,
                                                            daemon: ZmxSupport.daemonName(for: orphaned.paneIdentity), leaderPID: 200)])
        XCTAssertEqual(selection.sessionCount, 1)
        XCTAssertTrue(selection.inventoryComplete)
    }

    func testLiveResetSelectionIsNilWhenTheListingFails() {
        let probe = LiveAttributionProbe(responsible: { .live($0) }, hostPID: { _ in nil }, appPID: 300)
        XCTAssertNil(makeServer(runner: { _ in throw ZmxClient.CommandError.timedOut }, probe: probe).liveResetSelection())
    }
}
