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

    func testATextReplicaRendersFetchedBytesAndRefetchesOnReloadAndThemeChange() async throws {
        let url = pages.appendingPathComponent("main.go")
        try "package one\n".write(to: url, atomically: true, encoding: .utf8)
        let page = registry.page(for: openReplica(url.path, .text(line: 1)), store: store, replica: replicaLink())
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "package one\n" }
        let bridge = try await page.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.agterm", in: nil,
                                                               contentWorld: HtmlOverlayBridge.world)
        XCTAssertEqual(bridge as? String, "undefined")

        try "package two\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "package two\n" }
        page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true))
        try await waitForVariable("--agterm-foreground", "#102030", in: page.webView)

        try await waitFor("three fetches") { self.fetched.count == 3 }
        XCTAssertEqual(fetched, [url.path, url.path, url.path])
    }

    func testABinaryReplicaReportsAFailure() async throws {
        let url = pages.appendingPathComponent("bin.txt")
        try Data([0x61, 0x00, 0x62]).write(to: url)
        _ = registry.page(for: openReplica(url.path, .text(line: nil)), store: store, replica: replicaLink())

        try await waitFor("failed") { self.current?.loadState == .failed }
        XCTAssertEqual(current?.loadError, TextProbe.Failure.notText(url.path).description)
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

    private func openLog(_ text: String, follow: Bool = true, tail: Int = 500, name: String = "app.log") throws -> (HtmlOverlay, URL) {
        let url = pages.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let overlay = HtmlOverlay(source: .text(path: url.path, line: nil), textLog: TextLog(tail: tail, follow: follow))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return (overlay, url)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func inRenderer(_ script: String, _ view: WKWebView) async throws -> Any? {
        try await view.evaluateJavaScript(script, in: nil, contentWorld: Self.rendererWorld)
    }

    private static let manyLines = (1...200).map { "line \($0)" }.joined(separator: "\n") + "\n"
    private static let bar = "document.querySelector('.agterm-logbar')?.textContent ?? ''"

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

    func testALogPageShowsItsBarNoGutterAndItsEnd() async throws {
        let (overlay, _) = try openLog(Self.manyLines)
        let page = registry.page(for: overlay, store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        let dom = try await page.webView.evaluateJavaScript("""
            [document.querySelector('.agterm-logbar').textContent, document.querySelectorAll('.agterm-gutter').length,
             Math.abs(document.scrollingElement.scrollTop + document.scrollingElement.clientHeight
                      - document.scrollingElement.scrollHeight) < 5].join('|')
            """)
        XCTAssertEqual(dom as? String, "Follow: onlast 200 lines|0|true")
        XCTAssertEqual(current?.logState?.report.lines, 200)
    }

    func testAPlainTextPageGetsNoBar() async throws {
        let page = registry.page(for: try openText("notes.log", "a\n"), store: store)
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "a\n" }

        let bars = try await page.webView.evaluateJavaScript("document.querySelectorAll('.agterm-logbar').length")
        XCTAssertEqual(bars as? Int, 0)
    }

    func testAnAppendReachesTheFollowingPageAndAnUnchangedFilePushesNothing() async throws {
        let (overlay, url) = try openLog("a\n")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("last 1 lines") }
        _ = try await inRenderer("""
            const original = window.agtermTextUpdate;
            window.pushes = 0;
            window.agtermTextUpdate = (...args) => { window.pushes += 1; return original(...args); };
            true;
            """, page.webView)
        try await Task.sleep(for: .milliseconds(2500))
        let idle = try await inRenderer("window.pushes", page.webView)
        XCTAssertEqual(idle as? Int, 0)

        try append("b\n", to: url)

        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "a\nb\n" }
        XCTAssertEqual(current?.logState?.report.lines, 2)
    }

    func testAUserScrollUpPausesAndResumeFollowsAgain() async throws {
        let (overlay, _) = try openLog(Self.manyLines)
        let page = registry.page(for: overlay, store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        _ = try await inRenderer("""
            window.dispatchEvent(new WheelEvent('wheel', { deltaY: -400 }));
            document.scrollingElement.scrollTop = 0;
            true;
            """, page.webView)
        try await waitFor("pause reaches the model") { self.current?.logState?.following == false }
        page.apply(try XCTUnwrap(current))
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }

        _ = try await inRenderer("document.querySelector('.agterm-logbar button').click(); true", page.webView)
        try await waitFor("resume reaches the model") { self.current?.logState?.following == true }
    }

    func testAProgrammaticScrollNeverPauses() async throws {
        let (overlay, _) = try openLog(Self.manyLines)
        let page = registry.page(for: overlay, store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        _ = try await inRenderer("document.scrollingElement.scrollTop = 0", page.webView)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(current?.logState?.following, true)
    }

    func testAFollowChangeFromTheModelRedrawsTheBar() async throws {
        let (overlay, _) = try openLog("a\n")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        XCTAssertEqual(store.setTextLogFollowing(session.id, pane: nil, mode: .off), .success(false))
        page.apply(try XCTUnwrap(current))
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }

        XCTAssertEqual(store.setTextLogFollowing(session.id, pane: nil, mode: .on), .success(true))
        page.apply(try XCTUnwrap(current))
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
    }

    func testAFollowChangeBeforeThePageExistsIsWhatItOpensWith() async throws {
        let (overlay, _) = try openLog("a\n")
        XCTAssertEqual(store.setTextLogFollowing(session.id, pane: nil, mode: .off), .success(false))

        let page = registry.page(for: try XCTUnwrap(current), store: store)

        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }
        XCTAssertEqual(overlay.id, current?.id)
    }

    func testAThemeChangeKeepsThePausedTextAndItsScrollPosition() async throws {
        let (overlay, url) = try openLog(Self.manyLines)
        let page = registry.page(for: overlay, store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        _ = try await inRenderer("""
            window.dispatchEvent(new WheelEvent('wheel', { deltaY: -400 }));
            document.scrollingElement.scrollTop = 600;
            true;
            """, page.webView)
        try await waitFor("pause reaches the model") { self.current?.logState?.following == false }
        page.apply(try XCTUnwrap(current))
        try await Task.sleep(for: .milliseconds(400))
        try append("added\n", to: url)

        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))

        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }
        let dom = try await page.webView.evaluateJavaScript("""
            [document.querySelector('pre code').textContent.includes('added'), Math.round(document.scrollingElement.scrollTop)].join('|')
            """)
        XCTAssertEqual(dom as? String, "false|600")
    }

    func testAnExplicitReloadReadsTheFileAgainAndKeepsFollowingOff() async throws {
        let (overlay, url) = try openLog("a\n", follow: false, tail: 10)
        let page = registry.page(for: overlay, store: store)
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "a\n" }
        try append("b\n", to: url)

        XCTAssertNil(store.reloadHtmlOverlay(session.id, pane: nil))
        page.apply(try XCTUnwrap(current))

        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "a\nb\n" }
        XCTAssertEqual(current?.logState?.following, false)
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }
    }

    func testARebuiltFollowingPageCatchesUpWithAnAppendDuringTheRebuild() async throws {
        let (overlay, url) = try openLog("a\n")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))
        try append("during rebuild\n", to: url)

        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) {
            $0 == "a\nduring rebuild\n"
        }
        XCTAssertEqual(current?.logState?.report.lines, 2)
    }

    func testAGrowingHighlightedFileTurnsPlainPastTheHighlightCap() async throws {
        let (overlay, url) = try openLog("{\"a\": 1}\n", tail: TextPage.maxTail, name: "events.json")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript("document.querySelectorAll('pre code span').length", in: page.webView) { $0 != "0" }

        let row = "{\"key\": \"" + String(repeating: "v", count: 90) + "\"}\n"
        try append(String(repeating: row, count: TextPage.maxHighlightBytes / row.utf8.count + 10) + "{\"last\": 2}\n", to: url)

        try await waitForScript("document.querySelector('pre code')?.textContent.endsWith('{\"last\": 2}\\n')", in: page.webView) {
            $0 == "true"
        }
        let spans = try await page.webView.evaluateJavaScript("document.querySelectorAll('pre code span').length")
        XCTAssertEqual(spans as? Int, 0)
    }

    func testAHeldScrollbarDragPastTheIntentWindowStillResumes() async throws {
        let (overlay, _) = try openLog(Self.manyLines, follow: false)
        let page = registry.page(for: overlay, store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }
        _ = try await inRenderer("document.scrollingElement.scrollTop = 0; true", page.webView)

        _ = try await inRenderer("window.dispatchEvent(new PointerEvent('pointerdown')); true", page.webView)
        try await Task.sleep(for: .milliseconds(900))
        _ = try await inRenderer("document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight; true", page.webView)

        try await waitFor("the drag to the bottom resumes following") { self.current?.logState?.following == true }
    }

    // regression: a first read that failed after the open was accepted left a failed page the restored file never repaired
    func testALogGoneBeforeThePageIsBuiltWaitsAndRecoversWhenItReturns() async throws {
        let (overlay, url) = try openLog("a\n")
        try FileManager.default.removeItem(at: url)

        let page = registry.page(for: overlay, store: store)
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("waiting for file") }
        try "back\n".write(to: url, atomically: true, encoding: .utf8)

        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "back\n" }
        try await waitForScript(Self.bar, in: page.webView) { !$0.contains("waiting for file") }
        XCTAssertEqual(current?.loadState, .loaded)
        XCTAssertEqual(current?.logState?.report, TextLogReport(lines: 1))
    }

    func testTheScrollHandlerIgnoresAnythingButItsReport() async throws {
        let (overlay, _) = try openLog("a\n")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        _ = try await inRenderer("""
            window.webkit.messageHandlers.agtermLogScroll.postMessage({ following: 'no' });
            window.webkit.messageHandlers.agtermLogScroll.postMessage(['following', false]);
            window.webkit.messageHandlers.agtermLogScroll.postMessage('pause');
            true;
            """, page.webView)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(current?.logState?.following, true)
        let inPage = try await page.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.agtermLogScroll")
        XCTAssertEqual(inPage as? String, "undefined")
    }
}
