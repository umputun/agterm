import Network
import WebKit
import XCTest
@testable import agterm
import agtermCore

private final class LoopbackServer: @unchecked Sendable {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "agterm.test.loopback")
    private var routes: [String: Response]

    init(_ host: NWEndpoint.Host, routes: [String: Response]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: .any)
        listener = try NWListener(using: parameters)
        self.routes = routes
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    func set(_ path: String, _ response: Response) { queue.sync { routes[path] = response } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let response = routes[path] ?? Response(status: 404, body: "not found")
            let headers = (["Content-Type": "text/html", "Content-Length": "\(response.body.utf8.count)",
                            "Connection": "close"].merging(response.headers) { $1 })
                .map { "\($0): \($1)\r\n" }.joined()
            let raw = "HTTP/1.1 \(response.status) X\r\n\(headers)\r\n\(response.body)"
            connection.send(content: Data(raw.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@MainActor
private final class PageProbe: NSObject, WKScriptMessageHandler {
    var messages: [String] = []

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String { messages.append(body) }
    }
}

@MainActor
private final class FakeBrowser: HtmlBrowser {
    var prompts: [URL] = []
    var answers: [(Bool) -> Void] = []
    var dismissals = 0
    var opened: [URL] = []
    var available = true

    func confirm(_ url: URL, over _: NSView, _ done: @escaping (Bool) -> Void) -> (() -> Void)? {
        prompts.append(url)
        answers.append(done)
        return { self.dismissals += 1 }
    }

    func open(_ url: URL) -> Bool {
        guard available else { return false }
        opened.append(url)
        return true
    }
}

@MainActor
final class HtmlOverlayRegistryTests: XCTestCase {
    private final class StubSurface: PaneRoleMutableSurface {
        let paneToken: String
        init(_ token: String) { paneToken = token }
        var isRealized: Bool { true }
        func teardown() {}
        func promoteToPrimaryPane() {}
        func setPaneRole(_: SwappablePaneRole) {}
    }

    private var directory: URL!
    private var pages: URL!
    private var servers: [LoopbackServer] = []
    private var store: AppStore!
    private var session: Session!
    private let registry = HtmlOverlayRegistry.shared
    private let browser = FakeBrowser()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-html-reg-\(UUID().uuidString)")
        pages = directory.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        store = AppStore(persistence: PersistenceStore(directory: directory.appendingPathComponent("state")))
        let workspace = store.addWorkspace(name: "work")
        session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        registry.install()
        registry.browser = browser
        try write("a.html", #"<title>A</title><script src="s.js"></script><a href="b.html">b</a>"#)
        try write("b.html", "<title>B</title>")
        try "document.title = 'script ran'".write(to: pages.appendingPathComponent("s.js"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        servers.forEach { $0.stop() }
        registry.browser = SystemBrowser()
        store.closeSession(session.id)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAPageIsCreatedOncePerIdentityAndReleasedByTheModel() throws {
        let page = try open()
        let first = registry.page(for: page, store: store)
        XCTAssertTrue(registry.page(for: page, store: store) === first)

        XCTAssertTrue(store.closeOverlay(session.id))
        XCTAssertNil(registry.existing(page.id))
        XCTAssertNil(first.webView.navigationDelegate)
    }

    func testASwapKeepsEachPageWithItsWebView() throws {
        store.toggleSplit(session.id)
        session.surface = StubSurface("left")
        session.splitSurface = StubSurface("right")
        let left = try open(pane: .left, file: "a.html")
        let right = try open(pane: .right, file: "b.html")
        let leftView = registry.page(for: left, store: store).webView
        let rightView = registry.page(for: right, store: store).webView

        XCTAssertNil(store.swapPanes(session.id))
        let nowLeft = try XCTUnwrap(session.paneOverlay(.left)?.html)
        XCTAssertTrue(registry.page(for: nowLeft, store: store).webView === rightView)
        let nowRight = try XCTUnwrap(session.paneOverlay(.right)?.html)
        XCTAssertTrue(registry.page(for: nowRight, store: store).webView === leftView)
    }

    func testASoftClosedPageSurvivesUntilTheCloseIsFinal() throws {
        let page = try open()
        _ = registry.page(for: page, store: store)
        XCTAssertTrue(store.softCloseSession(session.id, grace: 60))
        XCTAssertNotNil(registry.existing(page.id))
        store.finalizeAllPendingCloses()
        XCTAssertNil(registry.existing(page.id))
    }

    func testLoadReportsStateTitleAndHistoryAndReloadReturnsToTheOriginal() async throws {
        let page = try open(grant: pages.path)
        let live = registry.page(for: page, store: store)
        try await waitFor("loaded with the script") { self.current?.loadState == .loaded && self.current?.current?.title == "script ran" }

        _ = try await live.webView.evaluateJavaScript("location.href = 'b.html'")
        try await waitFor("navigated to b") { self.current?.current?.page.hasSuffix("/b.html") == true && self.current?.current?.canGoBack == true }

        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitFor("reloaded a") { self.current?.current?.page.hasSuffix("/a.html") == true && self.current?.loadState == .loaded }
    }

    func testDropsAreRegisteredOnlyWhileThePageIsOnScreen() throws {
        let view = registry.page(for: try open(), store: store).webView
        XCTAssertFalse(view.registeredDraggedTypes.isEmpty)
        view.setDropsEnabled(false)
        XCTAssertTrue(view.registeredDraggedTypes.isEmpty)
        let parked = view.registeredDraggedTypes
        view.setDropsEnabled(true)
        XCTAssertFalse(view.registeredDraggedTypes.isEmpty)
        XCTAssertNotEqual(view.registeredDraggedTypes, parked)
    }

    func testAnAuthoredBodyBackgroundFillsTheCanvasAndAnUnstyledPageStaysTransparent() async throws {
        try write("body.html", "<title>W</title><style>body { background: white; color: black }</style><p>short</p>")
        let styled = try await snapshotPixel(file: "body.html")
        XCTAssertEqual(styled.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(styled.redComponent, 1, accuracy: 0.02)
        XCTAssertTrue(store.closeOverlay(session.id))

        try write("plain.html", "<title>P</title><p>short</p>")
        let plain = try await snapshotPixel(file: "plain.html")
        XCTAssertEqual(plain.alphaComponent, 0, accuracy: 0.01, "an unstyled page must leave the themed backing visible")
    }

    func testAThemeChangeReloadsTheFilePageShownAndAnUnchangedThemeDoesNot() async throws {
        let page = registry.page(for: try open(grant: pages.path), store: store)
        try await waitFor("a loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "script ran" }
        _ = try await page.webView.evaluateJavaScript("location.href = 'b.html'")
        try await waitFor("b loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "B" }

        page.applyTheme(registry.theme(backgroundColor: nil))
        XCTAssertFalse(page.webView.isLoading)
        page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true))
        XCTAssertTrue(page.webView.isLoading)
        try await waitForVariable("--agterm-foreground", "#102030", in: page.webView)
        XCTAssertEqual(current?.current?.title, "B")
        let color = try await page.webView.evaluateJavaScript("getComputedStyle(document.documentElement).color")
        XCTAssertEqual(color as? String, "rgb(16, 32, 48)")
    }

    func testAThemeChangeHandsThePageNoUserActivation() async throws {
        try write("hostile.html", """
            <title>H</title><script>
            const report = m => webkit.messageHandlers.probe.postMessage(m + ':' + navigator.userActivation.isActive);
            const byID = document.getElementById.bind(document);
            document.getElementById = id => { report('hook'); return byID(id) };
            new MutationObserver(() => report('mutation'))
              .observe(document.documentElement, {subtree: true, childList: true, attributes: true, characterData: true});
            addEventListener('pagehide', () => report('pagehide'));
            report('ready');
            </script>
            """)
        for grant in [nil, pages.path] {
            let probe = PageProbe()
            let page = registry.page(for: try open(file: "hostile.html", grant: grant), store: store)
            page.webView.configuration.userContentController.add(probe, name: "probe")
            try await waitFor("first load") { probe.messages.contains("ready:false") }
            page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true))
            try await waitFor("reloaded") { probe.messages.filter { $0.hasPrefix("ready") }.count == 2 }
            XCTAssertEqual(probe.messages.filter { $0.hasSuffix(":true") }, [], "grant \(String(describing: grant))")
            XCTAssertFalse(probe.messages.contains { $0.hasPrefix("hook") }, "\(probe.messages)")
            XCTAssertTrue(store.closeOverlay(session.id))
        }
    }

    func testTheFileAloneGrantKeepsSiblingScriptsOut() async throws {
        let page = try open()
        _ = registry.page(for: page, store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title != nil }
        XCTAssertEqual(current?.current?.title, "A")
    }

    func testAFolderGrantKeepsFilesOutsideItOut() async throws {
        try "document.title = 'outside ran'".write(to: directory.appendingPathComponent("outside.js"), atomically: true, encoding: .utf8)
        try write("c.html", #"<title>C</title><script src="../outside.js"></script>"#)
        let page = try open(file: "c.html", grant: pages.path)
        _ = registry.page(for: page, store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title != nil }
        XCTAssertEqual(current?.current?.title, "C")
    }

    func testAMissingFileReportsAFailure() async throws {
        let page = try open(file: "missing.html")
        _ = registry.page(for: page, store: store)
        try await waitFor("failed") { self.current?.loadState == .failed }
        XCTAssertNotNil(current?.loadError)
    }

    func testAUrlPageLoadsOverPlainHttpOnEveryLoopbackName() async throws {
        let v4 = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>v4</title>")])
        let v6 = try await serve(.ipv6(.loopback), ["/": .init(body: "<title>v6</title>")])
        for (address, title) in [("http://127.0.0.1:\(v4)/", "v4"), ("http://localhost:\(v4)/", "v4"), ("http://[::1]:\(v6)/", "v6")] {
            _ = registry.page(for: try openURL(address), store: store)
            try await waitFor("\(address) loaded") { self.current?.loadState == .loaded && self.current?.current?.title == title }
            XCTAssertTrue(store.closeOverlay(session.id))
        }
    }

    func testASameOriginRedirectLoadsAndACrossOriginOneFailsTheOpen() async throws {
        let port = try await serve(.ipv4(.loopback), [
            "/start": .init(status: 302, headers: ["Location": "/landed"]),
            "/landed": .init(body: "<title>landed</title>"),
            "/away": .init(status: 302, headers: ["Location": "http://example.invalid/"]),
        ])
        _ = registry.page(for: try openURL("http://127.0.0.1:\(port)/start"), store: store)
        try await waitFor("redirect followed") { self.current?.current?.title == "landed" && self.current?.loadState == .loaded }
        XCTAssertTrue(store.closeOverlay(session.id))

        _ = registry.page(for: try openURL("http://127.0.0.1:\(port)/away"), store: store)
        try await waitFor("blocked redirect failed") { self.current?.loadState == .failed }
        XCTAssertEqual(current?.loadError, "navigation blocked: http://example.invalid/")
    }

    func testAReloadRedirectedOffOriginFailsInsteadOfStayingLoading() async throws {
        let server = try LoopbackServer(.ipv4(.loopback), routes: ["/": .init(body: "<title>first</title>")])
        servers.append(server)
        let port = try await server.start()
        let page = try openURL("http://127.0.0.1:\(port)/")
        _ = registry.page(for: page, store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "first" }

        server.set("/", .init(status: 302, headers: ["Location": "http://example.invalid/"]))
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitFor("reload failed") { self.current?.loadState == .failed }
        XCTAssertEqual(current?.loadError, "navigation blocked: http://example.invalid/")
    }

    func testABlockedNavigationLeavesALoadedPageLoaded() async throws {
        let page = try open(grant: pages.path)
        let live = registry.page(for: page, store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "script ran" }
        _ = try await live.webView.evaluateJavaScript("location.href = 'https://example.com/'")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(current?.loadState, .loaded)
        XCTAssertNil(current?.loadError)
    }

    func testAPageStartedNavigationRedirectedOffOriginFails() async throws {
        let port = try await serve(.ipv4(.loopback), [
            "/": .init(body: "<title>home</title>"),
            "/hop": .init(status: 302, headers: ["Location": "http://example.invalid/"]),
        ])
        let live = registry.page(for: try openURL("http://127.0.0.1:\(port)/"), store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "home" }
        _ = try await live.webView.evaluateJavaScript("location.href = '/hop'")
        try await waitFor("hop failed") { self.current?.loadState == .failed }
        XCTAssertEqual(current?.loadError, "navigation blocked: http://example.invalid/")
    }

    func testACurrentReloadAfterAFailedFirstLoadLoadsTheSource() async throws {
        let server = try LoopbackServer(.ipv4(.loopback), routes: ["/": .init(status: 302, headers: ["Location": "http://example.invalid/"])])
        servers.append(server)
        let port = try await server.start()
        let page = try openURL("http://127.0.0.1:\(port)/")
        _ = registry.page(for: page, store: store)
        try await waitFor("first load failed") { self.current?.loadState == .failed }

        server.set("/", .init(body: "<title>recovered</title>"))
        XCTAssertNil(registry.reload(page.id, target: .current, store: store))
        try await waitFor("recovered") { self.current?.loadState == .loaded && self.current?.current?.title == "recovered" }
    }

    func testAFirstLoadWebKitCannotDisplayFails() async throws {
        let port = try await serve(.ipv4(.loopback), ["/build.zip": .init(headers: ["Content-Type": "application/octet-stream"], body: "PK")])
        _ = registry.page(for: try openURL("http://127.0.0.1:\(port)/build.zip"), store: store)
        try await waitFor("failed") { self.current?.loadState == .failed }
        XCTAssertNotNil(current?.loadError)
    }

    func testAnUndisplayableNavigationLeavesALoadedPageLoaded() async throws {
        let port = try await serve(.ipv4(.loopback), [
            "/": .init(body: "<title>home</title>"),
            "/build.zip": .init(headers: ["Content-Type": "application/octet-stream"], body: "PK"),
        ])
        let live = registry.page(for: try openURL("http://127.0.0.1:\(port)/"), store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "home" }
        _ = try await live.webView.evaluateJavaScript("location.href = '/build.zip'")
        try await Task.sleep(for: .milliseconds(300))
        try await waitFor("back to loaded") { self.current?.loadState == .loaded }
        XCTAssertNil(current?.loadError)
        XCTAssertEqual(current?.current?.title, "home")
    }

    func testAReloadWebKitCannotDisplayKeepsTheShownPage() async throws {
        let server = try LoopbackServer(.ipv4(.loopback), routes: ["/": .init(body: "<title>home</title>")])
        servers.append(server)
        let port = try await server.start()
        let page = try openURL("http://127.0.0.1:\(port)/")
        _ = registry.page(for: page, store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "home" }

        server.set("/", .init(headers: ["Content-Type": "application/octet-stream"], body: "PK"))
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await Task.sleep(for: .milliseconds(300))
        try await waitFor("back to the shown page") { self.current?.loadState == .loaded && self.current?.current?.title == "home" }
        XCTAssertNil(current?.loadError)
        XCTAssertEqual(current?.current?.page, "http://127.0.0.1:\(port)/")
    }

    func testARefusedConnectionFails() async throws {
        let server = try LoopbackServer(.ipv4(.loopback), routes: [:])
        let port = try await server.start()
        server.stop()
        _ = registry.page(for: try openURL("http://127.0.0.1:\(port)/"), store: store)
        try await waitFor("failed") { self.current?.loadState == .failed }
        XCTAssertNotNil(current?.loadError)
    }

    func testCurrentReloadStaysOnTheNavigatedPageAndOriginalReturnsToTheUrl() async throws {
        let port = try await serve(.ipv4(.loopback), ["/a": .init(body: "<title>a</title>"), "/b": .init(body: "<title>b</title>")])
        let page = try openURL("http://127.0.0.1:\(port)/a")
        let live = registry.page(for: page, store: store)
        try await waitFor("a loaded") { self.current?.current?.title == "a" && self.current?.loadState == .loaded }
        _ = try await live.webView.evaluateJavaScript("location.href = '/b'")
        try await waitFor("b loaded") { self.current?.current?.title == "b" && self.current?.loadState == .loaded }

        XCTAssertNil(registry.reload(page.id, target: .current, store: store))
        try await waitFor("b reloaded") { self.current?.loadState == .loaded && self.current?.current?.page.hasSuffix("/b") == true }
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitFor("a again") { self.current?.current?.title == "a" && self.current?.loadState == .loaded }
    }

    func testBrowserStorageLastsThroughAReloadButNotIntoTheNextOverlay() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>store</title>")])
        let address = "http://127.0.0.1:\(port)/"
        let page = try openURL(address)
        let live = registry.page(for: page, store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "store" }
        _ = try await live.webView.evaluateJavaScript("localStorage.setItem('k', 'v'); document.cookie = 'c=1'")
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitFor("reloaded") { self.current?.loadState == .loaded }
        let kept = try await live.webView.evaluateJavaScript("localStorage.getItem('k') + '|' + document.cookie")
        XCTAssertEqual(kept as? String, "v|c=1")
        XCTAssertTrue(store.closeOverlay(session.id))

        let next = registry.page(for: try openURL(address), store: store)
        try await waitFor("next loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "store" }
        let fresh = try await next.webView.evaluateJavaScript("localStorage.getItem('k') + '|' + document.cookie")
        XCTAssertEqual(fresh as? String, "null|")
    }

    func testTheAppReadsSixteenPaletteColorsFromTheTheme() {
        let palette = GhosttyApp.shared.terminalPalette
        XCTAssertEqual(palette.count, 16)
        XCTAssertTrue(palette.allSatisfy { WatermarkConfig.isValidColorHex($0) }, "\(palette)")
    }

    func testAFilePageGetsThePaletteAndFollowsAThemeChange() async throws {
        try write("plain.html", "<title>P</title><p>short</p>")
        let page = registry.page(for: try open(file: "plain.html"), store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded }
        let initial = try await variable("--agterm-color-1", in: page.webView)
        XCTAssertEqual(initial, GhosttyApp.shared.terminalPalette[1])

        let palette = (0..<16).map { String(format: "#%02x%02x%02x", $0, 0x40, 0x80) }
        page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true, palette: palette))
        try await waitForVariable("--agterm-color-1", "#014080", in: page.webView)
        let background = try await variable("--agterm-background", in: page.webView)
        XCTAssertEqual(background, "#000000")
    }

    func testAUrlPageKeepsTheBrowserCanvasThroughAThemeChange() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>app</title><body style=\"color: #333\"><p>app text</p></body>")])
        let page = registry.page(for: try openURL("http://127.0.0.1:\(port)/"), store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "app" }

        let before = try await bottomPixel(page.webView)
        XCTAssertEqual(before.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(before.redComponent, 1, accuracy: 0.02, "a url page must keep the browser's white canvas: \(before)")
        let initial = try await variable("--agterm-background", in: page.webView)
        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))
        let kept = try await variable("--agterm-background", in: page.webView)
        XCTAssertEqual(kept, initial, "a url page takes a theme change only at its next load")
        XCTAssertNil(registry.reload(page.id, target: .current, store: store))
        try await waitForVariable("--agterm-background", "#101010", in: page.webView)
        let scheme = try await page.webView.evaluateJavaScript("getComputedStyle(document.documentElement).colorScheme")
        XCTAssertEqual(scheme as? String, "normal")
        let after = try await bottomPixel(page.webView)
        XCTAssertEqual(after.redComponent, 1, accuracy: 0.02, "a theme change must not darken a url page: \(after)")
    }

    func testAPageClickingLinksInALoopOpensOnlyWhatTheUserApproves() async throws {
        try write("loop.html", #"<title>L</title><a id="x" href="https://example.com/x">x</a>"#
            + "<script>setInterval(() => document.getElementById('x').click(), 20)</script>")
        let page = registry.page(for: try open(file: "loop.html"), store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        let target = try XCTUnwrap(URL(string: "https://example.com/x"))

        try await waitFor("first prompt") { self.browser.prompts.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(browser.prompts.count, 1, "requests while a prompt is up are dropped")
        browser.answers[0](true)
        XCTAssertEqual(browser.opened, [target])

        try await waitFor("second prompt") { self.browser.prompts.count == 2 }
        browser.answers[1](false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(browser.prompts.count, 2, "a declined page asks nothing more")

        page.webView.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)))
        try await waitFor("asked again after real input") { self.browser.prompts.count == 3 }
        XCTAssertEqual(browser.prompts, [target, target, target])

        XCTAssertTrue(store.closeOverlay(session.id))
        XCTAssertEqual(browser.dismissals, 1)
        browser.answers[2](true)
        XCTAssertEqual(browser.opened, [target], "an answer after close opens nothing")
    }

    func testAPageOutOfSightAsksNothingAndLosesItsPrompt() async throws {
        try write("link.html", #"<title>L</title><a id="x" href="https://example.com/x">x</a>"#)
        let page = registry.page(for: try open(file: "link.html"), store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded }
        _ = try await page.webView.evaluateJavaScript("document.getElementById('x').click()")
        try await waitFor("prompt") { self.browser.prompts.count == 1 }

        page.setOnScreen(false)
        XCTAssertEqual(browser.dismissals, 1)
        browser.answers[0](true)
        XCTAssertEqual(browser.opened, [])
        _ = try await page.webView.evaluateJavaScript("document.getElementById('x').click()")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(browser.prompts.count, 1)
    }

    func testOpenInBrowserOpensTheOriginalFileAndFailsWithoutABrowser() async throws {
        let page = try open(grant: pages.path)
        let live = registry.page(for: page, store: store)
        try await waitFor("a loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "script ran" }
        _ = try await live.webView.evaluateJavaScript("location.href = 'b.html'")
        try await waitFor("b loaded") { self.current?.current?.title == "B" }

        XCTAssertNil(registry.navigate(page.id, .browser))
        XCTAssertEqual(browser.opened, [pages.appendingPathComponent("a.html")])
        XCTAssertEqual(browser.prompts, [])
        browser.available = false
        XCTAssertEqual(registry.navigate(page.id, .browser), OverlayHtmlError.noBrowser)
    }

    func testOpenInBrowserOpensTheUrlPageShown() async throws {
        let port = try await serve(.ipv4(.loopback), ["/a": .init(body: "<title>a</title>"), "/b?q=1": .init(body: "<title>b</title>")])
        let page = try openURL("http://127.0.0.1:\(port)/a")
        let live = registry.page(for: page, store: store)
        try await waitFor("a loaded") { self.current?.current?.title == "a" && self.current?.loadState == .loaded }
        _ = try await live.webView.evaluateJavaScript("location.href = '/b?q=1'")
        try await waitFor("b loaded") { self.current?.current?.title == "b" && self.current?.loadState == .loaded }

        XCTAssertNil(registry.navigate(page.id, .browser))
        XCTAssertEqual(browser.opened, [try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/b?q=1"))])
    }

    func testNavigatingAPageThatWasNeverShownIsRefused() {
        XCTAssertEqual(registry.navigate(UUID(), .back), OverlayHtmlError.notRealized)
    }

    private var current: HtmlOverlay? { session.htmlOverlay ?? session.paneOverlay(.left)?.html }

    private func snapshotPixel(file: String) async throws -> NSColor {
        let page = registry.page(for: try open(file: file), store: store)
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitFor("\(file) loaded") { self.current?.loadState == .loaded }
        return try await bottomPixel(page.webView)
    }

    private func host(_ view: NSView) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = try XCTUnwrap(window.contentView).bounds
        window.contentView?.addSubview(view)
        return window
    }

    private func bottomPixel(_ view: WKWebView) async throws -> NSColor {
        let image = try await view.takeSnapshot(configuration: nil)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep
            ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 10))
        return color.usingColorSpace(.sRGB) ?? color
    }

    private func variable(_ name: String, in view: WKWebView) async throws -> String? {
        let value = try await view.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('\(name)').trim()")
        return value as? String
    }

    private func waitForVariable(_ name: String, _ expected: String, in view: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try await variable(name, in: view) != expected {
            guard Date() < deadline else { return XCTFail("\(name) never became \(expected)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func write(_ name: String, _ body: String) throws {
        try "<!doctype html><html><body>\(body)</body></html>"
            .write(to: pages.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func open(pane: OverlayPane? = nil, file: String = "a.html", grant: String? = nil) throws -> HtmlOverlay {
        let overlay = HtmlOverlay(source: .file(path: pages.appendingPathComponent(file).path, grantRoot: grant))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: pane, overlay: overlay, sizePercent: nil))
        return overlay
    }

    private func openURL(_ address: String) throws -> HtmlOverlay {
        let overlay = HtmlOverlay(source: .url(try XCTUnwrap(URL(string: address))))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }

    private func serve(_ host: NWEndpoint.Host, _ routes: [String: LoopbackServer.Response]) async throws -> UInt16 {
        let server = try LoopbackServer(host, routes: routes)
        servers.append(server)
        return try await server.start()
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("\(what) not reached within \(timeout)s: \(String(describing: current))")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
