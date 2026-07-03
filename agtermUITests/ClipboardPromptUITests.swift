import AppKit
import XCTest

/// End-to-end coverage for the OSC 52 clipboard gate (the NSAlert sheet + terminal effect that the
/// host-free `ClipboardPromptPolicyTests` can't reach). Drives a session to emit real OSC 52 read/write
/// escapes, clicks Allow/Deny on the sheet, and asserts the observable effect: the terminal's OSC 52
/// response for reads (via `session.text`), and the system clipboard for writes.
///
/// Reads are gated by ghostty's `clipboard-read = ask` default (no config needed); writes need
/// `clipboard-write = ask`, so the write tests relaunch with that config.
@MainActor
final class ClipboardPromptUITests: ControlAPITestCase {
    private var savedClipboard: String?

    override func setUp() async throws {
        // best-effort save/restore of the developer's clipboard STRING around these tests (which read and
        // write it). Non-string clipboard content (images, rich text) is not preserved.
        savedClipboard = NSPasteboard.general.string(forType: .string)
        try await super.setUp()
    }

    override func tearDown() async throws {
        try await super.tearDown()
        NSPasteboard.general.clearContents()
        if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
    }

    // MARK: - helpers

    private func setSystemClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func base64(_ value: String) -> String { Data(value.utf8).base64EncodedString() }

    /// Type a `printf '<body>'` line into `target` and wait for the named clipboard sheet to appear,
    /// retrying the injection (a freshly realized shell can drop the first keystrokes; a re-emitted OSC 52
    /// from the same surface just coalesces into the one prompt). Returns the Allow/Deny sheet buttons.
    private func emitOSC52(printfBody: String, sheetButton title: String, target: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let button = app.sheets.buttons[title]
        for _ in 0..<4 {
            let typed = try sendCommand(typeRequest(text: "printf '\(printfBody)'\n", target: target, select: true))
            XCTAssertEqual(typed["ok"] as? Bool, true, "session.type should succeed", file: file, line: line)
            if button.waitForExistence(timeout: 4) { return button }
        }
        XCTFail("clipboard prompt sheet with button '\(title)' never appeared", file: file, line: line)
        return button
    }

    /// The target session's on-screen buffer as plain text (via `session.text`).
    private func sessionText(target: String) throws -> String {
        let response = try sendCommand(#"{"cmd":"session.text","target":"\#(target)"}"#)
        let result = response["result"] as? [String: Any]
        return (result?["text"] as? String) ?? ""
    }

    /// Polls `session.text` until `predicate` holds, returning the matching buffer or nil on timeout.
    private func pollSessionText(target: String, timeout: TimeInterval, _ predicate: (String) -> Bool) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? sessionText(target: target), predicate(text) { return text }
            usleep(200_000)
        }
        return nil
    }

    private func pollClipboard(equals expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSPasteboard.general.string(forType: .string) == expected { return true }
            usleep(200_000)
        }
        return NSPasteboard.general.string(forType: .string) == expected
    }

    // MARK: - read gate

    func testReadPromptDenyWithholdsClipboard() throws {
        let id = try activeSessionID()
        let secret = "SECRETREADXYZ"
        setSystemClipboard(secret)
        let deny = try emitOSC52(printfBody: "\\033]52;c;?\\007", sheetButton: "Deny", target: id)
        deny.click()
        // deny delivers an EMPTY OSC 52 response, so the shell echoes "52;c;" with no clipboard base64.
        let buffer = pollSessionText(target: id, timeout: 6) { $0.contains("52;c;") && !$0.contains(self.base64(secret)) }
        XCTAssertNotNil(buffer, "a denied read must not deliver the clipboard base64 (\(base64(secret)))")
    }

    func testReadPromptAllowDeliversClipboard() throws {
        let id = try activeSessionID()
        let secret = "SECRETREADABC"
        setSystemClipboard(secret)
        let allow = try emitOSC52(printfBody: "\\033]52;c;?\\007", sheetButton: "Allow", target: id)
        allow.click()
        // allow delivers the clipboard, so the shell echoes the OSC 52 response carrying its base64.
        let buffer = pollSessionText(target: id, timeout: 6) { $0.contains(self.base64(secret)) }
        XCTAssertNotNil(buffer, "an allowed read must deliver the clipboard base64 (\(base64(secret)))")
    }

    // MARK: - write gate

    func testWritePromptAllowSetsClipboard() throws {
        try relaunch(withGhosttyConfig: "clipboard-write = ask\n")
        let id = try activeSessionID()
        setSystemClipboard("OLD-WRITE-VALUE")
        let allow = try emitOSC52(printfBody: "\\033]52;c;\(base64("NEW-WRITE-VALUE"))\\007", sheetButton: "Allow", target: id)
        allow.click()
        XCTAssertTrue(pollClipboard(equals: "NEW-WRITE-VALUE", timeout: 6), "an allowed write must set the clipboard")
    }

    func testWritePromptDenyLeavesClipboard() throws {
        try relaunch(withGhosttyConfig: "clipboard-write = ask\n")
        let id = try activeSessionID()
        setSystemClipboard("KEEP-THIS-VALUE")
        let deny = try emitOSC52(printfBody: "\\033]52;c;\(base64("SHOULD-NOT-STICK"))\\007", sheetButton: "Deny", target: id)
        deny.click()
        // give the denied write a beat to (not) run, then confirm the clipboard is unchanged.
        usleep(500_000)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "KEEP-THIS-VALUE", "a denied write must not change the clipboard")
    }
}
