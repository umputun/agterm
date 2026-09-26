import Network
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

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-html-reg-\(UUID().uuidString)")
        pages = directory.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        store = AppStore(persistence: PersistenceStore(directory: directory.appendingPathComponent("state")))
        let workspace = store.addWorkspace(name: "work")
        session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        registry.install()
        try write("a.html", #"<title>A</title><script src="s.js"></script><a href="b.html">b</a>"#)
        try write("b.html", "<title>B</title>")
        try "document.title = 'script ran'".write(to: pages.appendingPathComponent("s.js"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        servers.forEach { $0.stop() }
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

    func testAThemeChangeRestylesAnOpenPage() async throws {
        try write("plain.html", "<title>P</title><p>short</p>")
        let page = registry.page(for: try open(file: "plain.html"), store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded }
        page.applyTheme(HtmlOverlayTheme(background: "#000000", foreground: "#102030", dark: true))
        let color = try await page.webView.evaluateJavaScript("getComputedStyle(document.documentElement).color")
        XCTAssertEqual(color as? String, "rgb(16, 32, 48)")
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

    func testNavigatingAPageThatWasNeverShownIsRefused() {
        XCTAssertEqual(registry.navigate(UUID(), .back), OverlayHtmlError.notRealized)
    }

    private var current: HtmlOverlay? { session.htmlOverlay ?? session.paneOverlay(.left)?.html }

    private func snapshotPixel(file: String) async throws -> NSColor {
        let page = registry.page(for: try open(file: file), store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        page.webView.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(page.webView)
        try await waitFor("\(file) loaded") { self.current?.loadState == .loaded }
        let image = try await page.webView.takeSnapshot(configuration: nil)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep
            ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)))
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 10))
        return color.usingColorSpace(.sRGB) ?? color
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
