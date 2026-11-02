import WebKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class TextPageRenderingTests: HtmlPageTestCase {
    private static let hostile = """
        <script>document.title = 'ran'</script> <img src=x onerror="document.title = 'ran'"> <link rel=stylesheet href=s.css>
        <iframe src="https://example.com/"></iframe> <meta http-equiv="refresh" content="0;url=https://example.com/">
        <a href="https://example.com/x">x</a> javascript:document.title='ran' <object data=x></object> https://example.com/y

        """
    private static let rendererWorld = WKContentWorld.world(name: "agterm-markdown")

    func testHostileTextStaysTextWhetherPlainOrHighlighted() async throws {
        for name in ["hostile.txt", "hostile.js"] {
            let page = registry.page(for: try openText(name, Self.hostile), store: store)
            page.webView.configuration.userContentController.addUserScript(WKUserScript(source: """
                document.addEventListener('securitypolicyviolation', e => {
                  document.documentElement.dataset.blocked = (document.documentElement.dataset.blocked || '') + e.blockedURI + ' ';
                });
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .world(name: "probe")))
            try await waitForScript("document.querySelector('pre code')?.textContent.length ?? 0", in: page.webView) { $0 != "0" }
            try await Task.sleep(for: .milliseconds(300))

            let dom = try await page.webView.evaluateJavaScript("""
                [document.querySelector('pre code').textContent === \(try json(Self.hostile)),
                 document.querySelectorAll('script, img, link, iframe, a, object, embed, form, base').length,
                 document.querySelectorAll('meta').length, document.title, location.href,
                 document.documentElement.dataset.blocked ?? ''].join('|')
                """)
            XCTAssertEqual(dom as? String, "true|0|2||about:blank|", name)
            XCTAssertEqual(current?.loadState, .loaded, name)
            XCTAssertEqual(browser.prompts, [], name)
            XCTAssertEqual(browser.opened, [], name)
            XCTAssertEqual(sharing.revealed, [], name)
            store.closeHtmlOverlay(page.id)
        }
    }

    func testOnlyHighlightJsOutputReachesMarkupAndItCarriesNoAuthoredTags() async throws {
        let page = registry.page(for: try openText("hostile.js", Self.hostile), store: store)
        try await waitForScript("document.querySelectorAll('pre code span').length", in: page.webView) { $0 != "0" }

        let tags = try await page.webView.evaluateJavaScript("""
            [...new Set([...document.querySelectorAll('pre code *')].map(e => e.tagName))].join(',')
            """)
        XCTAssertEqual(tags as? String, "SPAN")
    }

    func testTheRendererRunsIsolatedWithPageScriptOffNoBridgeAndNoBaseURL() async throws {
        let page = registry.page(for: try openText("main.go", "package main\n"), store: store)
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "package main\n" }

        XCTAssertFalse(page.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let inPage = try await page.webView.evaluateJavaScript("""
            [typeof hljs, typeof window.agterm, typeof window.webkit?.messageHandlers?.agterm, document.baseURI].join('|')
            """)
        XCTAssertEqual(inPage as? String, "undefined|undefined|undefined|about:blank")
        let inRenderer = try await page.webView.evaluateJavaScript("typeof hljs", in: nil, contentWorld: Self.rendererWorld)
        XCTAssertEqual(inRenderer as? String, "object")
        let bridge = try await page.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.agterm", in: nil,
                                                               contentWorld: HtmlOverlayBridge.world)
        XCTAssertEqual(bridge as? String, "undefined")
    }

    func testATextPageStaysInItsOverlay() async throws {
        let overlay = try openText("main.go", "package main\n")
        _ = registry.page(for: overlay, store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded }

        XCTAssertEqual(registry.navigate(overlay.id, .browser), OverlayHtmlError.textInOverlay)
        XCTAssertEqual(registry.navigate(overlay.id, .finder), OverlayHtmlError.finderRequiresFile)
        XCTAssertEqual(browser.opened, [])
        XCTAssertEqual(sharing.revealed, [])
    }

    func testMappedSourceIsHighlightedAndPlainOrOversizedTextIsNot() async throws {
        let cases: [(String, String, Bool)] = [
            ("main.go", "package main\n\nfunc main() { return }\n", true),
            ("App.swift", "import Foundation\nlet x = 1\n", true),
            ("notes.txt", "func main() { return }\n", false),
            ("big.go", String(repeating: "func main() { return }\n", count: TextPage.maxHighlightBytes / 23 + 1), false),
        ]
        for (name, text, highlighted) in cases {
            let page = registry.page(for: try openText(name, text), store: store)
            try await waitForScript("document.querySelector('pre code')?.textContent.length ?? 0", in: page.webView) { $0 == "\(text.utf16.count)" }

            let keywords = try await page.webView.evaluateJavaScript("document.querySelectorAll('pre code .hljs-keyword').length")
            XCTAssertEqual((keywords as? Int ?? 0) > 0, highlighted, name)
            store.closeHtmlOverlay(page.id)
        }
    }

    func testTheRequestedLineIsMarkedAndScrolledTo() async throws {
        let text = (1...400).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let page = registry.page(for: try openText("long.log", text, line: 300), store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitForScript("document.querySelector('.agterm-band')?.style.top ?? ''", in: page.webView) { $0 == "5992px" }

        let view = try await page.webView.evaluateJavaScript("""
            [document.querySelector('.agterm-gutter').textContent.split('\\n').length, window.scrollY > 5000].join('|')
            """)
        XCTAssertEqual(view as? String, "400|true")
    }

    func testALineOutsideTheFileMarksNothing() async throws {
        for line in [0, 4] {
            let page = registry.page(for: try openText("short.log", "a\nb\nc\n", line: line), store: store)
            try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "a\nb\nc\n" }

            let band = try await page.webView.evaluateJavaScript("document.querySelectorAll('.agterm-band').length")
            XCTAssertEqual(band as? Int, 0, "line \(line)")
            store.closeHtmlOverlay(page.id)
        }
    }

    // regression: a newline right after <pre> is dropped by the parser and shifted every line number
    func testALeadingBlankLineStaysInTheRenderedText() async throws {
        let page = registry.page(for: try openText("lead.swift", "\n\nfunc a() {}\n", line: 3), store: store)
        try await waitForScript("document.querySelector('.agterm-band')?.style.top ?? ''", in: page.webView) { $0 == "52px" }

        let rendered = try await page.webView.evaluateJavaScript("""
            [JSON.stringify(document.querySelector('pre code').textContent), document.querySelector('.agterm-gutter').textContent].join('|')
            """)
        XCTAssertEqual(rendered as? String, #""\n\nfunc a() {}\n"|1"# + "\n2\n3")
    }

    func testATextPageReRendersOnReloadAndOnAThemeChange() async throws {
        let overlay = try openText("notes.txt", "one\n")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "one\n" }

        try "two\n".write(to: pages.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertNil(registry.reload(page.id, target: .current, store: store))
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "two\n" }

        try "three\n".write(to: pages.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "three\n" }

        page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true))
        try await waitForVariable("--agterm-foreground", "#102030", in: page.webView)
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "three\n" }
    }

    func testAMissingOrBinaryFileReportsAFailure() async throws {
        let binary = pages.appendingPathComponent("bin.txt")
        try Data([0x61, 0x00, 0x62]).write(to: binary)
        let missing = pages.appendingPathComponent("missing.txt").path
        let cases = [(missing, TextProbe.Failure.unreadable(missing)), (binary.path, .notText(binary.path))]
        for (path, failure) in cases {
            let overlay = HtmlOverlay(source: .text(path: path, line: nil))
            XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
            _ = registry.page(for: overlay, store: store)

            try await waitFor("failed") { self.current?.loadState == .failed }
            XCTAssertEqual(current?.loadError, failure.description)
            store.closeHtmlOverlay(overlay.id)
        }
    }

    func testANearCapFileRendersInBoundedTime() async throws {
        let line = "func main() { return }\n"
        let cases = [("high.go", TextPage.maxHighlightBytes), ("plain.log", TextPage.maxBytes)]
        for (name, size) in cases {
            let text = String(repeating: line, count: size / line.utf8.count)
            let clock = ContinuousClock(), started = clock.now
            let page = registry.page(for: try openText(name, text), store: store)
            try await waitForScript("document.querySelector('pre code')?.textContent.length ?? 0", in: page.webView) { $0 == "\(text.utf16.count)" }

            XCTAssertLessThan(clock.now - started, .seconds(10), name)
            store.closeHtmlOverlay(page.id)
        }
    }

    private func openText(_ name: String, _ text: String, line: Int? = nil) throws -> HtmlOverlay {
        let url = pages.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let overlay = HtmlOverlay(source: .text(path: url.path, line: line))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }

    private func json(_ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    }
}
