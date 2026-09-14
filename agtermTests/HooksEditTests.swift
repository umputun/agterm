import AppKit
import XCTest
@testable import agterm
import agtermCore

/// The starter file and the Edit Hooks action, against a settings model rooted in an isolated config
/// directory so the scheme's shared `AGTERM_STATE_DIR` config is never touched.
@MainActor
final class HooksEditTests: XCTestCase {
    private var stateDir: URL!
    private var configDir: URL!
    private var library: WindowLibrary!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-hooks-edit-\(UUID().uuidString)", isDirectory: true)
        configDir = stateDir.appendingPathComponent("cfg", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try SettingsStore(directory: stateDir).save(AppSettings(configDirectory: configDir.path))
        library = WindowLibrary(directory: stateDir)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func makeSettings() -> SettingsModel {
        SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
    }

    private var hooksFile: URL { configDir.appendingPathComponent("hooks.conf") }

    func testAMissingHooksFileGetsTheCommentedStarter() throws {
        let settings = makeSettings()

        XCTAssertEqual(settings.hooksPath, hooksFile.path)
        XCTAssertEqual(try String(contentsOf: hooksFile, encoding: .utf8), ConfigPaths.starterHooksConf())
        XCTAssertTrue(settings.hooks.entries.isEmpty)
        XCTAssertTrue(settings.hooksDiagnostics.isEmpty)
    }

    func testAnExistingHooksFileIsPreservedAndParsed() throws {
        let contents = "on status ~/s.sh\nbad line\n"
        try contents.write(to: hooksFile, atomically: true, encoding: .utf8)

        let settings = makeSettings()

        XCTAssertEqual(try String(contentsOf: hooksFile, encoding: .utf8), contents)
        XCTAssertEqual(settings.hooks.entries.map(\.command), ["~/s.sh"])
        XCTAssertEqual(settings.hooksDiagnostics.map(\.line), [2])
    }

    func testReloadRereadsTheFileAndPostsTheChangeNotification() throws {
        let settings = makeSettings()
        let posted = expectation(forNotification: .agtermHooksChanged, object: nil)
        try "on notify echo x\n".write(to: hooksFile, atomically: true, encoding: .utf8)

        settings.reloadHooks()

        wait(for: [posted], timeout: 2)
        XCTAssertEqual(settings.hooks.entries.map(\.kind), [.notify])
    }

    func testEditHooksOpensTheEditorOverlayOnTheFileAndMarksTheSession() throws {
        let settings = makeSettings()
        let actions = AppActions(library: library)
        actions.settingsModel = settings
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)

        actions.editHooks()

        XCTAssertEqual(actions.hooksEditOverlaySession, session.id)
        XCTAssertTrue(session.overlayActive)
        XCTAssertEqual(session.overlayCommand, ConfigPaths.editorCommand(forPath: hooksFile.path))
        XCTAssertNil(actions.keymapEditOverlaySession, "the hooks editor never marks the keymap slot")
    }
}
