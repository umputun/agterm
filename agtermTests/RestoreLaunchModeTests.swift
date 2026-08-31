import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RestoreLaunchModeTests: XCTestCase {
    func testSettingsChangeDoesNotMutateTheProcessLatch() throws {
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-restore-mode-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let library = WindowLibrary(directory: stateDir)
        let model = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        let launched = GhosttyApp.shared.restoreLaunchDecision
        let changed: RestoreMode = launched.requested == .live ? .none : .live

        model.setRestoreMode(changed)

        XCTAssertEqual(GhosttyApp.shared.restoreLaunchDecision, launched)
        XCTAssertEqual(SettingsStore(directory: stateDir).load().restoreMode, changed)
    }
}
