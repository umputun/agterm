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
            HtmlOverlayRegistry.shared.setZoom(1)
            model = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testStepHtmlOverlayZoomPersistsAndMirrors() {
        model.stepHtmlOverlayZoom("increase_font_size:1")
        model.stepHtmlOverlayZoom("increase_font_size:1")

        XCTAssertEqual(HtmlOverlayRegistry.shared.zoom, 1.25)
        XCTAssertEqual(SettingsStore(directory: stateDir).load().htmlOverlayZoom, 1.25)
        XCTAssertEqual(SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)).settings.htmlOverlayZoom, 1.25)
    }

    func testStepHtmlOverlayZoomBackToActualSizeClearsTheStoredField() {
        model.stepHtmlOverlayZoom("decrease_font_size:1")

        model.stepHtmlOverlayZoom("reset_font_size")

        XCTAssertEqual(HtmlOverlayRegistry.shared.zoom, 1)
        XCTAssertNil(SettingsStore(directory: stateDir).load().htmlOverlayZoom)
    }

    func testLaunchMirrorsTheSavedHtmlOverlayZoomToTheRegistry() throws {
        try SettingsStore(directory: stateDir).save(AppSettings(htmlOverlayZoom: 1.5))

        _ = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))

        XCTAssertEqual(HtmlOverlayRegistry.shared.zoom, 1.5)
    }

    func testSetLinkOpenModePersistsAndTheDefaultRemovesTheKey() {
        model.setLinkOpenMode(.overlay)
        XCTAssertEqual(model.settings.effectiveLinkOpenMode, .overlay)
        XCTAssertEqual(SettingsStore(directory: stateDir).load().linkOpenMode, "overlay")
        model.setLinkOpenMode(.browser)
        XCTAssertNil(SettingsStore(directory: stateDir).load().linkOpenMode)
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
