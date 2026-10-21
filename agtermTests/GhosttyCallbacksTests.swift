import AppKit
import GhosttyKit
import XCTest
@testable import agterm

@MainActor
final class GhosttyCallbacksTests: XCTestCase {
    private var selection: NSPasteboard { GhosttyCallbacks.pasteboard(for: GHOSTTY_CLIPBOARD_SELECTION) }

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            preserve(.general)
            preserve(selection)
        }
    }

    func testSelectionWriteLandsOnPrivatePasteboardAndLeavesGeneralAlone() {
        seed(.general, "keep me")
        write("selected text", location: GHOSTTY_CLIPBOARD_SELECTION)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "keep me")
        XCTAssertEqual(selection.string(forType: .string), "selected text")
    }

    func testStandardWriteLandsOnGeneralAndLeavesSelectionAlone() {
        seed(selection, "old selection")
        write("copied text", location: GHOSTTY_CLIPBOARD_STANDARD)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "copied text")
        XCTAssertEqual(selection.string(forType: .string), "old selection")
    }

    func testPrimaryWriteLandsOnGeneral() {
        seed(selection, "old selection")
        write("osc 52 p", location: GHOSTTY_CLIPBOARD_PRIMARY)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "osc 52 p")
        XCTAssertEqual(selection.string(forType: .string), "old selection")
    }

    func testClipboardTextReadsTheLocationsPasteboard() {
        seed(.general, "system clipboard")
        seed(selection, "last selection")
        XCTAssertEqual(GhosttyCallbacks.clipboardText(for: GHOSTTY_CLIPBOARD_SELECTION), "last selection")
        XCTAssertEqual(GhosttyCallbacks.clipboardText(for: GHOSTTY_CLIPBOARD_STANDARD), "system clipboard")
        XCTAssertEqual(GhosttyCallbacks.clipboardText(for: GHOSTTY_CLIPBOARD_PRIMARY), "system clipboard")
    }

    func testSelectionPasteboardIsNamedForThisBundle() {
        XCTAssertNotEqual(selection.name, NSPasteboard.general.name)
        XCTAssertEqual(selection.name.rawValue, (Bundle.main.bundleIdentifier ?? "") + ".selection")
    }

    private func write(_ text: String, location: ghostty_clipboard_e) {
        "text/plain".withCString { mime in
            text.withCString { data in
                var item = ghostty_clipboard_content_s(mime: mime, data: data, len: text.utf8.count)
                GhosttyApp.shared.callbacks.writeClipboard(ud: nil, location: location, content: &item, len: 1, confirm: false)
            }
        }
    }

    private func seed(_ pasteboard: NSPasteboard, _ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func preserve(_ pasteboard: NSPasteboard) {
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        addTeardownBlock {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }
}
