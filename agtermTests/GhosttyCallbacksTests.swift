import AppKit
import GhosttyKit
import XCTest
@testable import agterm
import agtermCore

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

    func testOnlyAReleasedUnknownKindIsADetectedLinkClick() {
        let cases: [(ghostty_action_open_url_kind_e, Bool, LinkPolicy.ClickSource)] = [
            (GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, true, .detected), (GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, false, .other),
            (GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, true, .osc8), (GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, false, .osc8),
            (GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, true, .other), (GHOSTTY_ACTION_OPEN_URL_KIND_HTML, true, .other),
            (ghostty_action_open_url_kind_e(rawValue: 99), true, .other),
        ]
        for (kind, released, want) in cases {
            XCTAssertEqual(LinkPolicy.ClickSource(kind, released: released), want, "kind \(kind.rawValue) released \(released)")
        }
    }

    func testAWriteFromARetiredSurfaceIsDropped() {
        let view = GhosttySurfaceView(workingDirectory: "/tmp")
        seed(selection, "old selection")
        write("from a live pane", location: GHOSTTY_CLIPBOARD_SELECTION, from: view)
        XCTAssertEqual(selection.string(forType: .string), "from a live pane")

        view.retired.withLock { $0 = true }
        write("from a closed pane", location: GHOSTTY_CLIPBOARD_SELECTION, from: view)

        XCTAssertEqual(selection.string(forType: .string), "from a live pane")
    }

    func testSelectionPasteboardIsNamedForThisBundle() {
        XCTAssertNotEqual(selection.name, NSPasteboard.general.name)
        XCTAssertEqual(selection.name.rawValue, (Bundle.main.bundleIdentifier ?? "") + ".selection")
    }

    private func write(_ text: String, location: ghostty_clipboard_e, from view: GhosttySurfaceView? = nil) {
        let ud = view.map { Unmanaged.passUnretained($0).toOpaque() }
        "text/plain".withCString { mime in
            text.withCString { data in
                var item = ghostty_clipboard_content_s(mime: mime, data: data, len: text.utf8.count)
                GhosttyApp.shared.callbacks.writeClipboard(ud: ud, location: location, content: &item, len: 1, confirm: false)
            }
        }
    }

    func testTheGateAgreesWithTheReaderForImageURLAndEmptyPasteboards() throws {
        let png = try XCTUnwrap(Self.pngData())
        let file = URL(fileURLWithPath: "/tmp/my report.pdf")
        let cases: [(name: String, fill: (NSPasteboard) -> Void, action: PasteOffer.Action?)] = [
            ("image only", { $0.setData(png, forType: .png) }, .image(png)),
            ("file url only", { $0.writeObjects([file as NSURL]) }, .urls([file])),
            ("empty", { _ in }, nil),
        ]
        for testCase in cases {
            let pasteboard = namedPasteboard()
            testCase.fill(pasteboard)

            XCTAssertEqual(GhosttyCallbacks.pasteOffer(pasteboard).action, testCase.action, testCase.name)
            XCTAssertEqual(GhosttyCallbacks.hasPasteOffer(pasteboard), testCase.action != nil, testCase.name)
        }
    }

    func testATIFFOnlyImageIsOfferedAsPNG() throws {
        let png = try XCTUnwrap(Self.pngData())
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: png)?.tiffRepresentation)
        let pasteboard = namedPasteboard()
        pasteboard.setData(tiff, forType: .tiff)

        guard case .image(let offered) = GhosttyCallbacks.pasteOffer(pasteboard).action else { return XCTFail("no image offered") }
        XCTAssertEqual(offered.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testAFileOfferIsHiddenFromAProgramOnAnotherHostAndTextIsNot() {
        let file = URL(fileURLWithPath: "/Users/me/shot.png")
        let standard: [(name: String, fill: (NSPasteboard) -> Void, hidden: Bool)] = [
            ("file urls", { $0.writeObjects([file as NSURL]) }, true),
            ("file urls and their string", { pb in
                pb.writeObjects([file as NSURL])
                pb.setString(file.path, forType: .string)
            }, true),
            ("text", { $0.setString("/Users/me/shot.png", forType: .string) }, false),
            ("web url", { $0.writeObjects([URL(string: "https://example.com")! as NSURL]) }, false),
        ]
        for testCase in standard {
            let pasteboard = namedPasteboard()
            testCase.fill(pasteboard)

            XCTAssertEqual(GhosttyCallbacks.hidesFilesOnOrigin(pasteboard, location: GHOSTTY_CLIPBOARD_STANDARD), testCase.hidden,
                           testCase.name)
        }
        let selection = namedPasteboard()
        selection.writeObjects([file as NSURL])
        XCTAssertFalse(GhosttyCallbacks.hidesFilesOnOrigin(selection, location: GHOSTTY_CLIPBOARD_SELECTION))
    }

    private func namedPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("agterm-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    private static func pngData() -> Data? {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return image?.representation(using: .png, properties: [:])
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
