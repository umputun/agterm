import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `UndoCloseShortcut.chord(from:)`, the `NSEvent` → `Chord` half of the undo-close
/// monitor. It lives here rather than in `agtermCoreTests` because the mapping reads `NSEvent` accessors
/// an AppKit-free target cannot construct.
///
/// Only the ASCII-capable-layout branch is reachable here. Which branch runs is decided by the LIVE
/// input source (`KeyboardLayout.isASCIICapable`), which a test cannot set without changing the
/// machine's keyboard, so these run on whatever the tester has — a Latin layout on any development
/// machine and in CI. The non-Latin branch is covered deterministically in `KeybindTests`, where
/// `chordKey(forKeyCode:produced:layoutIsASCIICapable:)` takes the layout as a parameter; keyCode 6 with
/// a Cyrillic `я` and `layoutIsASCIICapable: false` resolves to `z`, which is this monitor's ⌘Z.
///
/// What is left here is still worth pinning: that the monitor feeds `chordKey` the right key code and
/// the right character accessor, and that named keys win before it is consulted.
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

    // an alternative LATIN layout keeps its own letter positions: on Dvorak the physical Z position types
    // ";", so ⌘Z follows the Z the user actually types rather than the ANSI Z position.
    func testAlternativeLatinLayoutKeepsItsOwnLetterPositions() throws {
        try skipUnlessLayoutIsASCIICapable()
        let event = try keyDown(";", keyCode: 6, flags: .command)
        XCTAssertEqual(shortcut.chord(from: event), Chord(mods: [.command], key: ";"))
    }

    // the character accessor, not the key code, is what an ASCII-capable layout binds — pinning which of
    // the two the monitor passes through. A remapped Latin layout typing a non-ASCII character keeps it
    // and simply matches no chord, rather than being pulled onto the ANSI position.
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
}
