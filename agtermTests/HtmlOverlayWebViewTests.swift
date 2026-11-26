import WebKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class HtmlOverlayWebViewTests: HtmlPageTestCase {
    private static let code = "document.querySelector('pre code')?.textContent ?? ''"
    private static let count = "document.querySelector('.agterm-count')?.textContent ?? ''"
    private static let menuOpen = "String(!document.querySelector('.agterm-files-menu').hidden)"
    private static let twoFiles = ["diff --git a/a.go b/a.go", "--- a/a.go", "+++ b/a.go", "@@ -1,2 +1,2 @@", " a", "-b", "+c",
                                   "diff --git a/b.go b/b.go", "--- a/b.go", "+++ b/b.go", "@@ -1,2 +1,2 @@", " d", "-e", "+f"]
        .joined(separator: "\n") + "\n"

    private func shownViewer(_ name: String, _ text: String) async throws -> (HtmlOverlay, HtmlOverlayPage, NSWindow) {
        let overlay = try openText(name, text)
        let (page, window) = try shown(overlay)
        window.makeKeyAndOrderFront(nil)
        try await waitForScript(Self.code, in: page.webView) { !$0.isEmpty }
        window.makeFirstResponder(page.webView)
        return (overlay, page, window)
    }

    private func search(_ query: String, on page: HtmlOverlayPage) throws {
        store.setTextSearch(page.id, query: query)
        page.apply(try XCTUnwrap(current))
    }

    private func shownCount(_ page: HtmlOverlayPage) async throws -> String? {
        _ = try await page.webView.evaluateJavaScript("1")
        return try await page.webView.evaluateJavaScript(Self.count) as? String
    }

    func testEscapeLeavesTheFindBoxThenClearsAShownQueryThenClosesTheViewer() async throws {
        let (overlay, page, window) = try await shownViewer("a.txt", "alpha\nbeta\nalpha\n")
        defer { window.orderOut(nil) }
        let focused = "String(document.activeElement === document.querySelector('.agterm-search input'))"

        page.focusSearch()
        try await waitForScript(focused, in: page.webView) { $0 == "true" }
        try sendEscape(to: window)
        try await waitForScript(focused, in: page.webView) { $0 == "false" }
        _ = try await page.webView.evaluateJavaScript("1")
        XCTAssertNotNil(store.htmlOverlaySlot(overlay.id))

        try search("alpha", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 2" }
        try sendEscape(to: window, repeating: true)
        try sendEscape(to: window, repeating: true)
        let held = try await shownCount(page)
        XCTAssertEqual(held, "1 of 2", "a held Esc's repeats should not reach the page")
        XCTAssertNotNil(store.htmlOverlaySlot(overlay.id))

        try sendEscape(to: window)
        try await waitForScript(Self.count, in: page.webView) { $0.isEmpty }
        _ = try await page.webView.evaluateJavaScript("1")
        XCTAssertNotNil(store.htmlOverlaySlot(overlay.id))

        try sendEscape(to: window)
        try await waitFor("the viewer closed") { self.store.htmlOverlaySlot(overlay.id) == nil }
    }

    func testCommandPeriodStepsBackOneLayerLikeEscape() async throws {
        let (overlay, page, window) = try await shownViewer("a.txt", "alpha\nbeta\nalpha\n")
        defer { window.orderOut(nil) }

        try search("alpha", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 2" }
        try sendKey(".", keyCode: 47, modifiers: .command, to: window, repeating: true)
        try sendKey(".", keyCode: 47, modifiers: [.command, .capsLock], to: window, repeating: true)
        let held = try await shownCount(page)
        XCTAssertEqual(held, "1 of 2", "a held ⌘.'s repeats should not reach the page")
        XCTAssertNotNil(store.htmlOverlaySlot(overlay.id))

        try sendKey(".", keyCode: 47, modifiers: .command, to: window)
        try await waitForScript(Self.count, in: page.webView) { $0.isEmpty }
        _ = try await page.webView.evaluateJavaScript("1")
        XCTAssertNotNil(store.htmlOverlaySlot(overlay.id))

        try sendKey(".", keyCode: 47, modifiers: .command, to: window)
        try await waitFor("the viewer closed") { self.store.htmlOverlaySlot(overlay.id) == nil }
    }

    func testAHeldCommandPeriodKeyEquivalentIsDroppedOnlyByTheFocusedViewer() async throws {
        let (_, page, window) = try await shownViewer("a.txt", "alpha\nbeta\nalpha\n")
        defer { window.orderOut(nil) }
        try search("alpha", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 2" }
        let held = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: ".", charactersIgnoringModifiers: ".",
            isARepeat: true, keyCode: 47))

        XCTAssertTrue(page.webView.performKeyEquivalent(with: held))
        let after = try await shownCount(page)
        XCTAssertEqual(after, "1 of 2")

        window.makeFirstResponder(nil)
        XCTAssertFalse(page.webView.performKeyEquivalent(with: held))
    }

    func testAModifiedEscapeLeavesAShownQuery() async throws {
        let (_, page, window) = try await shownViewer("a.txt", "alpha\nbeta\nalpha\n")
        defer { window.orderOut(nil) }
        try search("alpha", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 2" }

        try sendKey("\u{1b}", keyCode: 53, modifiers: .option, to: window)
        let after = try await shownCount(page)

        XCTAssertEqual(after, "1 of 2")
    }

    func testEscapeKeepsAViewerWhoseFocusMovedBeforeWebKitAnswered() async throws {
        let (overlay, page, window) = try await shownViewer("a.txt", "alpha\n")
        defer { window.orderOut(nil) }

        try sendEscape(to: window)
        window.makeFirstResponder(nil)
        _ = try await page.webView.evaluateJavaScript("1")

        XCTAssertNotNil(store.htmlOverlaySlot(overlay.id))
    }

    func testEscapeWithTheFileListOpenClosesOnlyTheList() async throws {
        let (overlay, page, window) = try await shownViewer("a.diff", Self.twoFiles)
        defer { window.orderOut(nil) }
        try await press("f", page.webView)
        try await waitForScript(Self.menuOpen, in: page.webView) { $0 == "true" }

        try sendEscape(to: window)
        try await waitForScript(Self.menuOpen, in: page.webView) { $0 == "false" }
        _ = try await page.webView.evaluateJavaScript("1")

        XCTAssertNotNil(store.htmlOverlaySlot(overlay.id), "Esc should close only the file list, not the diff page")
    }
}
