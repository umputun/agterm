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
        XCTAssertEqual(dom as? String, "Follow: on|0|true")
        XCTAssertEqual(current?.logState?.report.lines, 200)
    }

    func testAPlainTextPageGetsSearchButNoFollowControls() async throws {
        let page = registry.page(for: try openText("notes.log", "a\n"), store: store)
        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "a\n" }

        let bars = try await page.webView.evaluateJavaScript("""
            [document.querySelectorAll('.agterm-logbar').length, document.querySelectorAll('.agterm-bar .agterm-search input').length].join('|')
            """)
        XCTAssertEqual(bars as? String, "0|1")
    }

    func testAnAppendReachesTheFollowingPageAndAnUnchangedFilePushesNothing() async throws {
        let (overlay, url) = try openLog("a\n")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript(Self.code, in: page.webView) { $0 == "a\n" }
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

    // regression: a horizontal scroll at the bottom of a paused page resumed following
    func testAHorizontalScrollOnAPausedPageAtTheBottomKeepsItPaused() async throws {
        let wide = (1...200).map { "line \($0) " + String(repeating: "w", count: 400) }.joined(separator: "\n") + "\n"
        let (overlay, url) = try openLog(wide)
        let page = registry.page(for: overlay, store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        try append("pinned\n", to: url)
        try await waitForScript("document.querySelector('pre code')?.textContent.endsWith('pinned\\n')", in: page.webView) { $0 == "true" }
        XCTAssertEqual(store.setTextLogFollowing(session.id, pane: nil, mode: .off), .success(false))
        page.apply(try XCTUnwrap(current))
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }

        _ = try await inRenderer("""
            window.dispatchEvent(new WheelEvent('wheel', { deltaX: 200 }));
            document.scrollingElement.scrollLeft = 300;
            true;
            """, page.webView)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(current?.logState?.following, false)
    }

    func testTheBarSpansTheVisibleWidthWhenThePageScrollsSideways() async throws {
        let wide = (1...50).map { "line \($0) " + String(repeating: "w", count: 400) }.joined(separator: "\n") + "\n"
        let (overlay, _) = try openLog(wide)
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        let span = try await page.webView.evaluateJavaScript("""
            (() => {
              document.scrollingElement.scrollLeft = 300;
              const bar = document.querySelector('.agterm-bar').getBoundingClientRect();
              return [document.scrollingElement.scrollLeft, Math.round(bar.left), Math.round(bar.right),
                      document.documentElement.clientWidth, document.querySelector('.agterm-bar').offsetHeight,
                      Math.round(document.querySelector('#agterm-page').getBoundingClientRect().top + document.scrollingElement.scrollTop)].join('|');
            })()
            """) as? String
        let parts = try XCTUnwrap(span).split(separator: "|").map { Int($0) ?? -1 }

        XCTAssertEqual(parts[0], 300, span ?? "")
        XCTAssertEqual([parts[1], parts[2]], [0, parts[3]], span ?? "")
        XCTAssertEqual(parts[5], parts[4], span ?? "")
    }

    func testTheScrollHandlerIgnoresAnythingButItsReport() async throws {
        let (overlay, _) = try openLog("a\n")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        _ = try await inRenderer("""
            window.webkit.messageHandlers.agtermTextPage.postMessage({ following: 'no' });
            window.webkit.messageHandlers.agtermTextPage.postMessage(['following', false]);
            window.webkit.messageHandlers.agtermTextPage.postMessage('pause');
            true;
            """, page.webView)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(current?.logState?.following, true)
        let inPage = try await page.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.agtermTextPage")
        XCTAssertEqual(inPage as? String, "undefined")
    }
}

@MainActor
extension TextPageRenderingTests {
    private static let count = "document.querySelector('.agterm-count')?.textContent ?? ''"
    private static let code = "document.querySelector('pre code')?.textContent ?? ''"
    private static let atBottom = """
        Math.abs(document.scrollingElement.scrollTop + document.scrollingElement.clientHeight
                 - document.scrollingElement.scrollHeight) < 5
        """

    private func search(_ query: String, on page: HtmlOverlayPage) throws {
        store.setTextSearch(page.id, query: query)
        page.apply(try XCTUnwrap(current))
    }

    private func step(_ forward: Bool, on page: HtmlOverlayPage) async throws -> String {
        let model = try XCTUnwrap(current)
        let bridge = try XCTUnwrap(page.textPage)
        let found = try await bridge.step(forward: forward, query: model.textSearch?.query ?? "", revision: model.searchRevision).get()
        return "\(found.current) of \(found.matches)"
    }

    private func press(_ key: String, _ view: WKWebView) async throws {
        _ = try await inRenderer("window.dispatchEvent(new KeyboardEvent('keydown', { key: \(try json(key)) })); true", view)
    }

    private func shown(_ overlay: HtmlOverlay) throws -> (HtmlOverlayPage, NSWindow) {
        let page = registry.page(for: overlay, store: store)
        return (page, try host(page.webView))
    }

    private func resume(_ page: HtmlOverlayPage) throws {
        XCTAssertEqual(store.setTextLogFollowing(session.id, pane: nil, mode: .on), .success(true))
        page.apply(try XCTUnwrap(current))
    }

    func testAQueryAcrossHighlightSpansMatchesAndReachesTheModel() async throws {
        let (page, window) = try shown(try openText("main.go", "package main\n\nfunc main() {}\n\nvar x = main()\n"))
        defer { window.orderOut(nil) }
        try await waitForScript("document.querySelectorAll('pre code span').length", in: page.webView) { $0 != "0" }

        try search("main()", on: page)

        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 2" }
        try await waitFor("the report") { self.current?.textSearch == TextSearch(query: "main()", matches: 2, current: 1) }
        let painted = try await inRenderer("[CSS.highlights.get('agterm-match').size, CSS.highlights.get('agterm-current').size].join('|')",
                                           page.webView)
        XCTAssertEqual(painted as? String, "2|1")
    }

    func testMatchesDoNotOverlapAndStepsWrapBothWays() async throws {
        let (page, window) = try shown(try openText("a.txt", "aaaaa\n"))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.code, in: page.webView) { $0 == "aaaaa\n" }
        try search("aa", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 2" }

        let forward = try await step(true, on: page)
        let wrapped = try await step(true, on: page)
        let back = try await step(false, on: page)

        XCTAssertEqual([forward, wrapped, back], ["2 of 2", "1 of 2", "2 of 2"])
    }

    func testAHostileQueryStaysTextAndClearingKeepsTheHighlightMarkup() async throws {
        let (page, window) = try shown(try openText("hostile.js", Self.hostile))
        defer { window.orderOut(nil) }
        try await waitForScript("document.querySelectorAll('pre code span').length", in: page.webView) { $0 != "0" }
        let spans = try await page.webView.evaluateJavaScript("document.querySelectorAll('pre code span').length") as? Int
        let query = #"<img src=x onerror="document.title = 'ran'">"#

        try search(query, on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 1" }
        let dom = try await page.webView.evaluateJavaScript("""
            [document.querySelector('.agterm-search input').value === \(try json(query)),
             document.querySelectorAll('img, script').length, document.title].join('|')
            """)
        XCTAssertEqual(dom as? String, "true|0|")

        try search("", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "" }
        let cleared = try await inRenderer("""
            [document.querySelectorAll('pre code span').length, CSS.highlights.get('agterm-match').size].join('|')
            """, page.webView)
        XCTAssertEqual(cleared as? String, "\(spans ?? -1)|0")
    }

    func testNavigationReachesMatchesPastThePaintedWindow() async throws {
        let (page, window) = try shown(try openText("many.txt", String(repeating: "hit\n", count: 6000)))
        defer { window.orderOut(nil) }
        try await waitForScript("document.querySelector('pre code')?.textContent.length ?? 0", in: page.webView) { $0 == "24000" }
        try search("hit", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 6000" }

        let last = try await step(false, on: page)

        XCTAssertEqual(last, "6000 of 6000")
        let painted = try await inRenderer("""
            const now = [...CSS.highlights.get('agterm-current')][0];
            [CSS.highlights.get('agterm-match').size,
             [...CSS.highlights.get('agterm-match')].some(r => r.startContainer === now.startContainer && r.startOffset === now.startOffset)
            ].join('|');
            """, page.webView)
        XCTAssertEqual(painted as? String, "5000|true")
    }

    func testAJumpToTheLastLinePausesAndItsOwnScrollNeverResumes() async throws {
        let (overlay, _) = try openLog("match first\n" + Self.manyLines + "match last\n")
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        try search("match", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "2 of 2" }

        let first = try await step(false, on: page)
        try await waitFor("the jump pauses the model") { self.current?.logState?.following == false }
        let last = try await step(true, on: page)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual([first, last], ["1 of 2", "2 of 2"])
        XCTAssertEqual(current?.logState?.following, false)
        let bottom = try await page.webView.evaluateJavaScript(Self.atBottom)
        XCTAssertEqual(bottom as? Bool, true)
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }
    }

    func testTypingWhileFollowingKeepsTheFieldAndFollowThroughAnAppend() async throws {
        let (overlay, url) = try openLog("one err\n")
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        _ = try await inRenderer("""
            const field = document.querySelector('.agterm-search input');
            field.focus(); field.value = 'err'; field.dispatchEvent(new Event('input')); true;
            """, page.webView)
        try await waitFor("the typed query reaches the model") { self.current?.textSearch?.query == "err" }
        page.apply(try XCTUnwrap(current))
        try append("two err\n", to: url)
        try await waitForScript(Self.code, in: page.webView) { $0 == "one err\ntwo err\n" }

        let dom = try await page.webView.evaluateJavaScript("""
            [document.activeElement === document.querySelector('.agterm-search input'),
             document.querySelector('.agterm-search input').value, \(Self.count)].join('|')
            """)
        XCTAssertEqual(dom as? String, "true|err|1 of 2")
        XCTAssertEqual(current?.logState?.following, true)
        try await waitFor("the typed query's report") { self.current?.textSearch == TextSearch(query: "err", matches: 2, current: 1) }
    }

    func testAnEvictingAppendKeepsTheCurrentMatchOnItsLine() async throws {
        let (overlay, url) = try openLog("a x\nb x\nc x\nd x\ne x\n", tail: 5)
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        try search("x", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "5 of 5" }
        let onD = try await step(false, on: page)
        XCTAssertEqual(onD, "4 of 5")
        try resume(page)

        try append("f x\ng x\n", to: url)

        try await waitForScript(Self.code, in: page.webView) { $0 == "c x\nd x\ne x\nf x\ng x\n" }
        try await waitForScript(Self.count, in: page.webView) { $0 == "2 of 5" }
    }

    func testRepeatedLinesKeepTheOccurrenceOnTheLine() async throws {
        let (overlay, url) = try openLog(String(repeating: "x x\n", count: 5), tail: 5)
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        try search("x", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "10 of 10" }
        _ = try await inRenderer("""
            const original = window.agtermTextUpdate;
            window.agtermTextUpdate = (...args) => { document.documentElement.dataset.pushed = 'yes'; return original(...args); };
            true;
            """, page.webView)

        try append("x x\n", to: url)

        try await waitForScript("document.documentElement.dataset.pushed ?? ''", in: page.webView) { $0 == "yes" }
        let count = try await page.webView.evaluateJavaScript(Self.count)
        XCTAssertEqual(count as? String, "8 of 10")
    }

    func testAnEvictedLineOrAReplacedFileResetsTheCurrentMatch() async throws {
        let (overlay, url) = try openLog("a x\nb x\nc x\nd x\ne x\n", tail: 5)
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        try search("x", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "5 of 5" }
        for _ in 0..<4 { _ = try await step(false, on: page) }
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 5" }
        try resume(page)

        try append("f x\n", to: url)
        try await waitForScript(Self.code, in: page.webView) { $0.hasPrefix("b x\n") }
        try await waitForScript(Self.count, in: page.webView) { $0 == "5 of 5" }

        _ = try await step(false, on: page)
        try resume(page)
        try FileManager.default.moveItem(at: url, to: pages.appendingPathComponent("app.log.1"))
        try "p x\nq x\nr x\ns x\nt x\n".write(to: url, atomically: true, encoding: .utf8)
        try await waitForScript(Self.code, in: page.webView) { $0.hasPrefix("p x\n") }
        try await waitForScript(Self.count, in: page.webView) { $0 == "5 of 5" }
    }

    func testACutFirstLineDropsAMatchAnchoredOnIt() async throws {
        let (overlay, _) = try openLog("x x\nb x\n")
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        try search("x", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "3 of 3" }
        let second = try await step(false, on: page)
        XCTAssertEqual(second, "2 of 3")

        _ = try await inRenderer("""
            agtermTextUpdate('x x\\nb x\\n', true, false, false, null, { dropped: 0, cut: false, replaced: false }); true;
            """, page.webView)
        let kept = try await page.webView.evaluateJavaScript(Self.count)
        _ = try await inRenderer("""
            agtermTextUpdate('x x\\nb x\\n', true, false, false, null, { dropped: 0, cut: true, replaced: false }); true;
            """, page.webView)
        let reset = try await page.webView.evaluateJavaScript(Self.count)

        XCTAssertEqual([kept as? String, reset as? String], ["2 of 3", "1 of 3"])
    }

    func testARebuildKeepsTheQueryAndCurrentMatchWithoutMoving() async throws {
        let (page, window) = try shown(try openText("notes.txt", "x\nx\nx\n"))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.code, in: page.webView) { $0 == "x\nx\nx\n" }
        try search("x", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 3" }
        _ = try await step(true, on: page)
        try await waitFor("the report") { self.current?.textSearch?.current == 2 }
        page.apply(try XCTUnwrap(current))

        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))

        try await waitForVariable("--agterm-foreground", "#e0e0e0", in: page.webView)
        try await waitForScript(Self.count, in: page.webView) { $0 == "2 of 3" }
        let field = try await page.webView.evaluateJavaScript("document.querySelector('.agterm-search input').value")
        XCTAssertEqual(field as? String, "x")
    }

    func testAStepBeforeThePageIsReadyIsRefusedAndRunsNothing() async throws {
        let overlay = try openText("notes.txt", "x\n")
        store.setTextSearch(overlay.id, query: "x")
        let page = registry.page(for: try XCTUnwrap(current), store: store)

        let early = await page.textPage?.step(forward: true, query: "x", revision: 1)

        guard case .failure(.notLoaded) = early else { return XCTFail("expected page not loaded, got \(String(describing: early))") }
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 1" }
    }

    func testAStepRightAfterAQueryChangeStepsThroughTheNewQuery() async throws {
        let (page, window) = try shown(try openText("notes.txt", "a b\nb\nb\n"))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.code, in: page.webView) { $0 == "a b\nb\nb\n" }
        try search("a", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 1" }

        store.setTextSearch(page.id, query: "b")
        let stepped = try await step(true, on: page)

        XCTAssertEqual(stepped, "2 of 3")
        let field = try await page.webView.evaluateJavaScript("document.querySelector('.agterm-search input').value")
        XCTAssertEqual(field as? String, "b")
    }

    func testThePageKeysFocusStepAndDriveFollowing() async throws {
        let (overlay, _) = try openLog("x first\n" + Self.manyLines + "x last\n")
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        try search("x", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "2 of 2" }

        try await press("/", page.webView)
        let focused = try await page.webView.evaluateJavaScript("document.activeElement === document.querySelector('.agterm-search input')")
        XCTAssertEqual(focused as? Bool, true)
        _ = try await page.webView.evaluateJavaScript("document.activeElement.blur(); true")

        try await press("n", page.webView)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 2" }
        try await waitFor("n pauses") { self.current?.logState?.following == false }
        try await press("N", page.webView)
        try await waitForScript(Self.count, in: page.webView) { $0 == "2 of 2" }

        try await press("G", page.webView)
        try await waitFor("G follows") { self.current?.logState?.following == true }
        try await press("g", page.webView)
        try await waitFor("g pauses") { self.current?.logState?.following == false }
        let top = try await page.webView.evaluateJavaScript("document.scrollingElement.scrollTop")
        XCTAssertEqual((top as? NSNumber)?.doubleValue, 0)
        try await press("F", page.webView)
        try await waitFor("F toggles to following") { self.current?.logState?.following == true }
        try await press("Home", page.webView)
        try await waitFor("Home pauses") { self.current?.logState?.following == false }
        try await press("End", page.webView)
        try await waitFor("End follows") { self.current?.logState?.following == true }
    }

    // regression: a control query arriving after coalesced typing was taken for the field's own echo and swallowed
    func testAControlQueryAfterCoalescedTypingReplacesTheTypedOne() async throws {
        let (page, window) = try shown(try openText("notes.txt", "a ab\nab\n"))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.code, in: page.webView) { $0 == "a ab\nab\n" }
        _ = try await inRenderer("""
            const field = document.querySelector('.agterm-search input');
            field.value = 'a'; field.dispatchEvent(new Event('input'));
            field.value = 'ab'; field.dispatchEvent(new Event('input')); true;
            """, page.webView)
        try await waitFor("both typed queries reach the model") { self.current?.searchRevision == 2 }

        store.setTextSearch(page.id, query: "a")
        page.apply(try XCTUnwrap(current))

        try await waitFor("the control query's counts") { self.current?.textSearch?.matches == 3 }
        let field = try await page.webView.evaluateJavaScript("document.querySelector('.agterm-search input').value")
        XCTAssertEqual(field as? String, "a")
        XCTAssertEqual(current?.textSearch?.query, "a")
    }

    // regression: a control query between a keystroke and its echo left the field on one query and the model on another
    func testATypedEchoAfterAControlQueryBringsFieldModelAndCountsTogether() async throws {
        let (page, window) = try shown(try openText("notes.txt", "abc foo\nabc\n"))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.code, in: page.webView) { $0 == "abc foo\nabc\n" }
        store.setTextSearch(page.id, query: "foo")
        let control = try XCTUnwrap(current?.searchRevision)

        _ = try await inRenderer("""
            const field = document.querySelector('.agterm-search input');
            field.value = 'abc'; field.dispatchEvent(new Event('input'));
            agtermTextSearchSet('foo', \(control), false); true;
            """, page.webView)
        try await waitFor("the typed query reaches the model") { self.current?.textSearch?.query == "abc" }
        page.apply(try XCTUnwrap(current))

        try await waitFor("the model's counts for the typed query") { self.current?.textSearch?.matches == 2 }
        let field = try await page.webView.evaluateJavaScript("document.querySelector('.agterm-search input').value")
        XCTAssertEqual(field as? String, "abc")
        try await waitForScript(Self.count, in: page.webView) { $0.hasSuffix("of 2") }
    }

    // regression: CRs kept in pushed text but dropped from the highlighted DOM threw inside the highlight window
    func testAHighlightedCRLFLogKeepsSearchingAndFollowingThroughAnAppend() async throws {
        let (overlay, url) = try openLog("{\"a\": 1}\r\n{\"a\": 2}\r\n", name: "events.json")
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript("document.querySelectorAll('pre code span').length", in: page.webView) { $0 != "0" }
        try search("a", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "2 of 2" }

        try append("{\"a\": 3}\r\n", to: url)

        try await waitForScript(Self.code, in: page.webView) { $0 == "{\"a\": 1}\n{\"a\": 2}\n{\"a\": 3}\n" }
        try await waitForScript(Self.count, in: page.webView) { $0 == "2 of 3" }
        let bottom = try await page.webView.evaluateJavaScript(Self.atBottom)
        XCTAssertEqual(bottom as? Bool, true)
        XCTAssertEqual(current?.logState?.following, true)
    }

    func testAThemeRebuildKeepsAPlainPageWhereItWas() async throws {
        let text = (1...400).map { $0 == 380 ? "needle \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"
        let (page, window) = try shown(try openText("long.txt", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.code, in: page.webView) { $0 == text }
        try search("needle", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 1" }
        let before = try await page.webView.evaluateJavaScript("Math.round(document.scrollingElement.scrollTop)") as? Int
        XCTAssertGreaterThan(before ?? 0, 5000)

        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))

        try await waitForVariable("--agterm-foreground", "#e0e0e0", in: page.webView)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 1" }
        let after = try await page.webView.evaluateJavaScript("Math.round(document.scrollingElement.scrollTop)") as? Int
        XCTAssertEqual(after, before)
    }

    func testTheBarFitsANarrowPageFollowingAndPaused() async throws {
        let (overlay, _) = try openLog(Self.manyLines + "x\n")
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        try search("line", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0.hasSuffix("of 200") }
        let fits = """
            (() => {
              const width = document.documentElement.clientWidth;
              const follow = document.querySelector('.agterm-logbar button').getBoundingClientRect();
              const box = document.querySelector('.agterm-search').getBoundingClientRect();
              const controls = [...document.querySelectorAll('.agterm-search button')].map(e => e.getBoundingClientRect().right);
              return [follow.right <= box.left, box.right <= width, Math.max(...controls) <= width].join('|');
            })()
            """

        let following = try await page.webView.evaluateJavaScript(fits)
        XCTAssertEqual(store.setTextLogFollowing(session.id, pane: nil, mode: .off), .success(false))
        page.apply(try XCTUnwrap(current))
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }
        let paused = try await page.webView.evaluateJavaScript(fits)

        XCTAssertEqual([following as? String, paused as? String], ["true|true|true", "true|true|true"])
    }
}
