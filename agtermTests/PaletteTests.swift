import XCTest
@testable import agterm

/// Hosted coverage for `CommandPalette.selectionStep`, which takes the layout as a parameter because a test
/// cannot change the machine's input source.
@MainActor
final class PaletteTests: XCTestCase {
    private func step(_ keyCode: UInt16, _ produced: String?, ascii: Bool) -> Int? {
        CommandPalette.selectionStep(keyCode: keyCode, produced: produced, layoutIsASCIICapable: ascii)
    }

    func testLatinLayoutMovesByTheTypedLetter() {
        XCTAssertEqual(step(38, "j", ascii: true), 1)
        XCTAssertEqual(step(40, "k", ascii: true), -1)
        XCTAssertEqual(step(38, "J", ascii: true), 1, "caps lock")
        XCTAssertEqual(step(40, "K", ascii: true), -1, "caps lock")
    }

    // regression: on a Cyrillic layout the J and K keys type `о` and `л`, and the selection did not move.
    func testNonLatinLayoutMovesByThePhysicalPosition() {
        XCTAssertEqual(step(38, "о", ascii: false), 1)
        XCTAssertEqual(step(40, "л", ascii: false), -1)
        XCTAssertEqual(step(38, nil, ascii: false), 1)
    }

    // on Dvorak the physical J position (key code 38) types `h` and `j` sits on key code 8.
    func testAlternativeLatinLayoutKeepsItsOwnLetterPositions() {
        XCTAssertNil(step(38, "h", ascii: true))
        XCTAssertEqual(step(8, "j", ascii: true), 1)
        XCTAssertEqual(step(9, "k", ascii: true), -1)
    }

    func testOnlyTheMembershipEditorsStayOpenAfterARun() {
        XCTAssertTrue(PaletteMode.flaggedEditor.keepsOpenOnRun)
        XCTAssertTrue(PaletteMode.focusEditor.keepsOpenOnRun)
        for mode in [PaletteMode.actions, .sessions, .themes, .customCommands, .attention] {
            XCTAssertFalse(mode.keepsOpenOnRun, "\(mode)")
        }
    }

    func testEmptyQueriesKeepTheFeedOrderExceptForActionsThemesAndCustomCommands() {
        for mode in [PaletteMode.sessions, .attention, .flaggedEditor, .focusEditor] {
            XCTAssertTrue(mode.keepsSourceOrder, "\(mode)")
        }
        for mode in [PaletteMode.actions, .themes, .customCommands] {
            XCTAssertFalse(mode.keepsSourceOrder, "\(mode)")
        }
    }

    func testOtherKeysDoNotMove() {
        XCTAssertNil(step(0, "a", ascii: true))
        XCTAssertNil(step(0, "ф", ascii: false))
        XCTAssertNil(step(38, "о", ascii: true), "a Latin layout typing a non-ASCII character binds what it types")
        XCTAssertNil(step(38, nil, ascii: true))
    }
}
