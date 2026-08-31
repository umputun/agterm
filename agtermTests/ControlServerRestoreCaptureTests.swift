import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `restore.capture` and for the checked save both restore commands acknowledge on: the
/// gate on the master setting, the response shape, and the failed-write ack. The argv read itself needs a
/// live `GhosttySurfaceView`, so a hosted session captures nothing and reports zero — which is exactly what
/// makes the gate and the reported text testable without driving the UI.
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
            XCTAssertTrue(settingsModel.setRestoreMode(.rerun))
            server = makeServer(launchMode: .rerun)
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

    func testRefusesOutsideRerunAndNamesTheConfiguredMode() {
        for mode in [RestoreMode.none, .live] {
            XCTAssertTrue(settingsModel.setRestoreMode(mode))
            let response = makeServer(launchMode: .rerun).captureRestoreCommands()
            XCTAssertFalse(response.ok, "a capture that cannot replay must refuse")
            XCTAssertEqual(response.error, "restore.capture requires rerun mode; configured restore mode is \(mode.rawValue)")
            XCTAssertNil(response.result)
        }
    }

    func testTheRefusalLeavesAnEarlierCaptureAlone() {
        for session in library.allOpenSessions() {
            session.foregroundCommand = ["sleep", "12345"]
            session.splitForegroundCommand = ["sleep", "12345"]
        }

        XCTAssertTrue(settingsModel.setRestoreMode(.live))
        _ = makeServer(launchMode: .rerun).captureRestoreCommands()

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
        let response = server.captureRestoreCommands()

        XCTAssertTrue(response.ok)
        // no realized surfaces in a hosted store, so nothing is captured — the point here is that the command
        // renders its own sentence instead of leaning on `count`, whose CLI branch prints "N diagnostic(s)".
        XCTAssertEqual(response.result?.count, 0)
        XCTAssertEqual(response.result?.text, "captured 0 panes")
    }

    /// The defect this pins: an unchecked save let `restore.clear` answer ok with the captured commands still
    /// on disk, and the slots are deliberately unreadable, so nothing else could report it.
    func testClearReportsAFailedSave() throws {
        let windowsDir = try unwritableWindowsDirectory()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: windowsDir.path) }

        let response = server.clearRestoreCommands()

        XCTAssertFalse(response.ok, "a clear whose save failed must not answer ok")
        XCTAssertEqual(response.error?.contains("save failed"), true, "the error should name the failed save")
    }

    func testCaptureReportsAFailedSave() throws {
        let windowsDir = try unwritableWindowsDirectory()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: windowsDir.path) }

        let response = server.captureRestoreCommands()

        XCTAssertFalse(response.ok, "a capture whose save failed must not answer ok")
        XCTAssertEqual(response.error?.contains("save failed"), true, "the error should name the failed save")
    }

    func testConfiguredRerunEnablesCaptureWithoutChangingTheLaunchLatch() {
        let server = makeServer(launchMode: .none)
        XCTAssertTrue(settingsModel.setRestoreMode(.rerun))

        let response = server.captureRestoreCommands()

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(server.launchRestoreMode, .none)
    }

    func testLiveLaunchConfiguredForRerunCapturesThroughTheZmxResolver() throws {
        let worker = try startWorker()
        defer { stopWorker(worker) }
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        session.surface = GhosttySurfaceView(
            workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": session.paneIdentity.uuidString], backedByZmx: true)
        var snapshotTimeout: TimeInterval?
        let resolver = ZmxForegroundResolver(
            leaderProvider: {
                snapshotTimeout = $0
                return [ZmxSupport.daemonName(for: session.paneIdentity): worker.processIdentifier]
            },
            leaderProbe: { _ in .foreground(worker.processIdentifier) })
        let server = makeServer(launchMode: .live, zmxForegroundResolver: resolver)

        let response = server.captureRestoreCommands()

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.count, 1)
        XCTAssertEqual(snapshotTimeout, ZmxClient.captureInvocationTimeout)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let persisted = PersistenceStore(
            directory: stateDir.appendingPathComponent("windows"), fileName: "\(windowID.uuidString).json").load()
        XCTAssertEqual(persisted.workspaces.first?.sessions.first?.foregroundCommand?.last, "30")
    }

    func testClearRemainsAvailableInLiveMode() {
        for session in library.allOpenSessions() {
            session.foregroundCommand = ["sleep", "12345"]
        }

        let response = makeServer(launchMode: .live).clearRestoreCommands()

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertTrue(library.allOpenSessions().allSatisfy { $0.foregroundCommand == nil })
    }

    private func makeServer(launchMode: RestoreMode,
                            zmxForegroundResolver: ZmxForegroundResolver? = nil) -> ControlServer {
        ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            launchRestoreMode: launchMode,
            zmxForegroundResolver: zmxForegroundResolver,
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path
        )
    }

    private func startWorker() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func stopWorker(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    /// The same lever `WindowLibraryTests.saveAllOpenCheckedReportsAFailedWrite` uses: the atomic write needs
    /// to create a temp file in the directory, so 0o500 makes it throw.
    private func unwritableWindowsDirectory() throws -> URL {
        XCTAssertTrue(library.saveAllOpenChecked(), "precondition: the store should be writable to start")
        let windowsDir = stateDir.appendingPathComponent("windows")
        XCTAssertTrue(FileManager.default.fileExists(atPath: windowsDir.path),
                      "precondition: the first save should have created the windows directory")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: windowsDir.path)
        return windowsDir
    }
}
