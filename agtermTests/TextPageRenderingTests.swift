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

    func testATextReplicaRefetchesOnReloadAndRedrawsAThemeChangeFromWhatItShows() async throws {
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
        try "package three\n".write(to: url, atomically: true, encoding: .utf8)
        page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true))
        try await waitForVariable("--agterm-foreground", "#102030", in: page.webView)

        try await waitForScript("document.querySelector('pre code')?.textContent ?? ''", in: page.webView) { $0 == "package two\n" }
        XCTAssertEqual(fetched, [url.path, url.path])
    }

    @MainActor private final class TailGate {
        var hang = false
        var asked = 0
    }

    private func openReplicaLog(_ path: String) -> HtmlOverlay {
        let overlay = HtmlOverlay(source: .replica(path: path, content: .text(line: nil)), replicaOf: UUID(),
                                  textLog: TextLog(tail: 50, follow: true))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }

    func testAReplicaLogOverTheTextCapOpensFromItsTailAndFollowsTheFile() async throws {
        let url = pages.appendingPathComponent("app.log")
        let line = String(repeating: "x", count: 99) + "\n"
        try String(repeating: line, count: TextPage.maxBytes / line.utf8.count + 1000).write(to: url, atomically: true, encoding: .utf8)
        let page = registry.page(for: openReplicaLog(url.path), store: store, replica: replicaLink(log: url.path))

        try await waitFor("the tail is shown") { self.current?.logState?.report.lines == 50 }
        XCTAssertTrue(fetched.isEmpty)
        try append("last\n", to: url)
        try await waitFor("the append is followed") { page.textPage?.follower?.snapshot?.text.hasSuffix(line + "last\n") == true }
    }

    func testAReplicaLogTheOriginCannotReadWaitsForIt() async throws {
        let url = pages.appendingPathComponent("gone.log")
        let page = registry.page(for: openReplicaLog(url.path), store: store, replica: replicaLink(log: url.path))

        try await waitFor("the page waits") { self.current?.logState?.report.waiting == true }
        try "back\n".write(to: url, atomically: true, encoding: .utf8)
        try await waitFor("the file is picked up") { page.textPage?.follower?.snapshot?.text == "back\n" }
    }

    func testAHideDuringAChannelReadLeavesTheLogAsItWasAndShowingCatchesUp() async throws {
        let url = pages.appendingPathComponent("app.log")
        try "one\n".write(to: url, atomically: true, encoding: .utf8)
        let gate = TailGate(), disk = replicaLink(log: url.path)
        let link = HtmlReplicaLink(fetch: disk.fetch, bridge: disk.bridge, logTail: { stamp in
            gate.asked += 1
            if gate.hang { try await Task.sleep(for: .seconds(60)) }
            return try await disk.logTail(stamp)
        })
        let page = registry.page(for: openReplicaLog(url.path), store: store, replica: link)
        try await waitFor("the log is shown") { page.textPage?.follower?.snapshot?.text == "one\n" }
        gate.hang = true
        let asked = gate.asked
        try await waitFor("a read is in flight") { gate.asked > asked }

        page.setOnScreen(false)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(current?.logState?.report, TextLogReport(lines: 1))
        XCTAssertEqual(page.textPage?.follower?.snapshot?.text, "one\n")
        gate.hang = false
        try append("two\n", to: url)
        page.setOnScreen(true)
        try await waitFor("showing catches up") { page.textPage?.follower?.snapshot?.text == "one\ntwo\n" }
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
        let diff = Self.patch(changes: [0], lines: TextPage.maxBytes / " line 100000\n".utf8.count - 10)
        let high = String(repeating: line, count: TextPage.maxHighlightBytes / line.utf8.count)
        let plain = String(repeating: line, count: TextPage.maxBytes / line.utf8.count)
        let colored = "\u{1B}[36mfunc\u{1B}[39m main() { \u{1B}[1mreturn\u{1B}[22m }\n"
        let coloredCount = TextPage.maxBytes / colored.utf8.count
        let cases = [("high.go", high, high.utf16.count), ("plain.log", plain, plain.utf16.count), ("big.diff", diff, diff.utf16.count),
                     ("colored.log", String(repeating: colored, count: coloredCount), line.utf16.count * coloredCount)]
        for (name, text, length) in cases {
            let clock = ContinuousClock(), started = clock.now
            let page = registry.page(for: try openText(name, text), store: store)
            // leaves room for WebContent startup on a loaded runner while still catching a pathological render
            try await waitForScript("document.querySelector('pre code')?.textContent.length ?? 0", in: page.webView,
                                    timeout: 30) { $0 == "\(length)" }

            XCTAssertLessThan(clock.now - started, .seconds(30), name)
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

    func testAStepCommitsItsCountsAndAMovedLogsPauseBeforeItAnswers() async throws {
        let (overlay, _) = try openLog("one err\ntwo\nthree err\n")
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.code, in: page.webView) { $0.contains("three err") }
        page.webView.configuration.userContentController.removeAllScriptMessageHandlers()

        try search("none", on: page)
        let none = try await step(true, on: page)
        XCTAssertEqual(none, "0 of 0")
        XCTAssertEqual(current?.logState?.following, true)

        try search("err", on: page)
        let reached = try await step(true, on: page)

        XCTAssertEqual(reached.hasSuffix("of 2"), true, reached)
        XCTAssertEqual(current?.textSearch?.matches, 2)
        XCTAssertEqual(current?.logState?.following, false)
    }

    func testADiffPageReportsItsChangesOnlyOnceItIsReady() async throws {
        let posted = try await postedUntil("changes", try openText("a.diff", "@@ -1 +1 @@\n-a\n+b\n"))
        XCTAssertEqual(posted.prefix(2), ["ready", "changes"])
    }

    func testADiffPageWithNoChangesReportsItsCountOnlyOnceItIsReady() async throws {
        let posted = try await postedUntil("changes", try openText("a.diff", "@@ -1 +1 @@\n a\n"))
        XCTAssertEqual(posted.prefix(2), ["ready", "changes"])
    }

    func testASeededSearchReportsItsMatchesOnlyOnceThePageIsReady() async throws {
        let overlay = try openText("a.txt", "a b a\n")
        XCTAssertNotNil(store.setTextSearch(overlay.id, query: "a"))

        let posted = try await postedUntil("report", try XCTUnwrap(current))

        XCTAssertEqual(posted.prefix(2), ["ready", "report"])
    }

    private func postedUntil(_ key: String, _ overlay: HtmlOverlay) async throws -> [String] {
        let page = registry.page(for: overlay, store: store)
        defer { store.closeHtmlOverlay(page.id) }
        page.webView.configuration.userContentController.addUserScript(WKUserScript(source: """
            const handler = window.webkit.messageHandlers.agtermTextPage;
            const post = handler.postMessage.bind(handler);
            handler.postMessage = (body) => {
              const root = document.documentElement;
              root.dataset.posted = (root.dataset.posted || '') + Object.keys(body)[0] + ' ';
              post(body);
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.rendererWorld))
        try await waitForScript("document.documentElement.dataset.posted ?? ''", in: page.webView) { $0.contains(key) }
        let posted = try await page.webView.evaluateJavaScript("document.documentElement.dataset.posted") as? String
        return (posted ?? "").split(separator: " ").map(String.init)
    }

    func testAChangeStepCommitsItsChangeBeforeItAnswers() async throws {
        let (page, window) = try shown(try openText("a.diff", "@@ -1 +1 @@\n-a\n+b\n@@ -5 +5 @@\n-c\n+d\n"))
        defer { window.orderOut(nil) }
        try await waitFor("the diff reports its changes") { self.current?.textChanges?.count == 2 }
        page.webView.configuration.userContentController.removeAllScriptMessageHandlers()
        let bridge = try XCTUnwrap(page.textPage)

        let reached = try await bridge.stepChange(forward: true).get()

        XCTAssertEqual(reached, TextChanges(count: 2, current: 1))
        XCTAssertEqual(current?.textChanges, reached)
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

    // regression: an over-limit query was searched whole while the presenter reported it cut
    func testAnOverLimitQueryIsSearchedReportedAndShownAsTheModelStoresIt() async throws {
        let cut = String(repeating: "a", count: TextSearch.maxQuery)
        let (page, window) = try shown(try openText("long.txt", cut + "\n"))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.code, in: page.webView) { $0 == cut + "\n" }

        store.setTextSearch(page.id, query: cut + "z")
        page.apply(try XCTUnwrap(current))

        try await waitFor("the cut query's counts") { self.current?.textSearch?.matches == 1 }
        XCTAssertEqual(current?.textSearch?.query, cut)
        let field = try await page.webView.evaluateJavaScript("document.querySelector('.agterm-search input').value")
        XCTAssertEqual(field as? String, cut)
        let limit = try await page.webView.evaluateJavaScript("document.querySelector('.agterm-search input').maxLength")
        XCTAssertEqual((limit as? NSNumber)?.intValue, TextSearch.maxQuery)
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

    func testTheBarFitsANarrowPageFollowingPausedAndWithANote() async throws {
        let (overlay, url) = try openLog(Self.manyLines + "x\n")
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
              const wrap = document.querySelector('.agterm-wrap');
              return [wrap.getBoundingClientRect().right <= follow.left, wrap.scrollWidth <= wrap.clientWidth,
                      box.right <= width, Math.max(...controls) <= width].join('|');
            })()
            """

        let following = try await page.webView.evaluateJavaScript(fits)
        XCTAssertEqual(store.setTextLogFollowing(session.id, pane: nil, mode: .off), .success(false))
        page.apply(try XCTUnwrap(current))
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: paused - Resume") }
        let paused = try await page.webView.evaluateJavaScript(fits)
        try resume(page)
        try FileManager.default.removeItem(at: url)
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("waiting for file") }
        XCTAssertEqual(store.setTextLogFollowing(session.id, pane: nil, mode: .off), .success(false))
        page.apply(try XCTUnwrap(current))
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Resume") && $0.contains("waiting for file") }
        let noted = try await page.webView.evaluateJavaScript(fits)

        XCTAssertEqual([following, paused, noted].map { $0 as? String }, Array(repeating: "true|true|true|true", count: 3))
    }
}

@MainActor
extension TextPageRenderingTests {
    private static let changesLabel = "document.querySelector('.agterm-changes span')?.textContent ?? ''"
    private static let bandRows = """
        (() => {
          const band = document.querySelector('.agterm-change');
          if (!band || band.hidden) return '';
          const style = getComputedStyle(document.querySelector('#agterm-page pre'));
          const height = parseFloat(style.lineHeight);
          return [(parseFloat(band.style.top) - parseFloat(style.paddingTop)) / height, parseFloat(band.style.height) / height].join('|');
        })()
        """

    private static func patch(changes: [Int], lines: Int = 200) -> String {
        var rows = ["diff --git a/x b/x", "index 1..2 100644", "--- a/x", "+++ b/x", "@@ -1,\(lines) +1,\(lines) @@"]
        for i in 0..<lines {
            rows += changes.contains(i) ? ["-old \(i)", "+new \(i)"] : [" line \(i)"]
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func stepChange(_ forward: Bool, on page: HtmlOverlayPage) async throws -> String {
        let found = try await XCTUnwrap(page.textPage).stepChange(forward: forward).get()
        return "\(found.current) of \(found.count)"
    }

    func testADiffPageCountsItsChangesAndStepsWrapBothWays() async throws {
        let (page, window) = try shown(try openText("a.diff", Self.patch(changes: [10, 100, 190])))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "3 changes" }
        try await waitFor("the first report") { self.current?.textChanges == TextChanges(count: 3, current: 0) }

        let first = try await stepChange(true, on: page)
        XCTAssertEqual(first, "1 of 3")
        try await waitForScript(Self.bandRows, in: page.webView) { $0 == "15|2" }
        let second = try await stepChange(true, on: page)
        let third = try await stepChange(true, on: page)
        let wrapped = try await stepChange(true, on: page)
        let back = try await stepChange(false, on: page)

        XCTAssertEqual([second, third, wrapped, back], ["2 of 3", "3 of 3", "1 of 3", "3 of 3"])
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 3 of 3" }
        try await waitFor("the step report") { self.current?.textChanges == TextChanges(count: 3, current: 3) }
    }

    func testHunkCountsDecideWhatIsAChange() async throws {
        let text = """
            diff --git a/x b/x
            --- a/x
            +++ b/x
            @@ -1,2 +1,2 @@
            --- x
            +++ y
             k
            diff --git a/y b/y
            --- a/y
            +++ b/y
            @@ -2 +2 @@
            -a
            \\ No newline at end of file
            +b
            \\ No newline at end of file

            """
        let (page, window) = try shown(try openText("two.patch", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "2 changes" }

        _ = try await stepChange(true, on: page)
        try await waitForScript(Self.bandRows, in: page.webView) { $0 == "4|2" }
        _ = try await stepChange(true, on: page)
        try await waitForScript(Self.bandRows, in: page.webView) { $0 == "11|3" }
    }

    func testEachFileOfADiffIsHighlightedInItsOwnLanguageAndKeepsItsText() async throws {
        let text = """
            diff --git a/main.go b/main.go
            --- a/main.go
            +++ b/main.go
            @@ -1,3 +1,3 @@
             /* opened
            -old comment line
            +<script>document.title = 'ran'</script>
             */ func main() {}
            diff --git a/q.sql b/q.sql
            --- a/q.sql
            +++ b/q.sql
            @@ -1,2 +1,2 @@
            --- dropped
            +select 1;
             from t

            """
        let (page, window) = try shown(try openText("two.diff", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "2 changes" }

        let dom = try await page.webView.evaluateJavaScript("""
            (() => {
              const code = document.querySelector('pre code');
              const rows = code.innerHTML.split('\\n');
              const has = (row, cls) => rows[row].includes(`class="${cls}"`);
              const style = getComputedStyle(code.parentElement);
              const height = code.parentElement.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
              return [code.textContent === \(try json(text)), height / parseFloat(style.lineHeight),
                [...new Set([...code.querySelectorAll('*')].map(e => e.tagName))].join(','),
                has(6, 'hljs-comment'), has(7, 'hljs-keyword'), has(13, 'hljs-keyword'), has(12, 'hljs-comment'),
                has(1, 'hljs-meta'), [4, 5, 6, 7].every(row => has(row, 'agterm-marker')),
                getComputedStyle(code.querySelector('.agterm-marker')).fontSize, document.title].join('|');
            })()
            """)
        XCTAssertEqual(dom as? String, "true|15|SPAN|true|true|true|true|true|true|0px|")
    }

    func testEachHunkIsHighlightedOnItsOwn() async throws {
        let text = """
            --- a/x.go
            +++ b/x.go
            @@ -1 +1 @@
            -var a
            +/* opened, closed in lines the patch leaves out
            @@ -40 +40 @@
            -var b
            +func c() {}

            """
        let (page, window) = try shown(try openText("hunks.diff", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "2 changes" }

        let keyword = try await page.webView.evaluateJavaScript("""
            document.querySelector('pre code').innerHTML.split('\\n')[7].includes('class="hljs-keyword"')
            """)
        XCTAssertEqual(keyword as? Bool, true)
    }

    func testADiffWithNoUnifiedHunkKeepsTheDiffGrammar() async throws {
        let text = "*** a.c\n--- b.c\n***************\n*** 1,2 ****\n- old\n  same\n--- 1,2 ----\n+ new\n  same\n"
        let (page, window) = try shown(try openText("context.diff", text))
        defer { window.orderOut(nil) }
        try await waitForScript("document.querySelectorAll('pre code .hljs-deletion').length", in: page.webView) { $0 != "0" }

        let dom = try await page.webView.evaluateJavaScript("""
            [document.querySelector('pre code').textContent === \(try json(text)),
             document.querySelectorAll('pre code .hljs-addition').length > 0,
             document.querySelectorAll('pre code .agterm-marker').length].join('|')
            """)
        XCTAssertEqual(dom as? String, "true|true|0")
    }

    func testACRLFDiffIsHighlightedInItsFileLanguage() async throws {
        let text = ["diff --git a/x.go b/x.go", "--- a/x.go", "+++ b/x.go", "@@ -1 +1 @@", "-var a", "+func b() {}", ""]
            .joined(separator: "\r\n")
        let (page, window) = try shown(try openText("crlf.diff", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "1 change" }

        let keywords = try await page.webView.evaluateJavaScript("document.querySelectorAll('pre code .hljs-keyword').length")
        XCTAssertEqual(keywords as? Int, 2)
    }

    func testColorEscapesBecomeStyledTextAndSearchReadsTheShownText() async throws {
        let text = "\u{1B}[36mbugs+impl\u{1B}[39m started\n\u{1B}[1;38;5;196mfail\u{1B}[22m red\u{1B}[0m \u{1B}(B\u{1B}[2Kplain\n"
            + "\u{1B}[1;38:2::0:128:0mgreen\u{1B}[0m\n"
            + "\u{1B}[32mok\u{1B}[>4;1m still\u{1B}[0m \u{1B}_Gf=1;AA\u{1B}\\x\u{1B}Ptmux;\u{1B}\u{1B}[31mhidden\u{1B}\\y"
            + "\u{1B}Ptmux;\u{1B}\u{1B}]8;;http://x\u{1B}\u{1B}\\label\u{1B}\u{1B}]8;;\u{1B}\u{1B}\\\u{1B}\\\nend\u{1B}P1+r6b"
        let (page, window) = try shown(try openText("agents.log", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.code, in: page.webView) { $0 == "bugs+impl started\nfail red plain\ngreen\nok still xy\nend" }

        let spans = try await page.webView.evaluateJavaScript("""
            [...document.querySelectorAll('pre code span')].map(s => `${s.textContent}:${s.style.color}:${s.style.fontWeight}`).join(',')
            """)
        XCTAssertEqual(spans as? String,
                       "bugs+impl:var(--agterm-color-6, #00cdcd):,fail:rgb(255, 0, 0):bold, red:rgb(255, 0, 0):,green:rgb(0, 128, 0):bold,"
                       + "ok:var(--agterm-color-2, #00cd00):, still:var(--agterm-color-2, #00cd00):")
        try search("impl started", on: page)
        try await waitForScript(Self.count, in: page.webView) { $0 == "1 of 1" }
    }

    func testAColoredDiffShowsItsRowsAndFileLanguageWithoutTheEscapes() async throws {
        let plain = ["diff --git a/x.go b/x.go", "--- a/x.go", "+++ b/x.go", "@@ -1 +1 @@", "-var a", "+func b() {}", ""]
        let colored = ["\u{1B}[1mdiff --git a/x.go b/x.go\u{1B}[m", "\u{1B}[1m--- a/x.go\u{1B}[m", "\u{1B}[1m+++ b/x.go\u{1B}[m",
                       "\u{1B}[36m@@ -1 +1 @@\u{1B}[m", "\u{1B}[31m-var a\u{1B}[m", "\u{1B}[32m+func b() {}\u{1B}[m", ""]
        let (page, window) = try shown(try openText("colored.diff", colored.joined(separator: "\n")))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "1 change" }

        let dom = try await page.webView.evaluateJavaScript("""
            [document.querySelector('pre code').textContent === \(try json(plain.joined(separator: "\n"))),
             document.querySelectorAll('pre code .hljs-keyword').length,
             document.querySelectorAll('.agterm-added, .agterm-removed').length].join('|')
            """)
        XCTAssertEqual(dom as? String, "true|2|2")
    }

    func testAFollowedLogEndingMidEscapeShowsNoFragmentUntilItCompletes() async throws {
        let (overlay, url) = try openLog("a\n")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript(Self.code, in: page.webView) { $0 == "a\n" }

        try append("x\u{1B}[3", to: url)
        try await waitForScript(Self.code, in: page.webView) { $0 == "a\nx" }
        try append("1mb\n", to: url)
        try await waitForScript(Self.code, in: page.webView) { $0 == "a\nxb\n" }

        let color = try await page.webView.evaluateJavaScript("document.querySelector('pre code span')?.style.color ?? ''")
        XCTAssertEqual(color as? String, "var(--agterm-color-1, #cd0000)")
    }

    func testAddedAndRemovedRunsGetBandsAlsoPastTheHighlightCap() async throws {
        let bands = """
            [...document.querySelectorAll('.agterm-added, .agterm-removed')].map(b => {
              const style = getComputedStyle(document.querySelector('#agterm-page pre'));
              const height = parseFloat(style.lineHeight);
              return [b.className, (parseFloat(b.style.top) - parseFloat(style.paddingTop)) / height,
                parseFloat(b.style.height) / height].join(':');
            }).join(' ')
            """
        let small = try shown(try openText("a.diff", Self.patch(changes: [1, 2], lines: 5)))
        try await waitForScript(Self.changesLabel, in: small.0.webView) { $0 == "1 change" }
        try await waitForScript(bands, in: small.0.webView) {
            $0 == "agterm-removed:6:1 agterm-added:7:1 agterm-removed:8:1 agterm-added:9:1"
        }
        small.1.orderOut(nil)
        store.closeHtmlOverlay(small.0.id)

        let large = try shown(try openText("b.diff", Self.patch(changes: [0], lines: 30_000)))
        defer { large.1.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: large.0.webView) { $0 == "1 change" }
        try await waitForScript(bands, in: large.0.webView) { $0 == "agterm-removed:5:1 agterm-added:6:1" }
        let classes = try await large.0.webView.evaluateJavaScript("""
            [...new Set([...document.querySelectorAll('pre code span')].map(e => e.className))].sort().join(',')
            """)
        XCTAssertEqual(classes as? String, "agterm-marker,hljs-meta")
    }

    func testAfterAManualScrollNextStartsBelowTheView() async throws {
        let (page, window) = try shown(try openText("a.diff", Self.patch(changes: [10, 100, 190])))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "3 changes" }
        _ = try await stepChange(true, on: page)

        _ = try await page.webView.evaluateJavaScript("document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight; true")
        let next = try await stepChange(true, on: page)

        XCTAssertEqual(next, "3 of 3")
    }

    func testTheBracketKeysStepButNotWhileTypingInFind() async throws {
        let (page, window) = try shown(try openText("a.diff", Self.patch(changes: [10, 100, 190])))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "3 changes" }

        try await press("]", page.webView)
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 1 of 3" }
        try await press("[", page.webView)
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 3 of 3" }

        _ = try await inRenderer("""
            const field = document.querySelector('.agterm-search input');
            field.focus();
            field.dispatchEvent(new KeyboardEvent('keydown', { key: ']', bubbles: true }));
            true
            """, page.webView)
        let label = try await page.webView.evaluateJavaScript(Self.changesLabel)
        XCTAssertEqual(label as? String, "change 3 of 3")
    }

    func testAThemeRebuildKeepsTheChangeAndAReloadReadsTheChangesAgain() async throws {
        let (page, window) = try shown(try openText("a.diff", Self.patch(changes: [10, 100, 190])))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "3 changes" }
        _ = try await stepChange(true, on: page)
        _ = try await stepChange(true, on: page)
        try await waitFor("the step report") { self.current?.textChanges?.current == 2 }

        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))
        try await waitForVariable("--agterm-foreground", "#e0e0e0", in: page.webView)
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 2 of 3" }
        try await waitForScript(Self.bandRows, in: page.webView) { $0 == "106|2" }

        try "no changes here\n".write(to: pages.appendingPathComponent("a.diff"), atomically: true, encoding: .utf8)
        XCTAssertNil(registry.reload(page.id, target: .current, store: store))
        try await waitForScript(Self.code, in: page.webView) { $0 == "no changes here\n" }
        try await waitFor("the empty report") { self.current?.textChanges == TextChanges(count: 0, current: 0) }
        let controls = try await page.webView.evaluateJavaScript("document.querySelectorAll('.agterm-changes').length")
        XCTAssertEqual(controls as? Int, 0)
    }

    func testAReloadOfAPatchThatStillHasChangesStartsBeforeTheFirst() async throws {
        let (page, window) = try shown(try openText("a.diff", Self.patch(changes: [10, 100, 190])))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "3 changes" }
        _ = try await stepChange(true, on: page)
        _ = try await stepChange(true, on: page)
        try await waitFor("the step report") { self.current?.textChanges?.current == 2 }

        try Self.patch(changes: [20, 60, 120, 170]).write(to: pages.appendingPathComponent("a.diff"), atomically: true, encoding: .utf8)
        XCTAssertNil(registry.reload(page.id, target: .current, store: store))

        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "4 changes" }
        let band = try await page.webView.evaluateJavaScript(Self.bandRows)
        XCTAssertEqual(band as? String, "")
        try await waitFor("the fresh report") { self.current?.textChanges == TextChanges(count: 4, current: 0) }
    }

    func testAPatchPastTheHighlightCapStillSteps() async throws {
        let text = Self.patch(changes: [5, 25000], lines: 30000)
        XCTAssertGreaterThan(text.utf8.count, TextPage.maxHighlightBytes)
        let (page, window) = try shown(try openText("big.diff", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "2 changes" }

        let classes = try await page.webView.evaluateJavaScript("""
            [...new Set([...document.querySelectorAll('pre code span')].map(e => e.className))].sort().join(',')
            """)
        let stepped = try await stepChange(false, on: page)

        XCTAssertEqual(classes as? String, "agterm-marker,hljs-meta")
        XCTAssertEqual(stepped, "2 of 2")
    }

    func testAPlainTextPageHasNoChangesAndAnEarlyStepIsRefused() async throws {
        let page = registry.page(for: try openText("notes.txt", "@@ -1 +1 @@\n-a\n+b\n"), store: store)

        let early = await page.textPage?.stepChange(forward: true)

        guard case .failure(.notLoaded) = early else { return XCTFail("expected page not loaded, got \(String(describing: early))") }
        try await waitForScript(Self.code, in: page.webView) { $0 == "@@ -1 +1 @@\n-a\n+b\n" }
        let controls = try await page.webView.evaluateJavaScript("document.querySelectorAll('.agterm-changes').length")
        XCTAssertEqual(controls as? Int, 0)
        XCTAssertNil(current?.textChanges)
    }
}

@MainActor
extension TextPageRenderingTests {
    private static let wrapButton = "document.querySelector('.agterm-wrap')?.textContent ?? ''"
    private static let longLine = String(repeating: "wrap me ", count: 60)

    private static let gutterRows = """
        (() => {
          const pre = document.querySelector('#agterm-page pre');
          const code = pre.querySelector('code');
          const style = getComputedStyle(pre);
          const height = parseFloat(style.lineHeight);
          const origin = pre.getBoundingClientRect().top + parseFloat(style.paddingTop);
          const rowOf = (rect) => Math.floor((rect.top + rect.height / 2 - origin) / height);
          const node = code.firstChild;
          const range = document.createRange();
          const at = node.data.indexOf('after');
          range.setStart(node, at);
          range.setEnd(node, at + 1);
          const fragments = code.getClientRects();
          const gutter = document.querySelector('.agterm-gutter').textContent.split('\\n');
          return [gutter.indexOf('3'), rowOf(range.getBoundingClientRect()), gutter.length,
                  rowOf(fragments[fragments.length - 1]) + 1,
                  document.scrollingElement.scrollWidth > document.scrollingElement.clientWidth].join('|');
        })()
        """

    func testTheWrapKeyWrapsLongLinesAndTheGutterNumbersTheirFirstRows() async throws {
        let (page, window) = try shown(try openText("a.txt", "short\n\(Self.longLine)\nafter\n"))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: off" }
        let unwrapped = try await page.webView.evaluateJavaScript(Self.gutterRows) as? String
        XCTAssertEqual(unwrapped, "2|2|3|3|true")

        try await press("w", page.webView)

        try await waitFor("the toggle reaches the model") { self.current?.textWrap == true }
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: on" }
        let measured = try await page.webView.evaluateJavaScript(Self.gutterRows) as? String
        let parts = try XCTUnwrap(measured).split(separator: "|")
        XCTAssertEqual(parts[0], parts[1])
        XCTAssertEqual(parts[2], parts[3])
        XCTAssertGreaterThan(Int(parts[1]) ?? 0, 2)
        XCTAssertEqual(parts[4], "false")

        _ = try await inRenderer("document.querySelector('.agterm-wrap').click(); true", page.webView)
        try await waitFor("the click reaches the model") { self.current?.textWrap == false }
        try await waitForScript(Self.gutterRows, in: page.webView) { $0 == "2|2|3|3|true" }
    }

    func testAWrapFromTheModelRedrawsThePageAndARebuildKeepsIt() async throws {
        let (page, window) = try shown(try openText("a.txt", "short\n\(Self.longLine)\nafter\n"))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: off" }

        XCTAssertEqual(store.setTextWrap(session.id, pane: nil, mode: .on), .success(true))
        page.apply(try XCTUnwrap(current))
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: on" }

        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))
        try await waitForVariable("--agterm-foreground", "#e0e0e0", in: page.webView)
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: on" }
        let wrapped = try await page.webView.evaluateJavaScript("document.body.classList.contains('agterm-wrapped')")
        XCTAssertEqual(wrapped as? Bool, true)
    }

    private static func section(_ name: String, lines: Int, changes: [Int]) -> [String] {
        var rows = ["diff --git a/\(name) b/\(name)", "--- a/\(name)", "+++ b/\(name)", "@@ -1,\(lines) +1,\(lines) @@"]
        for i in 0..<lines { rows += changes.contains(i) ? ["-old \(i)", "+new \(i)"] : [" line \(i)"] }
        return rows
    }

    private static let fourFiles = (section("a.go", lines: 30, changes: [2]) + section("b.go", lines: 30, changes: [20, 25])
        + ["diff --git a/c.sh b/c.sh", "old mode 100644", "new mode 100755"] + section("d.go", lines: 30, changes: [3]))
        .joined(separator: "\n") + "\n"
    private static let fileButton = """
        (document.querySelector('.agterm-file-path')?.textContent ?? '').replace(/\\u200e/g, '') + ' '
          + (document.querySelector('.agterm-file-place')?.textContent ?? '')
        """
    private static let fileMenu = """
        (() => {
          const menu = document.querySelector('.agterm-files-menu');
          if (menu.hidden) return 'closed';
          const rows = [...menu.querySelectorAll('.agterm-files-row')];
          return rows.map((row) => (row.getAttribute('aria-selected') === 'true' ? '>' : '') + row.lastChild.textContent).join(',')
            + '|' + (document.activeElement === menu.querySelector('input'));
        })()
        """

    private static func headerGap(_ line: Int) -> String {
        """
        (() => {
          const pre = document.querySelector('#agterm-page pre');
          const style = getComputedStyle(pre);
          const top = document.getElementById('agterm-page').offsetTop + pre.offsetTop + parseFloat(style.paddingTop)
            + \(line) * parseFloat(style.lineHeight);
          return Math.round(top - document.scrollingElement.scrollTop - document.querySelector('.agterm-bar').offsetHeight);
        })()
        """
    }

    private func fileKey(_ key: String, ctrl: Bool = false, _ view: WKWebView) async throws {
        _ = try await inRenderer("""
            document.querySelector('.agterm-files-menu input')
              .dispatchEvent(new KeyboardEvent('keydown', { key: \(try json(key)), ctrlKey: \(ctrl), bubbles: true })); true
            """, view)
    }

    private func filterFiles(_ value: String, _ view: WKWebView) async throws {
        _ = try await inRenderer("""
            (() => {
              const field = document.querySelector('.agterm-files-menu input');
              field.value = \(try json(value));
              field.dispatchEvent(new Event('input'));
              return true;
            })()
            """, view)
    }

    private func shownFourFiles() async throws -> (HtmlOverlayPage, NSWindow) {
        let (page, window) = try shown(try openText("a.diff", Self.fourFiles))
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "a.go 1/4" }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "4 changes" }
        return (page, window)
    }

    func testAPickedFileShowsItsHeaderAndMakesItsFirstChangeCurrent() async throws {
        let (page, window) = try await shownFourFiles()
        defer { window.orderOut(nil) }
        let first = try await page.webView.evaluateJavaScript("document.querySelector('.agterm-bar').firstElementChild.className")
        XCTAssertEqual(first as? String, "agterm-wrap")

        try await press("f", page.webView)
        try await waitForScript(Self.fileMenu, in: page.webView) { $0 == ">a.go,b.go,c.sh,d.go|true" }
        try await fileKey("ArrowDown", page.webView)
        try await fileKey("n", ctrl: true, page.webView)
        try await waitForScript(Self.fileMenu, in: page.webView) { $0 == "a.go,b.go,>c.sh,d.go|true" }
        try await fileKey("ArrowUp", page.webView)
        try await fileKey("Enter", page.webView)

        try await waitForScript(Self.fileMenu, in: page.webView) { $0 == "closed" }
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "b.go 2/4" }
        try await waitForScript(Self.headerGap(35), in: page.webView) { $0 == "0" }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 2 of 4" }
        try await waitFor("the pick's change report") { self.current?.textChanges == TextChanges(count: 4, current: 2) }
    }

    // a picked change below the view was stepped from the view's top, which reached it again
    func testStepsGoOnFromAPickedChangeBelowTheView() async throws {
        let (page, window) = try await shownFourFiles()
        defer { window.orderOut(nil) }
        try await press("f", page.webView)
        try await filterFiles("b.go", page.webView)
        try await fileKey("Enter", page.webView)
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 2 of 4" }

        try await press("]", page.webView)
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 3 of 4" }
        try await press("]", page.webView)
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 4 of 4" }
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "d.go 4/4" }

        try await press("f", page.webView)
        try await filterFiles("b.go", page.webView)
        try await fileKey("Enter", page.webView)
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 2 of 4" }
        try await press("[", page.webView)
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 1 of 4" }
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "a.go 1/4" }
    }

    func testAFileWithNoChangeClearsTheChangeAndAnEmptyFilterPicksNothing() async throws {
        let (page, window) = try await shownFourFiles()
        defer { window.orderOut(nil) }
        try await press("f", page.webView)
        try await filterFiles("SH", page.webView)
        try await waitForScript(Self.fileMenu, in: page.webView) { $0 == ">c.sh|true" }
        try await fileKey("Enter", page.webView)
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "c.sh 3/4" }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "4 changes" }

        try await press("f", page.webView)
        try await filterFiles("zz", page.webView)
        try await waitForScript(Self.fileMenu, in: page.webView) { $0 == "|true" }
        try await fileKey("Enter", page.webView)
        try await fileKey("Escape", page.webView)

        try await waitForScript(Self.fileMenu, in: page.webView) { $0 == "closed" }
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "c.sh 3/4" }
    }

    func testAFileJumpTakesANumberOrAPathAndReportsTheFileInView() async throws {
        let (page, window) = try await shownFourFiles()
        defer { window.orderOut(nil) }
        try await waitFor("the first files report") { self.current?.textFiles == TextFiles(count: 4, current: 1, path: "a.go") }
        let bridge = try XCTUnwrap(page.textPage)

        let byPath = await bridge.goFile("d.go")
        XCTAssertEqual(byPath, .success(TextFiles(count: 4, current: 4, path: "d.go")))
        XCTAssertEqual(current?.textFiles, TextFiles(count: 4, current: 4, path: "d.go"))
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "d.go 4/4" }
        let byNumber = await bridge.goFile("2")
        XCTAssertEqual(byNumber, .success(TextFiles(count: 4, current: 2, path: "b.go")))
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 2 of 4" }

        let missing = await bridge.goFile("zz.go")
        let past = await bridge.goFile("5")
        XCTAssertEqual(missing, .failure(.noFile("zz.go")))
        XCTAssertEqual(past, .failure(.noFile("5")))

        _ = try await inRenderer("document.scrollingElement.scrollTop = 0; true", page.webView)
        try await waitFor("the scroll's files report") { self.current?.textFiles == TextFiles(count: 4, current: 1, path: "a.go") }
    }

    func testTheOpenFileListKeepsPageKeysAndTheFileFollowsTheScroll() async throws {
        let (page, window) = try await shownFourFiles()
        defer { window.orderOut(nil) }
        try await press("f", page.webView)
        try await fileKey("w", page.webView)
        try await fileKey("Escape", page.webView)
        try await waitForScript(Self.fileMenu, in: page.webView) { $0 == "closed" }
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: off" }

        _ = try await inRenderer("document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight; true", page.webView)
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "d.go 4/4" }
        _ = try await inRenderer("document.scrollingElement.scrollTop = 0; true", page.webView)
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "a.go 1/4" }
    }

    private static func scrollToHeader(_ line: Int) -> String {
        """
        (() => {
          const pre = document.querySelector('#agterm-page pre');
          const style = getComputedStyle(pre);
          document.scrollingElement.scrollTop = document.getElementById('agterm-page').offsetTop + pre.offsetTop
            + parseFloat(style.paddingTop) + \(line) * parseFloat(style.lineHeight) - document.querySelector('.agterm-bar').offsetHeight;
          return true;
        })()
        """
    }

    private func rebuild(_ page: HtmlOverlayPage, foreground: String) async throws {
        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: foreground, dark: true))
        try await waitForVariable("--agterm-foreground", foreground, in: page.webView)
    }

    func testARebuildKeepsAPickedChangeAsTheStepsOrigin() async throws {
        let (page, window) = try await shownFourFiles()
        defer { window.orderOut(nil) }
        _ = try await XCTUnwrap(page.textPage).goFile("b.go")
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 2 of 4" }

        try await rebuild(page, foreground: "#e0e0e0")
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "b.go 2/4" }
        try await press("]", page.webView)

        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 3 of 4" }
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "b.go 2/4" }
    }

    func testARebuildAfterScrollingAwayStepsFromTheView() async throws {
        let (page, window) = try await shownFourFiles()
        defer { window.orderOut(nil) }
        _ = try await XCTUnwrap(page.textPage).goFile("b.go")
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 2 of 4" }
        _ = try await inRenderer(Self.scrollToHeader(74), page.webView)
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "d.go 4/4" }

        try await rebuild(page, foreground: "#e0e0e0")
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "d.go 4/4" }
        try await press("]", page.webView)

        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 4 of 4" }
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "d.go 4/4" }
    }

    func testARebuildKeepsAPickedShortLastFileUntilTheViewMoves() async throws {
        let text = (Self.section("a.go", lines: 30, changes: [2]) + ["diff --git a/c.sh b/c.sh", "old mode 100644", "new mode 100755"])
            .joined(separator: "\n") + "\n"
        let (page, window) = try shown(try openText("a.diff", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "a.go 1/2" }
        _ = try await XCTUnwrap(page.textPage).goFile("c.sh")
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "c.sh 2/2" }
        let gap = try await page.webView.evaluateJavaScript(Self.headerGap(34)) as? Int
        XCTAssertGreaterThan(gap ?? 0, 0)

        try await rebuild(page, foreground: "#e0e0e0")
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "c.sh 2/2" }
        _ = try await inRenderer("document.scrollingElement.scrollTop = 0; true", page.webView)
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "a.go 1/2" }
        _ = try await inRenderer("document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight; true", page.webView)
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "a.go 1/2" }

        try await rebuild(page, foreground: "#d0d0d0")
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "a.go 1/2" }
    }

    func testAReloadDropsTheReplacedPagesFileReports() async throws {
        let url = pages.appendingPathComponent("a.diff")
        try Self.fourFiles.write(to: url, atomically: true, encoding: .utf8)
        let gate = TailGate(), disk = replicaLink()
        let link = HtmlReplicaLink(fetch: { path, revision in
            gate.asked += 1
            while gate.hang { try await Task.sleep(for: .milliseconds(20)) }
            return try await disk.fetch(path, revision)
        }, bridge: disk.bridge, logTail: disk.logTail)
        let page = registry.page(for: openReplica(url.path, .text(line: nil)), store: store, replica: link)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitFor("the first files report") { self.current?.textFiles == TextFiles(count: 4, current: 1, path: "a.go") }

        try "no changes here\n".write(to: url, atomically: true, encoding: .utf8)
        gate.hang = true
        let asked = gate.asked
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitFor("a read is in flight") { gate.asked > asked && self.current?.textFiles == nil }
        _ = try await inRenderer("document.scrollingElement.scrollTop = document.scrollingElement.scrollHeight; true", page.webView)
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "d.go 4/4" }
        _ = try await page.webView.evaluateJavaScript("true")
        gate.hang = false

        try await waitForScript(Self.code, in: page.webView) { $0 == "no changes here\n" }
        XCTAssertNil(current?.textFiles)
    }

    // the page numbers lines after HTML turned every CR into a line break, so a lone CR shifted every later header
    func testALoneCarriageReturnKeepsAFileJumpOnItsHeader() async throws {
        let text = "--- a/x\n+++ b/x\n@@ -1,2 +1 @@\n-a\rb\n+c\n" + Self.section("y", lines: 30, changes: [3]).joined(separator: "\n") + "\n"
        let (page, window) = try shown(try openText("a.diff", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "b/x 1/2" }

        let jumped = try await XCTUnwrap(page.textPage).goFile("y")

        XCTAssertEqual(jumped, .success(TextFiles(count: 2, current: 2, path: "y")))
        try await waitForScript(Self.headerGap(6), in: page.webView) { $0 == "0" }
    }

    func testTheFileButtonLeavesTheSearchControlsOnANarrowPage() async throws {
        let long = "agtermCore/Sources/agtermCore/ControlProjection+Text.swift"
        let text = (Self.section(long, lines: 30, changes: [2]) + Self.section("site/commands.html", lines: 30, changes: [4]))
            .joined(separator: "\n") + "\n"
        let (page, window) = try shown(try openText("a.diff", text))
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 440, height: 300))
        page.webView.frame = try XCTUnwrap(window.contentView).bounds
        try await waitForScript("document.documentElement.clientWidth", in: page.webView) { $0 == "440" }
        try await waitForScript(Self.fileButton, in: page.webView) { $0 == "\(long) 1/2" }
        let fits = """
            (() => {
              const width = document.documentElement.clientWidth;
              const box = (selector) => document.querySelector(selector).getBoundingClientRect();
              const button = box('.agterm-files'), place = box('.agterm-file-place'), chevron = box('.agterm-files svg');
              const controls = [...document.querySelectorAll('.agterm-search input, .agterm-search button')].map(e => e.getBoundingClientRect().right);
              return [place.width > 0, place.right <= button.right, chevron.right <= button.right,
                      button.right <= box('.agterm-search').left, Math.max(...controls) <= width].join('|');
            })()
            """

        let opened = try await page.webView.evaluateJavaScript(fits) as? String
        try await press("]", page.webView)
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "change 1 of 2" }
        let stepped = try await page.webView.evaluateJavaScript(fits) as? String
        window.setContentSize(NSSize(width: 1200, height: 300))
        page.webView.frame = try XCTUnwrap(window.contentView).bounds
        try await waitForScript("document.documentElement.clientWidth", in: page.webView) { $0 == "1200" }
        let wide = try await page.webView.evaluateJavaScript("""
            (() => {
              const path = document.querySelector('.agterm-file-path'), label = document.querySelector('.agterm-changes span');
              return [path.clientWidth > 0 && path.clientWidth >= path.scrollWidth, label.offsetWidth > 0].join('|');
            })()
            """) as? String

        XCTAssertEqual([opened, stepped], Array(repeating: "true|true|true|true|true", count: 2))
        XCTAssertEqual(wide, "true|true")
    }

    func testADiffBandCoversEveryRowOfAWrappedLine() async throws {
        let diff = "--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n context\n-old\n+\(Self.longLine)\n"
        let (page, window) = try shown(try openText("a.diff", diff))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.changesLabel, in: page.webView) { $0 == "1 change" }
        let added = """
            (() => {
              const band = document.querySelector('.agterm-added');
              const gutter = document.querySelector('.agterm-gutter').textContent.split('\\n');
              const height = parseFloat(getComputedStyle(document.querySelector('#agterm-page pre')).lineHeight);
              return [parseFloat(band.style.height) / height, gutter.length - gutter.indexOf('6')].join('|');
            })()
            """
        try await waitForScript(added, in: page.webView) { $0 == "1|1" }

        try await press("w", page.webView)

        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: on" }
        let measured = try await page.webView.evaluateJavaScript(added) as? String
        let rows = try XCTUnwrap(measured).split(separator: "|")
        XCTAssertEqual(rows[0], rows[1])
        XCTAssertGreaterThan(Int(rows[0]) ?? 0, 1)
    }

    func testAWrapToggleKeepsAFollowingLogAtItsEnd() async throws {
        let text = (1...200).map { $0 % 10 == 0 ? "line \($0) \(Self.longLine)" : "line \($0)" }.joined(separator: "\n") + "\n"
        let (overlay, _) = try openLog(text)
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }

        try await press("w", page.webView)

        try await waitFor("the toggle reaches the model") { self.current?.textWrap == true }
        try await waitForScript(Self.atBottom, in: page.webView) { $0 == "true" }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(current?.logState?.following, true)
    }

    func testAWrappedFollowingLogStaysAtItsEndWhenItNarrows() async throws {
        let text = (1...200).map { $0 % 10 == 0 ? "line \($0) \(Self.longLine)" : "line \($0)" }.joined(separator: "\n") + "\n"
        let (overlay, _) = try openLog(text)
        let (page, window) = try shown(overlay)
        defer { window.orderOut(nil) }
        try await waitForScript(Self.bar, in: page.webView) { $0.contains("Follow: on") }
        try await press("w", page.webView)
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: on" }
        try await waitForScript(Self.atBottom, in: page.webView) { $0 == "true" }

        page.webView.frame.size.width = 250

        try await waitForScript("window.innerWidth", in: page.webView) { $0 == "250" }
        try await waitForScript(Self.atBottom, in: page.webView) { $0 == "true" }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(current?.logState?.following, true)
    }

    func testAWrapToggleOnAPausedLogIsWhereAThemeRebuildReopens() async throws {
        let text = (1...200).map { $0 % 10 == 0 ? "line \($0) \(Self.longLine)" : "line \($0)" }.joined(separator: "\n") + "\n"
        let (overlay, _) = try openLog(text)
        let (page, window) = try shown(overlay)
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

        try await press("w", page.webView)
        try await waitFor("the toggle reaches the model") { self.current?.textWrap == true }
        page.apply(try XCTUnwrap(current))
        let toggled = try await page.webView.evaluateJavaScript("Math.round(document.scrollingElement.scrollTop)") as? Int
        XCTAssertNotEqual(toggled, 600)

        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))

        try await waitForVariable("--agterm-foreground", "#e0e0e0", in: page.webView)
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: on" }
        try await waitForScript("Math.round(document.scrollingElement.scrollTop)", in: page.webView) { $0 == "\(toggled ?? -1)" }
    }

    // regression: a stale wrap cache suppressed a control change after a click
    func testAControlWrapAfterAClickTheBridgeHasNotAppliedReachesThePage() async throws {
        let (page, window) = try shown(try openText("a.txt", "short\n\(Self.longLine)\nafter\n"))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: off" }
        _ = try await inRenderer("document.querySelector('.agterm-wrap').click(); true", page.webView)
        try await waitFor("the click reaches the model") { self.current?.textWrap == true }

        XCTAssertEqual(store.setTextWrap(session.id, pane: nil, mode: .off), .success(false))
        page.apply(try XCTUnwrap(current))

        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: off" }
    }

    func testAWrapToggleKeepsTheLineUnderTheBar() async throws {
        let text = (1...300).map { $0 % 5 == 0 ? "line \($0) \(Self.longLine)" : "line \($0)" }.joined(separator: "\n") + "\n"
        let (page, window) = try shown(try openText("a.txt", text))
        defer { window.orderOut(nil) }
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: off" }
        let lineUnderBar = """
            (() => {
              const bar = document.querySelector('.agterm-bar').getBoundingClientRect();
              const code = document.querySelector('#agterm-page pre code');
              const caret = document.caretRangeFromPoint(code.getBoundingClientRect().left + 2, bar.bottom + 4);
              const before = document.createRange();
              before.setStart(code, 0);
              before.setEnd(caret.startContainer, caret.startOffset);
              return before.toString().split('\\n').length;
            })()
            """
        _ = try await inRenderer("document.scrollingElement.scrollTop = 3000; true", page.webView)
        try await waitForScript("Math.round(document.scrollingElement.scrollTop)", in: page.webView) { $0 == "3000" }
        let unwrapped = try await page.webView.evaluateJavaScript(lineUnderBar) as? Int
        XCTAssertGreaterThan(unwrapped ?? 0, 100)

        try await press("w", page.webView)
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: on" }
        let wrapped = try await page.webView.evaluateJavaScript(lineUnderBar) as? Int
        try await press("w", page.webView)
        try await waitForScript(Self.wrapButton, in: page.webView) { $0 == "Wrap: off" }
        let back = try await page.webView.evaluateJavaScript(lineUnderBar) as? Int

        XCTAssertEqual([wrapped, back], [unwrapped, unwrapped])
    }
}
