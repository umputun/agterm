import WebKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class TextPageBridgeTests: HtmlPageTestCase {
    private static let code = "document.querySelector('pre code')?.textContent ?? ''"
    private static let button = "document.querySelector('.agterm-expand')?.textContent ?? ''"
    private static let gutter = "document.querySelector('.agterm-gutter')?.textContent ?? ''"
    private static let recordUnderBar = """
        (() => {
          const bar = document.querySelector('.agterm-bar').getBoundingClientRect();
          const code = document.querySelector('#agterm-page pre code');
          const caret = document.caretRangeFromPoint(code.getBoundingClientRect().left + 2, bar.bottom + 4);
          const before = document.createRange();
          before.setStart(code, 0);
          before.setEnd(caret.startContainer, caret.startOffset);
          const text = code.textContent;
          const end = text.indexOf('\\n', before.toString().length);
          return text.slice(0, end < 0 ? text.length : end).split('\\n').filter((row) => row.startsWith('{')).length;
        })()
        """

    private static func records(_ count: Int, message: String = "m") -> String {
        (1...count).map { #"{"id":\#($0),"tags":["a","b"],"meta":{"k":"v"},"msg":"\#(message)"}"# }.joined(separator: "\n") + "\n"
    }

    private static let laidOut = """
        {
          "id": 1,
          "tags": [
            "a",
            "b"
          ],
          "meta": {
            "k": "v"
          },
          "msg": "m"
        }
        """

    private func expand(_ on: Bool, _ page: HtmlOverlayPage) throws {
        XCTAssertEqual(store.setTextExpand(session.id, pane: nil, mode: on ? .on : .off), .success(on))
        page.apply(try XCTUnwrap(current))
    }

    private func scrollIntoRow(_ row: Int, _ view: WKWebView) async throws {
        _ = try await inRenderer("""
            (() => {
              const page = document.getElementById('agterm-page');
              const pre = page.querySelector('pre');
              const style = getComputedStyle(pre);
              const height = parseFloat(style.lineHeight);
              const top = page.offsetTop + pre.offsetTop + parseFloat(style.paddingTop) + (\(row) + 0.5) * height;
              document.scrollingElement.scrollTop = top - document.querySelector('.agterm-bar').offsetHeight;
              return true;
            })()
            """, view)
    }

    func testAJSONLinesPageOpensAsWrittenWithAGutterLinePerRecord() async throws {
        let (page, window) = try shown(try openText("events.jsonl", Self.records(3)))
        defer { window.orderOut(nil) }

        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: off" }
        let code = try await page.webView.evaluateJavaScript(Self.code) as? String
        XCTAssertEqual(code, Self.records(3))
        let gutter = try await page.webView.evaluateJavaScript(Self.gutter) as? String
        XCTAssertEqual(gutter, "1\n2\n3")
        let keys = try await page.webView.evaluateJavaScript("document.querySelectorAll('pre code .hljs-attr').length") as? Int
        XCTAssertEqual(keys, 15)
    }

    func testThePageButtonAndKeyLayTheRecordsOutNumberedByFileLine() async throws {
        let (page, window) = try shown(try openText("events.jsonl", Self.records(2)))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: off" }

        _ = try await inRenderer("document.querySelector('.agterm-expand').click(); true", page.webView)
        try await waitFor("the click reaches the model") { self.current?.textExpand == true }
        page.apply(try XCTUnwrap(current))

        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: on" }
        let code = try await page.webView.evaluateJavaScript(Self.code) as? String
        XCTAssertEqual(code, Self.laidOut + "\n" + Self.laidOut.replacingOccurrences(of: "\"id\": 1", with: "\"id\": 2") + "\n")
        let gutter = try await page.webView.evaluateJavaScript(Self.gutter) as? String
        XCTAssertEqual(gutter, "1" + String(repeating: "\n", count: 11) + "2" + String(repeating: "\n", count: 10))

        try await press("e", page.webView)
        try await waitFor("the key reaches the model") { self.current?.textExpand == false }
        page.apply(try XCTUnwrap(current))
        try await waitForScript(Self.code, in: page.webView) { $0 == Self.records(2) }
        try await waitForScript(Self.gutter, in: page.webView) { $0 == "1\n2" }
    }

    func testAControlExpandRedrawsThePageAndAThemeRebuildKeepsIt() async throws {
        let (page, window) = try shown(try openText("events.jsonl", Self.records(2)))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: off" }

        try expand(true, page)
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: on" }

        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))
        try await waitForVariable("--agterm-foreground", "#e0e0e0", in: page.webView)
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: on" }
        let code = try await page.webView.evaluateJavaScript(Self.code) as? String
        XCTAssertTrue(code?.hasPrefix(Self.laidOut) == true)
    }

    func testAnExpandSetWhileThePageLoadsIsWhatItShows() async throws {
        let overlay = try openText("events.jsonl", Self.records(2))
        let page = registry.page(for: overlay, store: store)

        try expand(true, page)

        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: on" }
        try await waitForScript(Self.code, in: page.webView) { $0.hasPrefix(Self.laidOut) }
    }

    func testAnExpandWhileTheRawDocumentAwaitsItsReadyIsLaidOutOnceReady() async throws {
        let (page, window) = try shown(try openText("events.jsonl", Self.records(2)))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: off" }
        page.webView.configuration.userContentController.addUserScript(WKUserScript(source: """
            (() => {
              const handler = Object.getPrototypeOf(window.webkit.messageHandlers.agtermTextPage);
              const post = handler.postMessage;
              handler.postMessage = function (body) {
                if (body && body.ready && document.querySelector('.agterm-expand')?.textContent === 'Expand: off') {
                  window.agtermHeldReady = () => post.call(this, body);
                  return;
                }
                return post.call(this, body);
              };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.rendererWorld))
        XCTAssertNil(registry.reload(page.id, target: .current, store: store))
        let deadline = Date().addingTimeInterval(10)
        while try await inRenderer("typeof window.agtermHeldReady", page.webView) as? String != "function" {
            guard Date() < deadline else { return XCTFail("the raw document never held its ready") }
            try await Task.sleep(for: .milliseconds(50))
        }

        try expand(true, page)
        _ = try await inRenderer("window.agtermHeldReady(); true", page.webView)

        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: on" }
        try await waitForScript(Self.code, in: page.webView) { $0.hasPrefix(Self.laidOut) }
    }

    func testTheRecordUnderTheBarStaysThereAcrossTheToggle() async throws {
        let (page, window) = try shown(try openText("events.jsonl", Self.records(300)))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: off" }
        try await scrollIntoRow(150, page.webView)
        try await waitForScript(Self.recordUnderBar, in: page.webView) { $0 == "151" }

        try expand(true, page)
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: on" }
        try await waitForScript(Self.recordUnderBar, in: page.webView) { $0 == "151" }

        try expand(false, page)
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: off" }
        try await waitForScript(Self.recordUnderBar, in: page.webView) { $0 == "151" }
    }

    func testTheLineBandCoversTheWholeRecord() async throws {
        let overlay = try openText("events.jsonl", Self.records(3), line: 2)
        store.setTextExpand(overlay.id, expanded: true)
        let (page, window) = try shown(try XCTUnwrap(current))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: on" }

        let rows = try await page.webView.evaluateJavaScript("""
            (() => {
              const band = document.querySelector('.agterm-band').getBoundingClientRect();
              const pre = document.querySelector('#agterm-page pre');
              const style = getComputedStyle(pre);
              const top = pre.getBoundingClientRect().top + parseFloat(style.paddingTop);
              const height = parseFloat(style.lineHeight);
              return [Math.round((band.top - top) / height), Math.round(band.height / height)].join('|');
            })()
            """) as? String
        XCTAssertEqual(rows, "11|11")
    }

    func testAWrapOnAnExpandedPageKeepsTheRecordUnderTheBar() async throws {
        let (page, window) = try shown(try openText("events.jsonl", Self.records(100, message: String(repeating: "word ", count: 40))))
        defer { window.orderOut(nil) }
        try expand(true, page)
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: on" }
        try await scrollIntoRow(500, page.webView)
        try await waitForScript(Self.recordUnderBar, in: page.webView) { $0 == "46" }

        try await press("w", page.webView)

        try await waitFor("the toggle reaches the model") { self.current?.textWrap == true }
        try await waitForScript("document.body.classList.contains('agterm-wrapped')", in: page.webView) { $0 == "true" }
        try await waitForScript(Self.recordUnderBar, in: page.webView) { $0 == "46" }
    }

    private func typeIntoSearch(_ view: WKWebView, insert: String, at caret: Int?) async throws {
        let place = caret.map(String.init) ?? "field.selectionStart"
        _ = try await inRenderer("""
            (() => {
              const field = document.querySelector('.agterm-search input');
              field.focus();
              field.setRangeText(\(try json(insert)), \(place), \(caret.map(String.init) ?? "field.selectionEnd"), 'end');
              field.dispatchEvent(new Event('input'));
              return true;
            })()
            """, view)
    }

    private static let field = """
        (() => {
          const field = document.querySelector('.agterm-search input');
          return [document.activeElement === field, field.value, field.selectionStart, field.selectionEnd].join('|');
        })()
        """

    private func assertTypingContinues(log: Bool = false, after rebuild: (HtmlOverlayPage) throws -> Void) async throws {
        let bar = log ? ".agterm-logbar" : ".agterm-expand"
        let (page, window) = try shown(log ? try openLog("events.log", Self.records(2)) : try openText("events.jsonl", Self.records(2)))
        defer { window.orderOut(nil) }
        try await waitForScript("document.querySelector('\(bar)') !== null", in: page.webView) { $0 == "true" }
        try await typeIntoSearch(page.webView, insert: "ab", at: 0)
        _ = try await inRenderer("document.querySelector('.agterm-search input').setSelectionRange(1, 1); true", page.webView)
        try await waitFor("the query reaches the model") { self.current?.textSearch?.query == "ab" }
        page.apply(try XCTUnwrap(current))
        _ = try await page.webView.evaluateJavaScript("document.body.dataset.replaced = 'no'; true")

        try rebuild(page)

        try await waitForScript("document.body.dataset.replaced === undefined && document.querySelector('\(bar)') !== null",
                                in: page.webView) { $0 == "true" }
        try await waitForScript(Self.field, in: page.webView) { $0 == "true|ab|1|1" }
        try await typeIntoSearch(page.webView, insert: "X", at: nil)
        try await waitFor("the continued query reaches the model") { self.current?.textSearch?.query == "aXb" }
        try await waitForScript(Self.field, in: page.webView) { $0 == "true|aXb|2|2" }
    }

    func testTypingContinuesAtTheCaretAfterAnExpandFromControl() async throws {
        try await assertTypingContinues { page in
            try self.expand(true, page)
        }
    }

    func testTypingContinuesAtTheCaretAfterAThemeRebuild() async throws {
        try await assertTypingContinues { page in
            page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))
        }
    }

    func testTypingContinuesAtTheCaretAfterALogPageThemeRebuild() async throws {
        try await assertTypingContinues(log: true) { page in
            page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))
        }
    }

    private func openLog(_ name: String, _ text: String) throws -> HtmlOverlay {
        let url = pages.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let overlay = HtmlOverlay(source: .text(path: url.path, line: nil), textLog: TextLog(tail: 500, follow: true))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }

    // regression: the page keys must leave an e typed into the search field to the field
    func testAnETypedIntoSearchStaysInTheQuery() async throws {
        let (page, window) = try shown(try openText("events.jsonl", Self.records(2)))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.button, in: page.webView) { $0 == "Expand: off" }

        _ = try await inRenderer("""
            (() => {
              const field = document.querySelector('.agterm-search input');
              field.focus();
              field.dispatchEvent(new KeyboardEvent('keydown', { key: 'e', bubbles: true }));
              return true;
            })()
            """, page.webView)
        try await typeIntoSearch(page.webView, insert: "e", at: 0)

        try await waitFor("the query reaches the model") { self.current?.textSearch?.query == "e" }
        XCTAssertEqual(current?.textExpand, false)
    }
}
