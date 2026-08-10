import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Coverage for `toggle_fullscreen` riding `CustomCommandRunner`'s key monitor.
///
/// It is the one built-in with no SwiftUI menu item to carry its equivalent: AppKit appends the only full
/// screen item there is as the View menu is prepared for display, and an item of agterm's own beside it is
/// a visible duplicate that nothing suppresses. So the chord is matched in the monitor, which means it must
/// also honour the monitor's guards — a text field keeps its keystrokes. The built-in bindings a `map` line
/// puts beyond its menu key equivalent ride the same monitor; `CustomCommandRunnerTests` covers those.
@MainActor
final class FullScreenChordTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var runner: CustomCommandRunner!
    private var window: RecordingWindow!
    private var windowID: WindowInfo.ID!

    /// Records `toggleFullScreen` instead of performing it: the real call opens a Space and animates, which
    /// a unit test must not do to the machine running it.
    private final class RecordingWindow: NSWindow {
        var toggleCount = 0
        override func toggleFullScreen(_ sender: Any?) { toggleCount += 1 }
    }

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-fullscreen-chord-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            runner = CustomCommandRunner(library: library,
                                         settings: SettingsModel(library: library,
                                                                 settingsStore: SettingsStore(directory: stateDir)),
                                         actions: AppActions(library: library),
                                         socketProvider: { "" })
            // `NSWindow` defaults isReleasedWhenClosed to true; see the hosted-test rule in ui-tests.md.
            window = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
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
            WindowRegistry.shared.unregister(windowID)
            windowID = nil
            window.orderOut(nil)
            window = nil
            runner = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private func keyDown(_ key: String, keyCode: UInt16, mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil,
                         characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
    }

    private var controlCommandF: NSEvent { keyDown("f", keyCode: 3, mods: [.control, .command]) }

    private var configDir: URL { stateDir.appendingPathComponent("config", isDirectory: true) }

    private func write(keymap: String) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try keymap.write(to: ConfigPaths.keymapPath(configDirectory: configDir), atomically: true, encoding: .utf8)
    }

    /// A runner over `keymap` written into an isolated config directory — the matcher is built from the
    /// parsed keymap, so a seeded file is the only way to reach it.
    private func runner(keymap: String) throws -> CustomCommandRunner {
        try write(keymap: keymap)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        settings.setConfigDirectory(configDir.path)
        let actions = AppActions(library: library)
        actions.settingsModel = settings
        return CustomCommandRunner(library: library, settings: settings, actions: actions, socketProvider: { "" })
    }

    func testShippedChordTogglesFullScreenAndIsConsumed() throws {
        XCTAssertTrue(runner.handleKeyDown(controlCommandF, in: window), "the chord must be consumed, not passed to the terminal")
        XCTAssertEqual(window.toggleCount, 1)
    }

    func testUnboundChordIsIgnored() throws {
        XCTAssertFalse(runner.handleKeyDown(keyDown("g", keyCode: 5, mods: [.control, .command]), in: window))
        XCTAssertEqual(window.toggleCount, 0)
    }

    func testBareKeyIsIgnored() throws {
        XCTAssertFalse(runner.handleKeyDown(keyDown("f", keyCode: 3, mods: []), in: window),
                       "an unmodified f is terminal input")
        XCTAssertEqual(window.toggleCount, 0)
    }

    // the guard that keeps a rename field or the palette search usable: NSText first responder passes through.
    func testFocusedTextFieldKeepsTheChord() throws {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text), "the text view should take first responder")
        XCTAssertFalse(runner.handleKeyDown(controlCommandF, in: window))
        XCTAssertEqual(window.toggleCount, 0)
    }

    // The other side of the `!commandEngine.isArmed` guard: a half-typed leader outranks the built-in, so
    // ctrl+a then ⌃⌘F must fire the custom command rather than toggle full screen. Seeded through a real
    // keymap.conf in an isolated config directory, since the matcher is built from the parsed keymap.
    func testHalfTypedLeaderOutranksTheFullScreenChord() throws {
        let marker = stateDir.appendingPathComponent("leader-fired")
        let leaderRunner = try runner(keymap: "command \"Leader\" ctrl+a>ctrl+cmd+f touch \(marker.path)\n")
        leaderRunner.start()
        defer { leaderRunner.stop() }

        let leader = keyDown("a", keyCode: 0, mods: [.control])
        XCTAssertTrue(leaderRunner.handleKeyDown(leader, in: window), "ctrl+a should arm the leader")
        XCTAssertTrue(leaderRunner.handleKeyDown(controlCommandF, in: window),
                      "the second chord completes the sequence and is consumed")
        XCTAssertEqual(window.toggleCount, 0, "an armed leader must outrank the full screen chord")
    }

    func testKeyRepeatDoesNotToggleTwice() throws {
        let repeated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: "f", charactersIgnoringModifiers: "f",
                                        isARepeat: true, keyCode: 3)!
        XCTAssertFalse(runner.handleKeyDown(repeated, in: window), "a held-down chord toggles once, on the first press")
        XCTAssertEqual(window.toggleCount, 0)
    }
}
