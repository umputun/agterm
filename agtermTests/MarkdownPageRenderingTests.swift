import WebKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class MarkdownPageRenderingTests: HtmlPageTestCase {
    // regression: a loose list item opens with a newline text node, so its marker stayed text
    func testALooseTaskListGetsItsBoxes() async throws {
        let page = registry.page(for: try openMarkdown("doc.md", "- [x] done\n\n- [ ] open\n"), store: store)
        try await waitForScript("document.querySelectorAll('li').length", in: page.webView) { $0 == "2" }

        let rendered = try await page.webView.evaluateJavaScript("""
            [document.querySelectorAll('li.task input[type=checkbox]:checked').length,
             document.querySelectorAll('li.task input[type=checkbox]:not(:checked)').length,
             [...document.querySelectorAll('li')].map(li => li.textContent.trim()).join(',')].join('|')
            """)
        XCTAssertEqual(rendered as? String, "1|1|done,open")
    }

    // regression: the closing `---` turned the yaml lines into a setext heading under a rule
    func testLeadingFrontmatterRendersAsAYamlBlock() async throws {
        let source = "---\nname: chat\ndescription: 'a <b> peer''s chat'\n---\n# Chat\n\nbody\n\n---\n\nafter\n\n```\ncode\n```\n"
        let page = registry.page(for: try openMarkdown("doc.md", source), store: store)
        try await waitForScript("document.querySelector('h1')?.textContent ?? ''", in: page.webView) { $0 == "Chat" }

        let rendered = try await page.webView.evaluateJavaScript("""
            [document.querySelectorAll('h2').length, document.querySelectorAll('hr').length,
             document.querySelector('#agterm-page > :first-child').matches('pre.agterm-frontmatter'),
             document.querySelector('pre.agterm-frontmatter code.language-yaml').textContent,
             document.querySelectorAll('pre.agterm-frontmatter .hljs-attr').length > 0,
             document.querySelectorAll('b').length,
             getComputedStyle(document.querySelector('pre.agterm-frontmatter')).whiteSpace,
             getComputedStyle(document.querySelector('pre:not(.agterm-frontmatter)')).whiteSpace].join('|')
            """)
        XCTAssertEqual(rendered as? String, "0|1|true|name: chat\ndescription: 'a <b> peer''s chat'|true|0|pre-wrap|pre")
    }

    // regression: the parser dropped the newline after a <pre> holder, so a rule on line two read as frontmatter
    func testARuleAfterALeadingBlankLineIsNotFrontmatter() async throws {
        let page = registry.page(for: try openMarkdown("doc.md", "\n---\n## Heading\n\nbody\n---\n"), store: store)
        try await waitForScript("document.querySelector('#agterm-page > *') ? 'ready' : ''", in: page.webView) { $0 == "ready" }

        let rendered = try await page.webView.evaluateJavaScript("""
            [document.querySelectorAll('pre.agterm-frontmatter').length, document.querySelectorAll('hr').length,
             [...document.querySelectorAll('h2')].map(h => h.textContent).join(',')].join('|')
            """)
        XCTAssertEqual(rendered as? String, "0|1|Heading,body")
    }

    func testAMarkdownPageRendersThemedWithCodeAndTasksAndGetsNoBridge() async throws {
        let page = registry.page(for: try openMarkdown("doc.md", "# Title\n\n- [x] done\n- [ ] open\n\n```swift\nlet x = 1\n```\n"),
                                 store: store)
        try await waitForScript("document.querySelector('h1')?.textContent ?? ''", in: page.webView) { $0 == "Title" }

        let rendered = try await page.webView.evaluateJavaScript("""
            [document.querySelectorAll('pre code .hljs-keyword').length > 0,
             document.querySelectorAll('li.task input[type=checkbox]:checked').length,
             document.querySelectorAll('li.task input[type=checkbox]:not(:checked)').length,
             document.getElementById('agterm-markdown') === null].join('|')
            """)
        XCTAssertEqual(rendered as? String, "true|1|1|true")
        let foreground = try await variable("--agterm-foreground", in: page.webView)
        XCTAssertFalse(foreground?.isEmpty ?? true)
        let helper = try await page.webView.evaluateJavaScript("typeof window.agterm + '|' + typeof window.webkit?.messageHandlers?.agterm")
        XCTAssertEqual(helper as? String, "undefined|undefined")
        let bridge = try await page.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.agterm", in: nil,
                                                               contentWorld: HtmlOverlayBridge.world)
        XCTAssertEqual(bridge as? String, "undefined")
        XCTAssertEqual(current?.loadState, .loaded)
    }

    func testAMarkdownPageKeepsAuthoredMarkupInertAndLoadsOnlyEmbeddedPictures() async throws {
        _ = try writePNG("shot.png", width: 30)
        let source = """
            # Doc

            <script>document.title = 'ran'</script> <img src=x onerror="document.title = 'ran'">

            ![remote](https://example.com/r.png) ![inline](data:image/png;base64,iVBORw0KGgo=) ![local](shot.png)
            """
        let page = registry.page(for: try openMarkdown("doc.md", source), store: store)
        page.webView.configuration.userContentController.addUserScript(WKUserScript(source: """
            document.addEventListener('securitypolicyviolation', e => {
              document.documentElement.dataset.blocked = (document.documentElement.dataset.blocked || '') + e.blockedURI + ' ';
            });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .world(name: "probe")))
        try await waitForScript("document.querySelector('h1')?.textContent ?? ''", in: page.webView) { $0 == "Doc" }
        try await Task.sleep(for: .milliseconds(300))

        let blocked = try await page.webView.evaluateJavaScript("document.documentElement.dataset.blocked ?? ''")
        XCTAssertEqual(blocked as? String, "", "an authored picture source never reaches the document")
        let images = try await page.webView.evaluateJavaScript("""
            [document.images.length, document.images[0]?.getAttribute('src').startsWith('data:image/png;base64,iVBORw0KGgoAAAANSUhEUg'),
             [...document.querySelectorAll('.agterm-alt')].map(e => e.textContent).join(','),
             document.body.textContent.includes('<script>'), document.title].join('|')
            """)
        XCTAssertEqual(images as? String, "1|true|remote,inline|true|")
        try await waitForScript("document.images[0]?.naturalWidth ?? 0", in: page.webView) { $0 == "30" }
    }

    // regression: every repeated reference wrote the whole data URI into the rendered markup
    func testARepeatedPictureIsSetThroughTheDomAndCappedAtTheEmbeddedLimit() async throws {
        _ = try writePNG("shot.png", width: 30)
        let source = (0..<1000).map { _ in "![s](shot.png)" }.joined(separator: " ") + " ![r](https://example.com/r.png)"
        let page = registry.page(for: try openMarkdown("doc.md", source), store: store)
        page.webView.configuration.userContentController.addUserScript(WKUserScript(source: """
            const setter = Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML').set;
            Object.defineProperty(Element.prototype, 'innerHTML', { set(html) {
              const root = document.documentElement;
              root.dataset.markupPlaceholders = String((html.match(/data-agterm-image=/g) || []).length);
              root.dataset.markupPayload = String(html.includes('data:image'));
              setter.call(this, html);
            } });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .world(name: "agterm-markdown")))
        try await waitForScript("document.querySelectorAll('.agterm-alt').length", in: page.webView) { $0 == "745" }

        let seen = try await page.webView.evaluateJavaScript("""
            [document.images.length, document.querySelectorAll('img[src^="data:image/png"]').length,
             document.documentElement.dataset.markupPlaceholders, document.documentElement.dataset.markupPayload].join('|')
            """)
        XCTAssertEqual(seen as? String, "256|256|256|false")
    }

    // regression: each duplicate heading probed every earlier suffix, quadratic in the run length
    func testManyIdenticalHeadingsGetTheirSuffixesInLinearTime() async throws {
        let source = "# x-2\n\n" + String(repeating: "# x\n\n", count: 50000)
        let clock = ContinuousClock(), started = clock.now
        let page = registry.page(for: try openMarkdown("doc.md", source), store: store)
        try await waitForScript("document.querySelectorAll('h1').length", in: page.webView) { $0 == "50001" }

        let ids = try await page.webView.evaluateJavaScript("""
            (() => { const h = document.querySelectorAll('h1'); return [h[0].id, h[1].id, h[2].id, h[3].id, h[50000].id].join(',') })()
            """)
        XCTAssertEqual(ids as? String, "x-2,x,x-1,x-3,x-50000")
        XCTAssertLessThan(clock.now - started, .seconds(10))
    }

    func testAMarkdownPageLinksHeadingsAndKeepsOtherTargetsInert() async throws {
        let source = "# Intro & Setup!\n\n## Usage\n\n## Usage\n\n## Usage-1\n\n"
            + "[a](#usage-1) [b](about:blank) [c](other.md) [d](https://example.com/x)\n"
        let page = registry.page(for: try openMarkdown("doc.md", source), store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitForScript("document.querySelectorAll('h2').length", in: page.webView) { $0 == "3" }

        let ids = try await page.webView.evaluateJavaScript("[...document.querySelectorAll('h1, h2')].map(h => h.id).join(',')")
        XCTAssertEqual(ids as? String, "intro--setup,usage,usage-1,usage-1-1", "a heading named like a suffixed duplicate gets its own id")
        let hrefs = try await page.webView.evaluateJavaScript("[...document.querySelectorAll('a')].map(a => a.getAttribute('href')).join(',')")
        XCTAssertEqual(hrefs as? String, "#usage-1,,,https://example.com/x")

        _ = try await page.webView.evaluateJavaScript("document.querySelectorAll('a')[3].click()")
        try await waitFor("web link handed to the confirmation") { self.browser.prompts.count == 1 }
        XCTAssertEqual(browser.prompts, [try XCTUnwrap(URL(string: "https://example.com/x"))])
        _ = try await page.webView.evaluateJavaScript("document.querySelectorAll('a')[1].click(); document.querySelectorAll('a')[2].click()")
        _ = try await page.webView.evaluateJavaScript("document.querySelectorAll('a')[0].click()")
        try await waitForScript("location.hash", in: page.webView) { $0 == "#usage-1" }
        let heading = try await page.webView.evaluateJavaScript("document.querySelector('h1').textContent")
        XCTAssertEqual(heading as? String, "Intro & Setup!", "the inert links leave the document in place")
        XCTAssertEqual(current?.loadState, .loaded)
    }

    func testAMarkdownPageReRendersOnReloadAndOnAThemeChange() async throws {
        let overlay = try openMarkdown("doc.md", "# One\n\n[a](#one)\n")
        let page = registry.page(for: overlay, store: store)
        try await waitForScript("document.querySelector('h1')?.textContent ?? ''", in: page.webView) { $0 == "One" }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('a').click()")
        try await waitForScript("location.hash", in: page.webView) { $0 == "#one" }

        try "# Two\n".write(to: pages.appendingPathComponent("doc.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(registry.reload(page.id, target: .current, store: store))
        try await waitForScript("document.querySelector('h1')?.textContent ?? ''", in: page.webView) { $0 == "Two" }

        try "# Three\n".write(to: pages.appendingPathComponent("doc.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitForScript("document.querySelector('h1')?.textContent ?? ''", in: page.webView) { $0 == "Three" }

        page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true))
        try await waitForVariable("--agterm-foreground", "#102030", in: page.webView)
        try await waitForScript("document.querySelector('h1')?.textContent ?? ''", in: page.webView) { $0 == "Three" }
    }

    func testAMarkdownReplicaRendersWithItsFetchedPictureAndNoBridge() async throws {
        let shot = try writePNG("shot.png", width: 40)
        let doc = pages.appendingPathComponent("doc.md")
        try "# Remote\n\n![s](shot.png) ![x](../outside.png)\n".write(to: doc, atomically: true, encoding: .utf8)

        let page = registry.page(for: openReplica(doc.path, .markdown), store: store, replica: replicaLink())

        try await waitForScript("document.querySelector('h1')?.textContent ?? ''", in: page.webView) { $0 == "Remote" }
        try await waitForScript("document.querySelectorAll('img[src^=\"data:image/png\"]').length", in: page.webView) { $0 == "1" }
        XCTAssertEqual(fetched, [doc.path, shot])
        let bridge = try await page.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.agterm", in: nil,
                                                               contentWorld: HtmlOverlayBridge.world)
        XCTAssertEqual(bridge as? String, "undefined")
    }

    func testAMarkdownPageStaysInItsOverlay() async throws {
        let overlay = try openMarkdown("doc.md", "# Doc\n")
        _ = registry.page(for: overlay, store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded }

        XCTAssertEqual(registry.navigate(overlay.id, .browser), OverlayHtmlError.markdownInOverlay)
        XCTAssertEqual(registry.navigate(overlay.id, .finder), OverlayHtmlError.finderRequiresFile)
        XCTAssertEqual(browser.opened, [])
        XCTAssertEqual(sharing.revealed, [])
    }

    func testAMissingMarkdownFileReportsAFailure() async throws {
        let overlay = HtmlOverlay(source: .markdown(path: pages.appendingPathComponent("missing.md").path))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        _ = registry.page(for: overlay, store: store)

        try await waitFor("failed") { self.current?.loadState == .failed }
        XCTAssertEqual(current?.loadError, MarkdownProbe.Failure.unreadable(overlay.source.markdownPath ?? "").description)
    }

    private func openMarkdown(_ name: String, _ text: String) throws -> HtmlOverlay {
        let url = pages.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let overlay = HtmlOverlay(source: .markdown(path: url.path))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }
}
