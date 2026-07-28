import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `UndoCloseShortcut.chord(from:)`, the `NSEvent` → `Chord` half of the undo-close
/// monitor. It lives here rather than in `agtermCoreTests` because the mapping reads `NSEvent` accessors
/// an AppKit-free target cannot construct.
///
/// The monitor resolves its base key from `charactersIgnoringModifiers`, which a synthesized event
/// reports verbatim — so a non-Latin layout is reproducible here. The custom-command runner's own
/// mapping is NOT: it reads `characters(byApplyingModifiers:)`, which AppKit re-translates from the key
/// code through the machine's ACTIVE input source, so a synthesized Cyrillic press comes back Latin on a
/// Latin-layout machine and the test would assert the tester's keyboard rather than the code. Both
/// monitors share one resolution — `chordKey(forKeyCode:produced:)`, covered in `KeybindTests`.
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

    // on a Cyrillic layout the physical Z key types `я`, so matching the produced character left the
    // default ⌘Z unreachable. The chord resolves by physical position instead.
    func testCyrillicLayoutChordResolvesToTheLatinPosition() throws {
        let event = try keyDown("я", keyCode: 6, flags: .command)
        XCTAssertEqual(shortcut.chord(from: event), BuiltinAction.undoClose.defaultChord)
    }

    // an alternative LATIN layout keeps its own letter positions: on Dvorak the physical Z position types
    // ";", so ⌘Z follows the Z the user actually types rather than the ANSI Z position.
    func testAlternativeLatinLayoutKeepsItsOwnLetterPositions() throws {
        let event = try keyDown(";", keyCode: 6, flags: .command)
        XCTAssertEqual(shortcut.chord(from: event), Chord(mods: [.command], key: ";"))
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
