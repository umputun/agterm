import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RecordingHookLauncher: HookLauncher {
    var launched: [(HookEntry, ControlEvent)] = []

    func launch(entry: HookEntry, event: ControlEvent,
                onDeliveryFailure _: @escaping @MainActor @Sendable (String) -> Void,
                onExit _: @escaping @MainActor @Sendable (Int32) -> Void) throws -> Int32 {
        launched.append((entry, event))
        return Int32(launched.count)
    }
}

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

    func testAnUnreadableHooksFileIsADiagnosticNotAnEmptyConfiguration() throws {
        try "on status ~/s.sh\n".write(to: hooksFile, atomically: true, encoding: .utf8)
        let settings = makeSettings()
        XCTAssertEqual(settings.hooks.entries.count, 1)

        try Data([0x6f, 0x6e, 0x20, 0xff, 0xfe, 0x0a]).write(to: hooksFile)
        settings.reloadHooks()

        XCTAssertTrue(settings.hooks.entries.isEmpty)
        XCTAssertEqual(settings.hooksDiagnostics.map(\.line), [0])
        XCTAssertTrue(settings.hooksDiagnostics[0].message.hasPrefix("could not read hooks.conf"))
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

    func testEditHooksAfterAConfigDirectoryChangeWritesTheStarterAndKeepsAnExistingFile() throws {
        let settings = makeSettings()
        let actions = AppActions(library: library)
        actions.settingsModel = settings
        let moved = stateDir.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        settings.setConfigDirectory(moved.path)
        let movedFile = moved.appendingPathComponent("hooks.conf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedFile.path))

        actions.editHooks()

        XCTAssertEqual(try String(contentsOf: movedFile, encoding: .utf8), ConfigPaths.starterHooksConf())
        XCTAssertEqual(library.activeStore?.activeSession?.overlayCommand,
                       ConfigPaths.editorCommand(forPath: movedFile.path))

        try "on status ~/kept.sh\n".write(to: movedFile, atomically: true, encoding: .utf8)
        library.activeStore?.closeOverlay(try XCTUnwrap(library.activeStore?.activeSession?.id))
        actions.editHooks()
        XCTAssertEqual(try String(contentsOf: movedFile, encoding: .utf8), "on status ~/kept.sh\n")
    }

    func testAStartedControllerSeesASessionCreatedByADirectoryOpen() throws {
        try "on session.created true\n".write(to: hooksFile, atomically: true, encoding: .utf8)
        let settings = makeSettings()
        let actions = AppActions(library: library)
        actions.settingsModel = settings
        let launcher = RecordingHookLauncher()
        let controller = HookController(library: library, settings: settings, socketProvider: { "" }, launcher: launcher)
        controller.start()

        XCTAssertTrue(actions.openSession(atDirectory: stateDir.path))

        XCTAssertEqual(launcher.launched.map { $0.1.kind }, [.sessionCreated])
        XCTAssertEqual(launcher.launched.map { $0.0.command }, ["true"])
        XCTAssertEqual(launcher.launched.first?.1.session, library.activeStore?.activeSession?.id.uuidString)
    }
}
