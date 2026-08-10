import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Coverage for the built-in bindings a `map` line puts beyond its menu key equivalent: they ride
/// `CustomCommandRunner`'s key monitor and dispatch through `AppActions.perform(_:)`, while the menu-bound
/// alternative stays AppKit's. `FullScreenChordTests` covers the same monitor's `toggle_fullscreen` special
/// case; the custom-command half of the matcher is pinned host-free in `CustomCommandEngineTests`.
@MainActor
final class CustomCommandRunnerTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var window: NSWindow!
    private var windowID: WindowInfo.ID!
    private var started: [CustomCommandRunner] = []

    /// A menu chord deliberately unlike `toggle_sidebar`'s shipped one, so the monitor cannot appear to work
    /// by accident, plus the leader alternative every case below drives.
    private static let sidebarKeymap = "map cmd+ctrl+shift+s|ctrl+a>s toggle_sidebar\n"

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-runner-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            // `NSWindow` defaults isReleasedWhenClosed to true; see the hosted-test rule in ui-tests.md.
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // the monitor fires only for an agterm terminal window, which the registry is what decides.
            // `WindowRegistry.shared` is process-global, so the id is retained for tearDown to unregister.
            windowID = UUID()
            WindowRegistry.shared.register(windowID, window: window)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            started.forEach { $0.stop() }
            started = []
            WindowRegistry.shared.unregister(windowID)
            windowID = nil
            window.orderOut(nil)
            window = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private var configDir: URL { stateDir.appendingPathComponent("config", isDirectory: true) }

    private func write(keymap: String) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try keymap.write(to: ConfigPaths.keymapPath(configDirectory: configDir), atomically: true, encoding: .utf8)
    }

    private struct Fixture {
        let runner: CustomCommandRunner
        let settings: SettingsModel
        let store: AppStore
        let sidebarBefore: Bool
    }

    /// A started runner over `keymap` written into an isolated config directory — the matcher is built from
    /// the parsed keymap, so a seeded file is the only way to reach it — plus the store and the sidebar state
    /// the chord is expected to flip. The settings model comes back so a test can rewrite the file and drive
    /// the reload path; the runner is stopped at teardown.
    private func fixture(keymap: String = CustomCommandRunnerTests.sidebarKeymap) throws -> Fixture {
        try write(keymap: keymap)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        settings.setConfigDirectory(configDir.path)
        let actions = AppActions(library: library)
        actions.settingsModel = settings
        let runner = CustomCommandRunner(library: library, settings: settings, actions: actions,
                                         socketProvider: { "" })
        runner.start()
        started.append(runner)
        let store = try XCTUnwrap(library.activeStore)
        return Fixture(runner: runner, settings: settings, store: store, sidebarBefore: store.sidebarVisible)
    }

    private func keyDown(_ key: String, keyCode: UInt16, mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil,
                         characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
    }

    private var leader: NSEvent { keyDown("a", keyCode: 0, mods: [.control]) }
    private var sidebarTail: NSEvent { keyDown("s", keyCode: 1, mods: []) }

    func testBuiltinSequenceAlternativeRunsTheActionAndIsConsumed() throws {
        let fix = try fixture()

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window), "ctrl+a should arm the leader")
        XCTAssertTrue(fix.runner.handleKeyDown(sidebarTail, in: window),
                      "the completing chord must be consumed, not passed to the terminal")
        XCTAssertEqual(fix.store.sidebarVisible, !fix.sidebarBefore)
    }

    // the menu-bound alternative belongs to AppKit, so the monitor must leave it alone — registering it in
    // both places is the double dispatch the menu/monitor split exists to prevent.
    func testTheMenuBoundAlternativeIsNotAlsoDispatchedByTheMonitor() throws {
        let fix = try fixture()

        let menuChord = keyDown("s", keyCode: 1, mods: [.command, .control, .shift])
        XCTAssertFalse(fix.runner.handleKeyDown(menuChord, in: window), "the menu carries this one")
        XCTAssertEqual(fix.store.sidebarVisible, fix.sidebarBefore)
    }

    // the reason `.firedBuiltin` routes through the palette rather than calling the action directly: with a
    // picker pending, the key is still consumed but the action must not run.
    func testBuiltinAlternativeInheritsThePalettesModalGate() throws {
        let fix = try fixture()
        let modalWindow = try XCTUnwrap(library.activeWindowID)
        let pick = PickController()
        PickRegistry.shared.register(modalWindow, controller: pick)
        defer { PickRegistry.shared.unregister(modalWindow) }
        XCTAssertTrue(pick.open(PendingPick(id: "gate", items: [ControlPickItem(id: "item", label: "Item")])))

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(sidebarTail, in: window),
                      "the chord is consumed either way; only the action is gated")
        XCTAssertEqual(fix.store.sidebarVisible, fix.sidebarBefore, "a pending picker must block the palette action")
    }

    // keymap.md requires the reload path, not only a seeded file: the matcher rebuilds on
    // `.agtermKeymapChanged`, so a built-in alternative added by an edit must start firing without a restart.
    func testKeymapReloadRebindsTheBuiltinAlternatives() throws {
        let fix = try fixture(keymap: "map cmd+shift+l toggle_split\n")
        XCTAssertFalse(fix.runner.handleKeyDown(leader, in: window), "nothing is bound to ctrl+a yet")

        try write(keymap: Self.sidebarKeymap)
        fix.settings.reloadKeymap()
        // the rebuild rides a main-queue notification block, so run the loop in slices until it lands.
        let deadline = Date().addingTimeInterval(5)
        var armed = false
        while !armed, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            armed = fix.runner.handleKeyDown(leader, in: window)
        }
        XCTAssertTrue(armed, "the reloaded keymap should arm ctrl+a")

        XCTAssertTrue(fix.runner.handleKeyDown(sidebarTail, in: window))
        XCTAssertEqual(fix.store.sidebarVisible, !fix.sidebarBefore)
    }
}
