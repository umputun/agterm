import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Coverage for `toggle_fullscreen` riding `CustomCommandRunner`'s key monitor.
///
/// It is the one built-in with no SwiftUI menu item to carry its equivalent: AppKit appends the only full
/// screen item there is as the View menu is prepared for display, and an item of agterm's own beside it is
/// a visible duplicate that nothing suppresses. So the chord is matched in the monitor, which means it must
/// also honour the monitor's guards — a text field keeps its keystrokes.
@MainActor
final class FullScreenChordTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var runner: CustomCommandRunner!
    private var window: RecordingWindow!

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
                                         socketProvider: { "" })
            // `NSWindow` defaults isReleasedWhenClosed to true; see the hosted-test rule in ui-tests.md.
            window = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // the monitor fires only for an agterm terminal window, which the registry is what decides.
            WindowRegistry.shared.register(UUID(), window: window)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
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

    func testKeyRepeatDoesNotToggleTwice() throws {
        let repeated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: "f", charactersIgnoringModifiers: "f",
                                        isARepeat: true, keyCode: 3)!
        XCTAssertFalse(runner.handleKeyDown(repeated, in: window), "a held-down chord toggles once, on the first press")
        XCTAssertEqual(window.toggleCount, 0)
    }
}
