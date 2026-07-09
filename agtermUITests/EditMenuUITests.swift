import AppKit
import XCTest

/// Drives the standard Edit menu to verify `GhosttySurfaceView`'s responder methods and `validateMenuItem`.
/// The menu items are AppKit's stock nil-target Copy/Paste/Select All: they enable only when the responder
/// chain reaches the terminal AND the surface can actually service them, so `isEnabled` is a direct read of
/// `validateMenuItem`'s three gates.
///
/// Subclasses `ControlAPITestCase` for the isolated state dir + control socket, which is what lets a test
/// create a real terminal selection (`session.selectall`) without synthesizing a mouse drag over the grid.
///
/// **Pasteboard state must be POLLED, never read once.** The app process observes `NSPasteboard.general`
/// through its own cache: instrumenting `hasPasteboardText` showed the app validating the menu at a
/// `changeCount` behind the runner's, seeing the empty instant between `clearContents()` and the write.
/// That is a test-harness race, not app behavior (a user copies in Finder and opens the menu long after).
/// So every clipboard-dependent assertion polls until the app catches up, and each "disabled" expectation is
/// entered from a known-enabled state so a stale read cannot satisfy it.
///
/// The runner is also SANDBOXED, which bounds what can be seeded at all — see the note above
/// `testEditMenuLeavesCutAndUndoDisabledForTerminal`.
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

    /// Re-open the Edit menu until `title` reaches `expected`, or the deadline passes. Returns the final
    /// observed state, so the caller still asserts the real condition — a gate that never reaches `expected`
    /// fails, it does not silently pass.
    @discardableResult
    private func pollEditMenuItem(_ title: String, isEnabled expected: Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var observed = !expected
        repeat {
            withEditMenu { observed = app.menuItems[title].isEnabled }
            if observed == expected { return observed }
            usleep(200_000)
        } while Date() < deadline
        return observed
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

        XCTAssertTrue(pollEditMenuItem("Copy", isEnabled: true),
                      "Copy should enable once the buffer is selected")
    }

    // Paste is gated on the clipboard holding something the paste path can insert. Seeded text FIRST, so the
    // later empty-clipboard expectation starts from a confirmed-enabled state and cannot pass on a stale read.
    func testEditMenuGatesPasteOnClipboardText() throws {
        seedPasteboard { $0.setString("pasteable", forType: .string) }
        XCTAssertTrue(pollEditMenuItem("Paste", isEnabled: true),
                      "Paste should enable when the clipboard holds text")

        seedPasteboard { _ in }  // deliberately empty
        XCTAssertFalse(pollEditMenuItem("Paste", isEnabled: false),
                       "Paste should disable once the clipboard is emptied")
    }

    // NOTE: the file-URL Paste case (a Finder copy, which carries no string representation) is NOT covered
    // here and cannot be. The XCUITest runner is sandboxed (`com.apple.security.app-sandbox`), so a file URL
    // it writes to `NSPasteboard.general` never becomes visible to the app process — instrumenting
    // `hasPasteboardText` showed the app reading `types=[]` for the full 8 s of polling while the runner's own
    // `canReadObject([NSURL])` returned true from its in-process cache. Such a test exercises the sandbox, not
    // `validateMenuItem`. The invariant it would have pinned lives in the code instead: `hasPasteboardText`
    // must mirror `pasteboardText`'s branches. See the Control API rule.

    // Cut is deliberately NOT implemented on the surface, so AppKit leaves it disabled for the terminal.
    // (It still works in a focused text field, whose field editor implements `cut:`.) It cannot be removed
    // on its own: it shares SwiftUI's `.pasteboard` group with Copy/Paste/Select All.
    func testEditMenuLeavesCutDisabledForTerminal() throws {
        withEditMenu {
            XCTAssertFalse(app.menuItems["Cut"].isEnabled, "Cut should stay disabled for the terminal")
        }
    }

    // Undo/Redo are removed outright (`CommandGroup(replacing: .undoRedo) {}`): agterm has no undo manager,
    // and their ⌘Z is already owned by File ▸ Reopen Closed Item. Asserting NON-EXISTENCE rather than
    // `isEnabled == false` matters — `isEnabled` on a missing element is also false, so a disabled-check
    // would keep passing if the items ever came back.
    func testEditMenuHasNoUndoOrRedoItems() throws {
        withEditMenu {
            XCTAssertFalse(app.menuItems["Undo"].exists, "Undo should be gone from the Edit menu")
            XCTAssertFalse(app.menuItems["Redo"].exists, "Redo should be gone from the Edit menu")
        }
        // ⌘Z belongs to File ▸ Reopen Closed Item, and nothing in Edit competes for it any more.
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["Reopen Closed Item"].waitForExistence(timeout: 5),
                      "File should still own the ⌘Z action")
        app.typeKey(.escape, modifierFlags: [])
    }
}
