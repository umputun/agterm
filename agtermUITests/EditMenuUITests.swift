import AppKit
import XCTest

/// Drives the standard Edit menu to verify `GhosttySurfaceView`'s responder methods and `validateMenuItem`.
/// The menu items are AppKit's stock nil-target Copy/Paste/Select All: they enable only when the responder
/// chain reaches the terminal AND the surface can actually service them, so `isEnabled` is a direct read of
/// `validateMenuItem`'s three gates.
///
/// Subclasses `ControlAPITestCase` for the isolated state dir + control socket, which is what lets a test
/// create a real terminal selection (`session.selectall`) without synthesizing a mouse drag over the grid.
@MainActor
final class EditMenuUITests: ControlAPITestCase {
    /// Open the Edit menu, run `body` against it, then dismiss. Menu validation runs on open, so the
    /// item state read inside `body` reflects `validateMenuItem` for the current first responder.
    private func withEditMenu(_ body: () throws -> Void) rethrows {
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5), "Edit menu should offer Copy")
        try body()
        app.typeKey(.escape, modifierFlags: [])
    }

    // Copy is gated on ghostty_surface_has_selection: disabled on a fresh session, enabled once
    // session.selectall creates a selection. Select All is gated only on a realized surface, so it is
    // always enabled while the terminal holds first responder.
    func testEditMenuGatesCopyOnSelection() throws {
        let id = try activeSessionID()

        withEditMenu {
            XCTAssertFalse(app.menuItems["Copy"].isEnabled, "Copy should be disabled with no selection")
            XCTAssertTrue(app.menuItems["Select All"].isEnabled, "Select All should be enabled on a realized surface")
        }

        let selected = try sendCommand(#"{"cmd":"session.selectall","target":"\#(id)"}"#)
        XCTAssertEqual(selected["ok"] as? Bool, true, "session.selectall should succeed: \(selected)")

        withEditMenu {
            XCTAssertTrue(app.menuItems["Copy"].isEnabled, "Copy should enable once the buffer is selected")
        }
    }

    // Paste is gated on the clipboard holding something the paste path can insert.
    func testEditMenuGatesPasteOnClipboardText() throws {
        seedPasteboard { _ in }  // deliberately empty
        withEditMenu {
            XCTAssertFalse(app.menuItems["Paste"].isEnabled, "Paste should be disabled with an empty clipboard")
        }

        seedPasteboard { $0.setString("pasteable", forType: .string) }
        withEditMenu {
            XCTAssertTrue(app.menuItems["Paste"].isEnabled, "Paste should enable when the clipboard holds text")
        }
    }

    // Regression: the clipboard may hold a file URL with NO string representation (a Finder copy), which the
    // paste path (GhosttyCallbacks.pasteboardText) turns into a shell-escaped path. Validating with a plain
    // `canReadObject(forClasses: [NSString.self])` probe reported "nothing to paste" and greyed the item out
    // while ⌘V pasted the path anyway — exactly the menu-vs-keyboard divergence these responders remove.
    func testEditMenuEnablesPasteForFileURLClipboard() throws {
        seedPasteboard { pb in
            pb.writeObjects([URL(fileURLWithPath: "/tmp/agterm-paste-probe.txt") as NSURL])
        }
        XCTAssertFalse(NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil),
                       "precondition: a file-URL pasteboard carries no NSString representation")

        withEditMenu {
            XCTAssertTrue(app.menuItems["Paste"].isEnabled,
                          "Paste must enable for a file-URL clipboard, since the paste path inserts its path")
        }
    }

    // Cut/Undo/Redo are deliberately NOT implemented on the surface, so AppKit leaves them disabled for the
    // terminal. (They still work in a focused text field, whose field editor implements them.)
    func testEditMenuLeavesCutAndUndoDisabledForTerminal() throws {
        withEditMenu {
            XCTAssertFalse(app.menuItems["Cut"].isEnabled, "Cut should stay disabled for the terminal")
            XCTAssertFalse(app.menuItems["Undo"].isEnabled, "Undo should stay disabled for the terminal")
        }
    }
}
