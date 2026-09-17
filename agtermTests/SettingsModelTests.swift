import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SettingsModelTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var model: SettingsModel!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-settings-model-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            model = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            GhosttyApp.shared.setFlaggedViewLayout(.flat)
            model = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testSetFlaggedViewLayoutPersistsMirrorsAndBroadcasts() {
        let posted = expectation(forNotification: .agtermAppearanceChanged, object: nil)

        model.setFlaggedViewLayout(.tree)

        wait(for: [posted], timeout: 1)
        XCTAssertEqual(GhosttyApp.shared.flaggedViewLayout, .tree)
        XCTAssertEqual(SettingsStore(directory: stateDir).load().flaggedViewLayout, "tree")
    }

    func testSetFlaggedViewLayoutBackToFlatClearsTheStoredField() {
        model.setFlaggedViewLayout(.tree)

        model.setFlaggedViewLayout(.flat)

        XCTAssertEqual(GhosttyApp.shared.flaggedViewLayout, .flat)
        XCTAssertNil(SettingsStore(directory: stateDir).load().flaggedViewLayout)
    }

    func testSetFlaggedViewLayoutSkipsAnUnchangedValue() {
        model.setFlaggedViewLayout(.tree)
        let posted = expectation(forNotification: .agtermAppearanceChanged, object: nil)
        posted.isInverted = true

        model.setFlaggedViewLayout(.tree)

        wait(for: [posted], timeout: 0.3)
    }
}
