import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `restore.mode`: the five reported fields, the rollback on a failed write, and the
/// probed-reason suppression that keeps a rerun user from being told their shell is unsupported for a mode
/// they never asked for.
@MainActor
final class ControlServerRestoreModeTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-restore-mode-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testSetPersistsForTheNextLaunchAndEchoesTheStatus() throws {
        let server = makeServer()

        let response = server.setRestoreMode(.live)

        XCTAssertTrue(response.ok)
        let status = try XCTUnwrap(response.result?.restore)
        XCTAssertEqual(status.configured, "live")
        XCTAssertEqual(settingsModel.settings.effectiveRestoreMode, .live)
        XCTAssertNil(settingsModel.settings.restoreRunningCommand, "the legacy key must not survive a save")
    }

    func testAFailedSaveRollsMemoryBackInsteadOfClaimingTheNewMode() throws {
        let server = makeServer()
        XCTAssertTrue(server.setRestoreMode(.rerun).ok, "precondition: a writable store")

        let directory = try unwritableStateDirectory()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let response = server.setRestoreMode(.live)

        XCTAssertFalse(response.ok, "an unsaved policy must not be acknowledged")
        XCTAssertEqual(response.error, "could not save the restore mode; settings keep rerun")
        XCTAssertEqual(settingsModel.settings.effectiveRestoreMode, .rerun,
                       "memory must not claim a mode the disk rejected")
        XCTAssertEqual(try XCTUnwrap(server.readRestoreMode().result?.restore).configured, "rerun")
    }

    func testTheReadReportsWhatTheLaunchAskedForAgainstWhatSettingsHold() throws {
        let server = makeServer()
        XCTAssertTrue(server.setRestoreMode(.live).ok)

        let status = try XCTUnwrap(server.readRestoreMode().result?.restore)
        XCTAssertEqual(status.configured, "live")
        XCTAssertEqual(status.requestedAtLaunch, GhosttyApp.shared.requestedRestoreMode.rawValue)
        XCTAssertEqual(status.active, GhosttyApp.shared.launchRestoreMode.rawValue)
        XCTAssertEqual(status.restartRequired, status.configured != status.requestedAtLaunch)
    }

    func testAProbedReasonIsReportedOnlyWhenLiveActuallyFellBack() {
        let fellBack = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .none,
                                            unavailableReason: "the bundled zsh integration is unavailable")
        XCTAssertNotNil(fellBack.unavailableReason)

        let neverAsked = ControlRestoreStatus(configured: .rerun, requestedAtLaunch: .rerun, active: .rerun,
                                              unavailableReason: "the bundled zsh integration is unavailable")
        XCTAssertNil(neverAsked.unavailableReason,
                     "a rerun launch must not be told why a mode it never requested was refused")
    }

    private func makeServer() -> ControlServer {
        ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            launchRestoreMode: GhosttyApp.shared.launchRestoreMode,
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path
        )
    }

    /// Settings save atomically through a temp file in the state directory, so 0o500 makes the write throw.
    private func unwritableStateDirectory() throws -> URL {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDir.path)
        return stateDir
    }
}
