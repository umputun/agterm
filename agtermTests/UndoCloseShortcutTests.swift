import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `UndoCloseShortcut.chord(from:)`, the `NSEvent` → `Chord` half of the undo-close
/// monitor. It lives here rather than in `agtermCoreTests` because the mapping reads `NSEvent` accessors
/// an AppKit-free target cannot construct.
///
/// Only the ASCII-capable-layout branch is reachable: the branch is chosen by the LIVE input source
/// (`KeyboardLayout.isASCIICapable`), which a test cannot set without changing the machine's keyboard.
/// The non-Latin branch is covered deterministically in `KeybindTests`, which takes the layout as a
/// parameter.
@MainActor
final class UndoCloseShortcutTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var shortcut: UndoCloseShortcut!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-undo-close-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            shortcut = UndoCloseShortcut(actions: AppActions(library: library))
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            shortcut = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    /// Skip a case whose outcome only holds while the machine's own layout can type ASCII. The monitor
    /// reads the live input source, so a tester sitting on the Russian layout the keymap rule prescribes
    /// for hand-verifying this feature would otherwise see these fail on a correct build.
    private func skipUnlessLayoutIsASCIICapable() throws {
        try XCTSkipUnless(KeyboardLayout.isASCIICapable,
                          "needs an ASCII-capable keyboard layout; the other branch is covered in KeybindTests")
    }

    /// A shortcut whose `AppActions` carries a settings model over `keymap`, seeded into an isolated config
    /// directory — the parsed keymap is the only way to reach `equivalent(for:)`.
    private func shortcut(keymap: String) throws -> UndoCloseShortcut {
        let configDir = stateDir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try keymap.write(to: ConfigPaths.keymapPath(configDirectory: configDir), atomically: true, encoding: .utf8)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        settings.setConfigDirectory(configDir.path)
        let actions = AppActions(library: library)
        actions.settingsModel = settings
        return UndoCloseShortcut(actions: actions)
    }

    /// A key press as the active layout reports it: `characters` is what the layout puts on that physical
    /// position, `keyCode` is the position itself.
    private func keyDown(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }

    func testLatinLayoutChordUsesTheProducedCharacter() throws {
        let event = try keyDown("z", keyCode: 6, flags: .command)
        XCTAssertEqual(shortcut.chord(from: event), BuiltinAction.undoClose.defaultChord)
    }

    // on Dvorak the physical Z position (keyCode 6) types ";", so ⌘Z follows the Z the user actually types.
    func testAlternativeLatinLayoutKeepsItsOwnLetterPositions() throws {
        try skipUnlessLayoutIsASCIICapable()
        let event = try keyDown(";", keyCode: 6, flags: .command)
        XCTAssertEqual(shortcut.chord(from: event), Chord(mods: [.command], key: ";"))
    }

    // a remapped Latin layout typing a non-ASCII character keeps it and matches no chord, rather than
    // being pulled onto the ANSI position of keyCode 6.
    func testASCIICapableLayoutBindsTheProducedCharacterNotThePosition() throws {
        try skipUnlessLayoutIsASCIICapable()
        let event = try keyDown("я", keyCode: 6, flags: .command)
        XCTAssertEqual(shortcut.chord(from: event), Chord(mods: [.command], key: "я"))
        XCTAssertNotEqual(shortcut.chord(from: event), BuiltinAction.undoClose.defaultChord)
    }

    func testNamedKeyWinsOverTheProducedCharacter() throws {
        let event = try keyDown("\r", keyCode: 36, flags: .command)
        XCTAssertEqual(shortcut.chord(from: event), Chord(mods: [.command], key: "return"))
    }

    func testPressWithNoUsableBaseKeyMakesNoChord() throws {
        let event = try keyDown("", keyCode: 63)
        XCTAssertNil(shortcut.chord(from: event))
    }

    // MARK: which chord the monitor answers to

    func testUnwiredSettingsModelFallsBackToTheShippedChord() throws {
        let shipped = try XCTUnwrap(BuiltinAction.undoClose.defaultChord)
        XCTAssertTrue(shortcut.matchesUndoCloseChord(shipped))
    }

    func testRemappedUndoCloseAnswersToItsNewChordOnly() throws {
        let remapped = try shortcut(keymap: "map cmd+shift+z undo_close\n")
        XCTAssertTrue(remapped.matchesUndoCloseChord(Chord(mods: [.command, .shift], key: "z")))
        XCTAssertFalse(remapped.matchesUndoCloseChord(try XCTUnwrap(BuiltinAction.undoClose.defaultChord)))
    }

    // a leader-only `map` line leaves undo_close with no menu chord, and the shipped ⌘Z must NOT stand in for
    // it — it would keep reopening closed items from a chord the user moved the action off.
    func testUndoCloseLeftUnboundByAMapLineAnswersToNoChord() throws {
        let unbound = try shortcut(keymap: "map ctrl+a>z undo_close\n")
        XCTAssertFalse(unbound.matchesUndoCloseChord(try XCTUnwrap(BuiltinAction.undoClose.defaultChord)))
        XCTAssertFalse(unbound.matchesUndoCloseChord(Chord(mods: [.control], key: "a")))
    }
}
