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

    func testALinkPageKeepsOnlyRelativeLinksToNeighbouringMarkdown() async throws {
        let source = "[a](sub/b.md) [b](c.MARKDOWN) [c](x.md#h) [k](x.md?q=1) [d](/abs.md) [e](//host/x.md) "
            + "[f](x.txt) [g](x.md/) [h](https://example.com/x.md) [j](#frag) [l](..%5Cx.md)\n"
        let view = linkPageView()
        view.loadHTMLString(MarkdownPage.html(markdown: source, images: .init(), style: "", links: true), baseURL: nil)
        try await waitForScript("document.querySelectorAll('a').length", in: view) { $0 == "11" }

        let hrefs = try await view.evaluateJavaScript("""
            [...document.querySelectorAll('a')].map(a => a.textContent + '=' + (a.getAttribute('href') ?? '')).join(',')
            """)
        XCTAssertEqual(hrefs as? String,
                       "a=sub/b.md,b=c.MARKDOWN,c=x.md#h,k=x.md?q=1,d=,e=,f=,g=,h=https://example.com/x.md,j=#frag,l=..%5Cx.md")
    }

    func testALinkPageFollowsALinkWithHistoryScrollReloadAndThemeRefresh() async throws {
        let filler = (1...150).map { "paragraph \($0) of filler text that takes up a line or two." }.joined(separator: "\n\n")
        let first = try writeMarkdown("a.md", "# A\n\n\(filler)\n\n[to b](sub/b.md#deep)\n")
        let second = try writeMarkdown("sub/b.md", "# B\n\n\(filler)\n\n## Deep\n\n\(filler)\n")
        let overlay = try openLinkPage(first)
        let page = registry.page(for: overlay, store: store)
        let view = page.webView
        let window = try host(view)
        defer { window.orderOut(nil) }
        let scroll = { try await view.evaluateJavaScript("Math.round(window.scrollY)") as? Int ?? -1 }
        try await waitForHeading("A", in: view)
        try await waitFor("first page reported") { self.current?.current?.page == self.canonical(first) }

        _ = try await view.evaluateJavaScript("window.scrollTo(0, 1500)")
        try await waitForScript("Math.round(window.scrollY)", in: view) { $0 == "1500" }
        _ = try await view.evaluateJavaScript("document.querySelector('a').click()")
        try await waitForScript("document.getElementById('deep') ? 'yes' : ''", in: view) { $0 == "yes" }
        try await waitForScript("Math.round(window.scrollY) > 1500 && Math.abs(document.getElementById('deep').getBoundingClientRect().top) < 5",
                                in: view) { $0 == "true" }
        try await waitFor("second page reported") { self.current?.current?.page == self.canonical(second) && self.current?.current?.canGoBack == true }
        XCTAssertEqual(current?.identity, "b.md")
        XCTAssertEqual(current?.source.markdownPath, first)
        let moved = try await scroll() - 900
        _ = try await view.evaluateJavaScript("window.scrollTo(0, \(moved))")
        try await waitForScript("Math.round(window.scrollY)", in: view) { $0 == "\(moved)" }

        XCTAssertNil(registry.navigate(overlay.id, .back))
        try await waitForHeading("A", in: view)
        try await waitForScript("Math.round(window.scrollY)", in: view) { $0 == "1500" }
        try await waitFor("back reported") { self.current?.current?.page == self.canonical(first) && self.current?.current?.canGoForward == true }
        XCTAssertNil(registry.navigate(overlay.id, .forward))
        try await waitForHeading("B", in: view)
        try await waitForScript("Math.round(window.scrollY)", in: view) { $0 == "\(moved)" }

        let history = (view.backForwardList.backList.count, view.backForwardList.forwardList.count)
        let freshB = "!document.documentElement.dataset.stale && document.querySelector('h1')?.textContent === 'B'"
        _ = try await view.evaluateJavaScript("document.documentElement.dataset.stale = '1'")
        XCTAssertNil(registry.reload(overlay.id, target: .current, store: store))
        try await waitForScript(freshB, in: view) { $0 == "true" }
        try await waitForScript("Math.round(window.scrollY)", in: view) { $0 == "\(moved)" }
        XCTAssertEqual(view.backForwardList.backList.count, history.0)
        XCTAssertEqual(view.backForwardList.forwardList.count, history.1)

        _ = try await view.evaluateJavaScript("document.documentElement.dataset.stale = '1'")
        page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true))
        try await waitForScript(freshB, in: view) { $0 == "true" }
        try await waitForVariable("--agterm-foreground", "#102030", in: view)
        try await waitForScript("Math.round(window.scrollY)", in: view) { $0 == "\(moved)" }
        XCTAssertEqual(view.backForwardList.backList.count, history.0)
        XCTAssertEqual(view.backForwardList.forwardList.count, history.1)

        XCTAssertNil(registry.reload(overlay.id, target: .original, store: store))
        try await waitForHeading("A", in: view)
        try await waitFor("original reported") { self.current?.current?.page == self.canonical(first) }
    }

    func testALinkPageKeepsItsDocumentWhenALinkedFileCannotBeRead() async throws {
        let first = try writeMarkdown("a.md", "# A\n\n[gone](missing.md) [listed](b.md)\n")
        let second = try writeMarkdown("b.md", "# B\n")
        let page = registry.page(for: try openLinkPage(first), store: store)
        try await waitForHeading("A", in: page.webView)
        try FileManager.default.removeItem(atPath: second)

        for index in 0..<2 {
            _ = try await page.webView.evaluateJavaScript("document.querySelectorAll('a')[\(index)].click()")
            try await waitFor("link \(index) settled") { self.current?.loadState == .loaded && self.current?.loadError == nil }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(current?.loadState, .loaded)
        XCTAssertNil(current?.loadError)
        XCTAssertEqual(current?.current?.page, canonical(first))
        XCTAssertEqual(current?.current?.canGoBack, false)
        let heading = try await page.webView.evaluateJavaScript("document.querySelector('h1').textContent")
        XCTAssertEqual(heading as? String, "A")
    }

    func testALinkPageKeepsItsDocumentWhenItsOwnFileIsRetargetedOutsideTheFolder() async throws {
        let first = try writeMarkdown("a.md", "# A\n")
        try "# Outside\n".write(to: directory.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        let overlay = try openLinkPage(first)
        let page = registry.page(for: overlay, store: store)
        try await waitForHeading("A", in: page.webView)
        try FileManager.default.removeItem(atPath: first)
        try FileManager.default.createSymbolicLink(atPath: first, withDestinationPath: directory.appendingPathComponent("outside.md").path)

        for target in [HtmlReloadTarget.current, .original] {
            XCTAssertNil(registry.reload(overlay.id, target: target, store: store))
            try await waitFor("reload settled") { self.current?.loadState == .loaded }
        }
        try await Task.sleep(for: .milliseconds(300))
        let heading = try await page.webView.evaluateJavaScript("document.querySelector('h1').textContent")
        XCTAssertEqual(heading as? String, "A")
        XCTAssertNil(current?.loadError)
    }

    func testALinkedFileAliasResolvesItsLinksAndPicturesFromWhereItWasRequested() async throws {
        let first = try writeMarkdown("start.md", "# Start\n\n[b](alias.md)\n")
        _ = try writeMarkdown("sub/b.md", "# B\n\n![p](p.png)\n\n[next](c.md)\n")
        _ = try writeMarkdown("c.md", "# Root C\n")
        _ = try writeMarkdown("sub/c.md", "# Sub C\n")
        _ = try writePNG("p.png", width: 20)
        try FileManager.default.createSymbolicLink(atPath: pages.appendingPathComponent("alias.md").path,
                                                   withDestinationPath: pages.appendingPathComponent("sub/b.md").path)
        let page = registry.page(for: try openLinkPage(first), store: store)
        try await waitForHeading("Start", in: page.webView)

        _ = try await page.webView.evaluateJavaScript("document.querySelector('a').click()")
        try await waitForHeading("B", in: page.webView)
        try await waitForScript("document.querySelectorAll('img[src^=\"data:image/png\"]').length", in: page.webView) { $0 == "1" }
        _ = try await page.webView.evaluateJavaScript("document.querySelector('a').click()")
        try await waitForHeading("Root C", in: page.webView)
    }

    func testALinkPageWhoseFileIsGoneBeforeItsFirstLoadFails() async throws {
        let first = try writeMarkdown("a.md", "# A\n")
        let overlay = try openLinkPage(first)
        try FileManager.default.removeItem(atPath: first)
        _ = registry.page(for: overlay, store: store)

        try await waitFor("failed") { self.current?.loadState == .failed }
        XCTAssertNotNil(current?.loadError)
    }

    func testALinkPageOpenedThroughASymlinkedFolderFollowsItsRelativeLinks() async throws {
        _ = try writeMarkdown("a.md", "# A\n\n[to b](sub/b.md)\n")
        let second = try writeMarkdown("sub/b.md", "# B\n")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: pages)
        let page = registry.page(for: try openLinkPage(alias.appendingPathComponent("a.md").path), store: store)
        try await waitForHeading("A", in: page.webView)

        _ = try await page.webView.evaluateJavaScript("document.querySelector('a').click()")
        try await waitForHeading("B", in: page.webView)
        try await waitFor("second page reported") { self.current?.current?.page == self.canonical(second) }
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

    func testAReplicaLinkPageFollowsALinkWithHistoryReloadAndThemeRefresh() async throws {
        let first = try writeMarkdown("a.md", "# A\n\n[to b](sub/b.md)\n")
        let second = try writeMarkdown("sub/b.md", "# B\n")
        let grant = try XCTUnwrap(MarkdownPage.linkGrant(for: first))
        let overlay = openReplicaLinkPage(first, grant: grant)
        let page = registry.page(for: overlay, store: store, replica: replicaLink())
        let view = page.webView
        try await waitForHeading("A", in: view)
        XCTAssertEqual(fetched, [grant.path])

        _ = try await view.evaluateJavaScript("document.querySelector('a').click()")
        try await waitForHeading("B", in: view)
        try await waitFor("second page reported") { self.current?.current?.page == self.canonical(second) && self.current?.current?.canGoBack == true }
        XCTAssertEqual(current?.identity, "b.md")

        XCTAssertNil(registry.navigate(overlay.id, .back))
        try await waitForHeading("A", in: view)
        try await waitFor("back reported") { self.current?.current?.page == grant.path && self.current?.current?.canGoForward == true }
        XCTAssertNil(registry.navigate(overlay.id, .forward))
        try await waitForHeading("B", in: view)

        let history = (view.backForwardList.backList.count, view.backForwardList.forwardList.count)
        let freshB = "!document.documentElement.dataset.stale && document.querySelector('h1')?.textContent === 'B'"
        _ = try await view.evaluateJavaScript("document.documentElement.dataset.stale = '1'")
        XCTAssertNil(registry.reload(overlay.id, target: .current, store: store))
        try await waitForScript(freshB, in: view) { $0 == "true" }
        _ = try await view.evaluateJavaScript("document.documentElement.dataset.stale = '1'")
        page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true))
        try await waitForScript(freshB, in: view) { $0 == "true" }
        XCTAssertEqual(view.backForwardList.backList.count, history.0)
        XCTAssertEqual(view.backForwardList.forwardList.count, history.1)
    }

    func testAReplicaLinkPageKeepsItsDocumentWhenTheOriginCannotServeALink() async throws {
        let first = try writeMarkdown("a.md", "# A\n\n[gone](missing.md)\n")
        let page = registry.page(for: openReplicaLinkPage(first, grant: try XCTUnwrap(MarkdownPage.linkGrant(for: first))),
                                 store: store, replica: replicaLink())
        try await waitForHeading("A", in: page.webView)

        _ = try await page.webView.evaluateJavaScript("document.querySelector('a').click()")
        try await waitFor("missing link fetched") { self.fetched.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(current?.loadState, .loaded)
        XCTAssertNil(current?.loadError)
        let heading = try await page.webView.evaluateJavaScript("document.querySelector('h1').textContent")
        XCTAssertEqual(heading as? String, "A")
    }

    func testAReplicaMarkdownPageKeepsLinksAsTextWithoutAGrantAndNeverFetchesAMarkdownPicture() async throws {
        let first = try writeMarkdown("a.md", "# A\n\n![p](pic.md) [b](b.md)\n")
        _ = try writeMarkdown("b.md", "# B\n")
        let plain = registry.page(for: openReplica(first, .markdown), store: store, replica: replicaLink())
        try await waitForHeading("A", in: plain.webView)
        let href = try await plain.webView.evaluateJavaScript("document.querySelector('a').getAttribute('href') ?? ''")
        XCTAssertEqual(href as? String, "")
        XCTAssertEqual(current?.navigation, false)
        XCTAssertEqual(fetched, [first])

        store.closeOverlay(session.id)
        fetched = []
        let linked = registry.page(for: openReplicaLinkPage(first, grant: try XCTUnwrap(MarkdownPage.linkGrant(for: first))),
                                   store: store, replica: replicaLink())
        try await waitForHeading("A", in: linked.webView)
        XCTAssertEqual(fetched.map { URL(fileURLWithPath: $0).lastPathComponent }, ["a.md"])
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

    private var markdownScript: WKUserScript {
        WKUserScript(source: MarkdownAssets.shared.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                     in: WKContentWorld.world(name: "agterm-markdown"))
    }

    private func linkPageView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.addUserScript(markdownScript)
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
    }

    private func writeMarkdown(_ name: String, _ text: String) throws -> String {
        let url = pages.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func openLinkPage(_ path: String) throws -> HtmlOverlay {
        let overlay = HtmlOverlay(source: .markdown(path: path), navigation: true,
                                  markdownLinks: try XCTUnwrap(MarkdownPage.linkGrant(for: path)))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }

    private func openReplicaLinkPage(_ path: String, grant: MarkdownLinkGrant) -> HtmlOverlay {
        let overlay = HtmlOverlay(source: .replica(path: path, content: .markdown), navigation: true, replicaOf: UUID(), markdownLinks: grant)
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }

    private func canonical(_ path: String) -> String? { MarkdownPage.linkGrant(for: path)?.path }

    private func waitForHeading(_ text: String, in view: WKWebView) async throws {
        try await waitForScript("document.querySelector('h1')?.textContent ?? ''", in: view) { $0 == text }
    }

    private func openMarkdown(_ name: String, _ text: String) throws -> HtmlOverlay {
        let url = pages.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let overlay = HtmlOverlay(source: .markdown(path: url.path))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }
}
