import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `restore.capture`: the gate on the master setting and the response shape. The argv
/// read itself needs a live `GhosttySurfaceView`, so a hosted session captures nothing and reports zero —
/// which is exactly what makes the gate and the reported text testable without driving the UI.
@MainActor
final class ControlServerRestoreCaptureTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-restore-capture-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            server = ControlServer(
                library: library,
                actions: AppActions(library: library),
                settingsModel: settingsModel,
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            settingsModel = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    func testRefusesWithTheSettingOff() {
        settingsModel.setRestoreRunningCommand(nil)

        let response = server.captureRestoreCommands()

        XCTAssertFalse(response.ok, "a capture that can never replay must refuse, not answer ok")
        XCTAssertEqual(response.error,
                       "\"Restore running commands on restart\" is off, nothing was captured")
        XCTAssertNil(response.result)
    }

    func testTheRefusalLeavesAnEarlierCaptureAlone() {
        settingsModel.setRestoreRunningCommand(nil)
        for session in library.allOpenSessions() {
            session.foregroundCommand = ["sleep", "12345"]
            session.splitForegroundCommand = ["sleep", "12345"]
        }

        _ = server.captureRestoreCommands()

        // the SPLIT slot is what pins the gate. A hosted session has no `GhosttySurfaceView`, so the main
        // slot is never assigned and survives with the guard deleted too; the split slot is nil'd
        // unconditionally by the capture's `else` for a session with no shown split, so it goes red the
        // moment the guard stops returning early.
        XCTAssertTrue(library.allOpenSessions().allSatisfy { $0.splitForegroundCommand == ["sleep", "12345"] },
                      "with the setting off the command must not clear the split slot")
        XCTAssertTrue(library.allOpenSessions().allSatisfy { $0.foregroundCommand == ["sleep", "12345"] },
                      "with the setting off the command must not touch the slots at all")
    }

    func testReportsPaneCountInItsOwnText() {
        settingsModel.setRestoreRunningCommand(true)

        let response = server.captureRestoreCommands()

        XCTAssertTrue(response.ok)
        // no realized surfaces in a hosted store, so nothing is captured — the point here is that the command
        // renders its own sentence instead of leaning on `count`, whose CLI branch prints "N diagnostic(s)".
        XCTAssertEqual(response.result?.count, 0)
        XCTAssertEqual(response.result?.text, "captured 0 panes")
    }
}
