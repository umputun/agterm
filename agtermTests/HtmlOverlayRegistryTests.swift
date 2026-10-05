import Network
import SwiftUI
import WebKit
import XCTest
@testable import agterm
import agtermCore

private final class LoopbackServer: @unchecked Sendable {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
        var hold = false
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "agterm.test.loopback")
    private var routes: [String: Response]
    private var held: [NWConnection] = []

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
            if response.hold { return held.append(connection) }
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
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint

    init(_ pasteboard: NSPasteboard, over view: NSView) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = view.window
        draggingLocation = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to _: NSPoint) {}
    func enumerateDraggingItems(options _: NSDraggingItemEnumerationOptions = [], for _: NSView?, classes _: [AnyClass],
                                searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor @Observable
private final class Mount {
    var shown = true
}

private struct MountedPage: View {
    let mount: Mount
    let store: AppStore
    let session: Session
    let overlay: HtmlOverlay

    var body: some View {
        if mount.shown {
            HtmlWebViewHost(store: store, session: session, overlay: overlay, backgroundColor: nil, isActive: false, visible: true)
        }
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
private final class FakeSharing: HtmlSharing {
    var revealed: [URL] = []
    var copied: [String] = []

    func reveal(_ url: URL) { revealed.append(url) }
    func copy(_ text: String) { copied.append(text) }
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
    private var profiles: [BrowserProfile] = []
    private var removal: (@MainActor (WKWebsiteDataStore) async -> Void)!
    private var store: AppStore!
    private var session: Session!
    private let registry = HtmlOverlayRegistry.shared
    private let browser = FakeBrowser()
    private let sharing = FakeSharing()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-html-reg-\(UUID().uuidString)")
        pages = directory.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        store = AppStore(persistence: PersistenceStore(directory: directory.appendingPathComponent("state")))
        let workspace = store.addWorkspace(name: "work")
        session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        registry.install()
        registry.browser = browser
        registry.sharing = sharing
        removal = registry.removeWebsiteData
        useProfile("profile")
        try write("a.html", #"<title>A</title><script src="s.js"></script><a href="b.html">b</a>"#)
        try write("b.html", "<title>B</title>")
        try "document.title = 'script ran'".write(to: pages.appendingPathComponent("s.js"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        servers.forEach { $0.stop() }
        registry.browser = SystemBrowser()
        registry.sharing = SystemHtmlSharing()
        registry.setZoom(1)
        registry.dispatch = nil
        store.closeSession(session.id)
        registry.removeWebsiteData = removal
        for profile in profiles { try await TestBrowserStore.remove(profile) }
        profiles = []
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
        let page = try open(grant: pages.path, javascript: true)
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

    func testAnOffScreenPageLeavesTheDropToTheViewBeneathIt() throws {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let content = NSView(frame: frame)
        window.contentView = content
        let beneath = NSView(frame: content.bounds)
        beneath.registerForDraggedTypes([.fileURL])
        content.addSubview(beneath)
        XCTAssertTrue(try dropTarget(in: content) === beneath)

        let view = registry.page(for: try open(), store: store).webView
        view.frame = content.bounds
        content.addSubview(view)
        XCTAssertTrue(try dropTarget(in: content) === view)

        view.setDropsEnabled(false)
        XCTAssertTrue(view.registeredDraggedTypes.isEmpty)
        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(try dropTarget(in: content) === beneath)

        view.setDropsEnabled(true)
        XCTAssertTrue(try dropTarget(in: content) === view)
        view.setDropsEnabled(false)
        XCTAssertTrue(try dropTarget(in: content) === beneath)
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
        let page = registry.page(for: try open(grant: pages.path, javascript: true), store: store)
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
            let page = registry.page(for: try open(file: "hostile.html", grant: grant, javascript: true), store: store)
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
        let page = try open(javascript: true)
        _ = registry.page(for: page, store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title != nil }
        XCTAssertEqual(current?.current?.title, "A")
    }

    func testAFolderGrantKeepsFilesOutsideItOut() async throws {
        try "document.title = 'outside ran'".write(to: directory.appendingPathComponent("outside.js"), atomically: true, encoding: .utf8)
        try write("c.html", #"<title>C</title><script src="../outside.js"></script>"#)
        let page = try open(file: "c.html", grant: pages.path, javascript: true)
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
        let page = try open(grant: pages.path, javascript: true)
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

    func testABrowsingPageFollowsARedirectToAnotherOriginAndNamesIt() async throws {
        let second = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>second</title>")])
        let first = try await serve(.ipv4(.loopback), [
            "/away": .init(status: 302, headers: ["Location": "http://127.0.0.1:\(second)/"]),
        ])
        _ = registry.page(for: try openURL("http://127.0.0.1:\(first)/away", browse: true), store: store)
        try await waitFor("redirect followed") { self.current?.current?.title == "second" && self.current?.loadState == .loaded }
        XCTAssertEqual(current?.identity, "http://127.0.0.1:\(second)")
        XCTAssertTrue(store.closeOverlay(session.id))

        _ = registry.page(for: try openURL("http://127.0.0.1:\(first)/away"), store: store)
        try await waitFor("ordinary page blocked") { self.current?.loadState == .failed }
        XCTAssertEqual(current?.loadError, "navigation blocked: http://127.0.0.1:\(second)/")
    }

    func testABrowsingPageNamesTheSiteShownThroughNavigationAndBack() async throws {
        let first = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>first</title>")])
        let second = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>second</title>")])
        let page = try openURL("http://127.0.0.1:\(first)/", browse: true)
        let live = registry.page(for: page, store: store)
        try await waitFor("first loaded") { self.current?.current?.title == "first" && self.current?.loadState == .loaded }
        XCTAssertEqual(current?.identity, "http://127.0.0.1:\(first)")

        _ = try await live.webView.evaluateJavaScript("location.href = 'http://127.0.0.1:\(second)/'")
        try await waitFor("second loaded") { self.current?.current?.title == "second" && self.current?.loadState == .loaded }
        XCTAssertEqual(current?.identity, "http://127.0.0.1:\(second)")

        XCTAssertNil(registry.navigate(page.id, .back))
        try await waitFor("back on first") { self.current?.current?.title == "first" }
        XCTAssertEqual(current?.identity, "http://127.0.0.1:\(first)")
    }

    func testABrowsingPageKeepsNamingTheShownSiteWhileAnotherSiteLoads() async throws {
        let first = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>first</title>")])
        let slow = try await serve(.ipv4(.loopback), ["/": .init(hold: true)])
        let live = registry.page(for: try openURL("http://127.0.0.1:\(first)/", browse: true), store: store)
        try await waitFor("first loaded") { self.current?.current?.title == "first" && self.current?.loadState == .loaded }

        _ = try await live.webView.evaluateJavaScript("location.href = 'http://127.0.0.1:\(slow)/'")
        try await waitFor("second site loading") { self.current?.loadState == .loading }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(current?.identity, "http://127.0.0.1:\(first)")
        XCTAssertEqual(current?.current?.page, "http://127.0.0.1:\(first)/")
    }

    func testABrowsingPageSentBackToItsSourceNamesTheShownSiteUntilTheSourceCommits() async throws {
        let server = try LoopbackServer(.ipv4(.loopback), routes: ["/": .init(body: "<title>first</title>")])
        servers.append(server)
        let first = try await server.start()
        let second = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>second</title>")])
        let page = try openURL("http://127.0.0.1:\(first)/", browse: true)
        let live = registry.page(for: page, store: store)
        try await waitFor("first loaded") { self.current?.current?.title == "first" && self.current?.loadState == .loaded }
        _ = try await live.webView.evaluateJavaScript("location.href = 'http://127.0.0.1:\(second)/'")
        try await waitFor("second loaded") { self.current?.current?.title == "second" && self.current?.loadState == .loaded }

        server.set("/", .init(hold: true))
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitFor("source loading") { self.current?.loadState == .loading }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(current?.identity, "http://127.0.0.1:\(second)")
    }

    func testABrowsingPageNamesItsSourceWhileItsFirstLoadRedirectsToASiteStillLoading() async throws {
        let slow = try await serve(.ipv4(.loopback), ["/": .init(hold: true)])
        let first = try await serve(.ipv4(.loopback), [
            "/away": .init(status: 302, headers: ["Location": "http://127.0.0.1:\(slow)/"]),
        ])
        let live = registry.page(for: try openURL("http://127.0.0.1:\(first)/away", browse: true), store: store)
        try await waitFor("redirect pending on the slow site") { live.webView.url?.port == Int(slow) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(current?.loadState, .loading)
        XCTAssertEqual(current?.identity, "http://127.0.0.1:\(first)")
    }

    func testABrowsingPageOpensAndCopiesTheSiteShownWhileAnotherLoads() async throws {
        let first = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>first</title>")])
        let slow = try await serve(.ipv4(.loopback), ["/": .init(hold: true)])
        let page = try openURL("http://127.0.0.1:\(first)/", browse: true)
        let live = registry.page(for: page, store: store)
        try await waitFor("first loaded") { self.current?.current?.title == "first" && self.current?.loadState == .loaded }
        _ = try await live.webView.evaluateJavaScript("location.href = 'http://127.0.0.1:\(slow)/'")
        try await waitFor("second site pending") { live.webView.url?.port == Int(slow) }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(registry.navigate(page.id, .browser))
        registry.copyLink(page.id)

        XCTAssertEqual(browser.opened, [try XCTUnwrap(URL(string: "http://127.0.0.1:\(first)/"))])
        XCTAssertEqual(sharing.copied, ["http://127.0.0.1:\(first)/"])
    }

    func testABrowsingPageOnABlankDocumentOpensItsSourceInTheBrowser() async throws {
        let first = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>first</title>")])
        let page = try openURL("http://127.0.0.1:\(first)/", browse: true)
        let live = registry.page(for: page, store: store)
        try await waitFor("first loaded") { self.current?.current?.title == "first" && self.current?.loadState == .loaded }
        _ = try await live.webView.evaluateJavaScript("location.href = 'about:blank'")
        try await waitFor("blank shown") { self.current?.current?.page == "about:blank" }

        XCTAssertNil(registry.navigate(page.id, .browser))

        XCTAssertEqual(browser.opened, [try XCTUnwrap(URL(string: "http://127.0.0.1:\(first)/"))])
    }

    func testABrowsingPageNamesABlankDocumentAsBlank() async throws {
        let first = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>first</title>")])
        let live = registry.page(for: try openURL("http://127.0.0.1:\(first)/", browse: true), store: store)
        try await waitFor("first loaded") { self.current?.current?.title == "first" && self.current?.loadState == .loaded }

        _ = try await live.webView.evaluateJavaScript("location.href = 'about:blank'")
        try await waitFor("blank shown") { self.current?.current?.page == "about:blank" }
        XCTAssertEqual(current?.identity, "about:blank")
    }

    func testABrowsingPageKeepsNamingTheShownSiteWhenALoadElsewhereFails() async throws {
        let first = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>first</title>")])
        let closed = try LoopbackServer(.ipv4(.loopback), routes: [:])
        let dead = try await closed.start()
        closed.stop()
        let live = registry.page(for: try openURL("http://127.0.0.1:\(first)/", browse: true), store: store)
        try await waitFor("first loaded") { self.current?.current?.title == "first" && self.current?.loadState == .loaded }

        _ = try await live.webView.evaluateJavaScript("location.href = 'http://127.0.0.1:\(dead)/'")
        try await waitFor("load elsewhere failed") { self.current?.loadState == .failed }
        XCTAssertEqual(current?.identity, "http://127.0.0.1:\(first)")
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

    func testPersistentStorageOutlivesItsOverlay() async throws {
        let port = try await serve(.ipv4(.loopback), [
            "/set": .init(headers: ["Set-Cookie": "s=1; Max-Age=3600; Path=/"], body: "<title>set</title>"),
            "/": .init(body: "<title>store</title>"),
        ])
        let first = registry.page(for: try openURL("http://127.0.0.1:\(port)/set", persistent: true), store: store)
        try await waitFor("set loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "set" }
        _ = try await first.webView.evaluateJavaScript("localStorage.setItem('k', 'v')")
        _ = try await first.webView.callAsyncJavaScript(Self.putRecord, contentWorld: .page)
        XCTAssertTrue(store.closeOverlay(session.id))

        let next = registry.page(for: try openURL("http://127.0.0.1:\(port)/", persistent: true), store: store)
        try await waitFor("next loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "store" }
        let kept = try await next.webView.evaluateJavaScript("localStorage.getItem('k') + '|' + document.cookie")
        XCTAssertEqual(kept as? String, "v|s=1")
        let record = try await next.webView.callAsyncJavaScript(Self.getRecord, contentWorld: .page)
        XCTAssertEqual(record as? String, "iv")
    }

    func testAnInMemoryPageAndThePersistentStoreNeverSeeEachOther() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>store</title>")])
        let address = "http://127.0.0.1:\(port)/"
        let saved = registry.page(for: try openURL(address, persistent: true), store: store)
        try await waitFor("saved loaded") { self.current?.loadState == .loaded }
        _ = try await saved.webView.evaluateJavaScript("localStorage.setItem('k', 'saved'); document.cookie = 'c=saved; max-age=3600'")
        XCTAssertTrue(store.closeOverlay(session.id))

        let memory = registry.page(for: try openURL(address), store: store)
        try await waitFor("memory loaded") { self.current?.loadState == .loaded }
        let unseen = try await memory.webView.evaluateJavaScript("localStorage.getItem('k') + '|' + document.cookie")
        XCTAssertEqual(unseen as? String, "null|")
        _ = try await memory.webView.evaluateJavaScript("localStorage.setItem('k', 'memory'); document.cookie = 'c=memory; max-age=3600'")
        XCTAssertTrue(store.closeOverlay(session.id))

        let again = registry.page(for: try openURL(address, persistent: true), store: store)
        try await waitFor("again loaded") { self.current?.loadState == .loaded }
        let kept = try await again.webView.evaluateJavaScript("localStorage.getItem('k') + '|' + document.cookie")
        XCTAssertEqual(kept as? String, "saved|c=saved")
    }

    func testTwoPersistentPagesOpenAtOnceShareTheStore() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>store</title>")])
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        let one = registry.page(for: try openURL(url.absoluteString, persistent: true), store: store)
        let beside = HtmlOverlay(source: .url(url), persistent: true)
        let two = registry.page(for: beside, store: store)
        defer { registry.release(beside.id) }
        try await waitFor("both loaded") { self.current?.loadState == .loaded && !two.webView.isLoading && two.webView.url != nil }

        _ = try await one.webView.evaluateJavaScript("localStorage.setItem('k', 'shared'); document.cookie = 'c=shared; max-age=3600'")

        // a write reaches the other page's process a moment after the call that made it returns
        let deadline = Date().addingTimeInterval(10)
        var seen: String?
        while seen != "shared|c=shared", Date() < deadline {
            seen = try await two.webView.evaluateJavaScript("localStorage.getItem('k') + '|' + document.cookie") as? String
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(seen, "shared|c=shared")
    }

    func testTwoProfilesDoNotShareAStore() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>store</title>")])
        let address = "http://127.0.0.1:\(port)/"
        let first = registry.page(for: try openURL(address, persistent: true), store: store)
        try await waitFor("first loaded") { self.current?.loadState == .loaded }
        _ = try await first.webView.evaluateJavaScript("localStorage.setItem('k', 'v'); document.cookie = 'c=1; max-age=3600'")
        XCTAssertTrue(store.closeOverlay(session.id))

        useProfile("other")
        let other = registry.page(for: try openURL(address, persistent: true), store: store)
        try await waitFor("other loaded") { self.current?.loadState == .loaded }
        let unseen = try await other.webView.evaluateJavaScript("localStorage.getItem('k') + '|' + document.cookie")
        XCTAssertEqual(unseen as? String, "null|")
    }

    func testAPersistentPageWithoutAReadableProfileFailsAndLoadsNothing() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>store</title>")])
        let state = directory.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let file = state.appendingPathComponent("browser-profile")
        try Data("not a uuid".utf8).write(to: file)
        registry.profile = BrowserProfile(directory: state)
        let failure = BrowserProfile.Failure.malformed(file.path).description
        XCTAssertEqual(registry.persistentStoreFailure(), failure)

        let page = registry.page(for: try openURL("http://127.0.0.1:\(port)/", persistent: true), store: store)

        XCTAssertEqual(current?.loadState, .failed)
        XCTAssertEqual(current?.loadError, failure)
        XCTAssertNil(page.webView.url)
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        page.apply(try XCTUnwrap(current))
        XCTAssertEqual(current?.loadState, .failed)
        XCTAssertNil(page.webView.url)
        XCTAssertEqual(try Data(contentsOf: file), Data("not a uuid".utf8))
    }

    func testClearEmptiesTheSavedStoreAndKeepsItsProfile() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>store</title>")])
        let address = "http://127.0.0.1:\(port)/"
        let first = registry.page(for: try openURL(address, persistent: true), store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded }
        _ = try await first.webView.evaluateJavaScript("localStorage.setItem('k', 'v'); document.cookie = 'c=1; max-age=3600'")
        _ = try await first.webView.callAsyncJavaScript(Self.putRecord, contentWorld: .page)
        XCTAssertTrue(store.closeOverlay(session.id))
        let profile = try XCTUnwrap(registry.profile)
        let id = try profile.existingIdentifier()

        let failure = await registry.clearPersistentStore()

        XCTAssertNil(failure)
        XCTAssertEqual(try profile.existingIdentifier(), id)
        let next = registry.page(for: try openURL(address, persistent: true), store: store)
        try await waitFor("next loaded") { self.current?.loadState == .loaded }
        let left = try await next.webView.evaluateJavaScript("localStorage.getItem('k') + '|' + document.cookie")
        XCTAssertEqual(left as? String, "null|")
        let record = try await next.webView.callAsyncJavaScript(Self.getRecord, contentWorld: .page)
        XCTAssertNil(record as? String)
    }

    func testClearIsRefusedWhileAPersistentPageIsOpenOrSoftClosed() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>store</title>")])
        let address = "http://127.0.0.1:\(port)/"
        let page = registry.page(for: try openURL(address, persistent: true), store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded }
        _ = try await page.webView.evaluateJavaScript("localStorage.setItem('k', 'v')")

        let open = await registry.clearPersistentStore()
        XCTAssertEqual(open, BrowserClearError.pagesOpen(1))

        XCTAssertTrue(store.softCloseSession(session.id, grace: 60))
        let softClosed = await registry.clearPersistentStore()
        XCTAssertEqual(softClosed, BrowserClearError.pagesOpen(1))
        let kept = try await page.webView.evaluateJavaScript("localStorage.getItem('k')")
        XCTAssertEqual(kept as? String, "v")

        store.finalizeAllPendingCloses()
        let closed = await registry.clearPersistentStore()
        XCTAssertNil(closed)
    }

    func testAnInMemoryPageDoesNotBlockAClear() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>store</title>")])
        _ = registry.page(for: try openURL("http://127.0.0.1:\(port)/"), store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded }
        XCTAssertNil(registry.persistentStoreFailure())

        let failure = await registry.clearPersistentStore()

        XCTAssertNil(failure)
    }

    func testClearWithNoProfileEverCreatedSucceedsAndCreatesNone() async throws {
        let profile = try XCTUnwrap(registry.profile)
        var removed = false
        registry.removeWebsiteData = { _ in removed = true }

        let failure = await registry.clearPersistentStore()

        XCTAssertNil(failure)
        XCTAssertFalse(removed)
        XCTAssertNil(try profile.existingIdentifier())
    }

    func testClearOfAnUnreadableProfileFailsAndRemovesNothing() async throws {
        let state = directory.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let file = state.appendingPathComponent("browser-profile")
        try Data("not a uuid".utf8).write(to: file)
        registry.profile = BrowserProfile(directory: state)
        var removed = false
        registry.removeWebsiteData = { _ in removed = true }

        let failure = await registry.clearPersistentStore()

        XCTAssertEqual(failure, BrowserProfile.Failure.malformed(file.path).description)
        XCTAssertFalse(removed)
    }

    func testAPersistentOpenIsRefusedUntilARunningClearCompletes() async throws {
        XCTAssertNil(registry.persistentStoreFailure())
        let started = expectation(description: "removal started")
        var finish: CheckedContinuation<Void, Never>?
        registry.removeWebsiteData = { _ in
            await withCheckedContinuation { continuation in
                finish = continuation
                started.fulfill()
            }
        }
        let clear = Task { await self.registry.clearPersistentStore() }
        await fulfillment(of: [started], timeout: 5)

        XCTAssertEqual(registry.persistentStoreFailure(), BrowserClearError.clearing)
        let second = await registry.clearPersistentStore()
        XCTAssertEqual(second, BrowserClearError.clearing)
        let page = registry.page(for: try openURL("http://127.0.0.1:1/", persistent: true), store: store)
        XCTAssertEqual(current?.loadState, .failed)
        XCTAssertEqual(current?.loadError, BrowserClearError.clearing)
        XCTAssertFalse(page.usesSavedStore)
        XCTAssertNil(page.webView.url)

        finish?.resume()
        let failure = await clear.value
        XCTAssertNil(failure)
        XCTAssertNil(registry.persistentStoreFailure())
    }

    func testAnInMemoryPageNeedsNoProfile() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>store</title>")])
        registry.profile = nil

        _ = registry.page(for: try openURL("http://127.0.0.1:\(port)/"), store: store)

        try await waitFor("loaded") { self.current?.loadState == .loaded }
        XCTAssertEqual(registry.persistentStoreFailure(), OverlayHtmlError.persistentUnavailable)
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
        let page = registry.page(for: try open(file: "loop.html", javascript: true), store: store)
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

    func testUnmountingThePageEndsItsPromptAndARemountAsksAgain() async throws {
        try write("link.html", #"<title>L</title><a id="x" href="https://example.com/x">x</a>"#)
        let overlay = try open(file: "link.html")
        let mount = Mount()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MountedPage(mount: mount, store: store, session: session, overlay: overlay))
        defer { window.orderOut(nil) }
        try await waitFor("mounted") { self.registry.existing(overlay.id)?.webView.window != nil }
        let page = try XCTUnwrap(registry.existing(overlay.id))
        try await waitFor("loaded") { self.current?.loadState == .loaded }
        _ = try await page.webView.evaluateJavaScript("document.getElementById('x').click()")
        try await waitFor("prompt") { self.browser.prompts.count == 1 }

        mount.shown = false
        try await waitFor("unmounted") { page.webView.window == nil }
        XCTAssertEqual(browser.dismissals, 1)
        browser.answers[0](true)
        XCTAssertEqual(browser.opened, [], "an answer after the page left its window opens nothing")

        mount.shown = true
        try await waitFor("remounted") { page.webView.window != nil }
        XCTAssertTrue(registry.existing(overlay.id) === page)
        _ = try await page.webView.evaluateJavaScript("document.getElementById('x').click()")
        try await waitFor("asked again") { self.browser.prompts.count == 2 }
    }

    func testOpenInBrowserOpensTheOriginalFileAndFailsWithoutABrowser() async throws {
        let page = try open(grant: pages.path, javascript: true)
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

    func testFinderRevealsTheCurrentFileWithoutNavigationButtons() async throws {
        let page = try open(grant: pages.path)
        let live = registry.page(for: page, store: store)
        try await waitFor("a loaded") { self.current?.loadState == .loaded }
        _ = try await live.webView.evaluateJavaScript("location.href = 'b.html'")
        try await waitFor("b loaded") { self.current?.current?.title == "B" }

        XCTAssertFalse(page.navigation)
        XCTAssertNil(registry.navigate(page.id, .finder))
        XCTAssertEqual(sharing.revealed, [pages.appendingPathComponent("b.html")])
        XCTAssertEqual(sharing.copied, [])
        XCTAssertEqual(browser.opened, [])
    }

    func testFinderRevealsTheOriginalTextLoadedFile() async throws {
        let page = try open()
        let live = registry.page(for: page, store: store)
        try await waitFor("text loaded") { self.current?.loadState == .loaded }

        XCTAssertEqual(live.webView.url?.scheme, "about")
        XCTAssertNil(registry.navigate(page.id, .finder))
        XCTAssertEqual(sharing.revealed, [pages.appendingPathComponent("a.html")])
    }

    func testFinderRevealsTheOriginalFileWhileTheFirstLoadIsPending() throws {
        let page = try open(grant: pages.path)
        _ = registry.page(for: page, store: store)

        XCTAssertNil(registry.navigate(page.id, .finder))
        XCTAssertEqual(sharing.revealed, [pages.appendingPathComponent("a.html")])
    }

    func testFinderRefusesAURLPageWithoutSideEffects() throws {
        let page = try openURL("http://127.0.0.1:1/report")
        _ = registry.page(for: page, store: store)

        XCTAssertEqual(registry.navigate(page.id, .finder), OverlayHtmlError.finderRequiresFile)
        XCTAssertEqual(sharing.revealed, [])
        XCTAssertEqual(sharing.copied, [])
        XCTAssertEqual(browser.opened, [])
    }

    func testCopyLinkCopiesTheCurrentURLWithQueryAndFragment() async throws {
        let port = try await serve(.ipv4(.loopback), ["/a": .init(body: "<title>a</title>"), "/b?q=1": .init(body: "<title>b</title>")])
        let page = try openURL("http://127.0.0.1:\(port)/a")
        let live = registry.page(for: page, store: store)
        try await waitFor("a loaded") { self.current?.loadState == .loaded }
        _ = try await live.webView.evaluateJavaScript("location.href = '/b?q=1#section'")
        let address = "http://127.0.0.1:\(port)/b?q=1#section"
        try await waitFor("b loaded") { self.current?.current?.page == address && self.current?.loadState == .loaded }

        registry.copyLink(page.id)

        XCTAssertEqual(sharing.copied, [address])
        XCTAssertEqual(sharing.revealed, [])
        XCTAssertEqual(browser.opened, [])
    }

    func testCopyLinkCopiesTheOriginalURLWhileTheFirstLoadIsPending() throws {
        let address = "http://127.0.0.1:1/report?q=1#section"
        let page = try openURL(address)
        _ = registry.page(for: page, store: store)

        registry.copyLink(page.id)

        XCTAssertEqual(sharing.copied, [address])
    }

    func testAPageRefusesDraggedFilesAndTakesDraggedText() throws {
        let view = registry.page(for: try open(), store: store).webView
        let window = try host(view)
        defer { window.orderOut(nil) }
        let files = NSPasteboard(name: NSPasteboard.Name("agterm-test-\(UUID().uuidString)"))
        defer { files.releaseGlobally() }
        files.clearContents()
        files.writeObjects([pages.appendingPathComponent("b.html") as NSURL])
        let text = NSPasteboard(name: NSPasteboard.Name("agterm-test-\(UUID().uuidString)"))
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString("plain words", forType: .string)

        XCTAssertEqual(view.draggingEntered(FakeDrag(files, over: view)), [])
        XCTAssertEqual(view.draggingUpdated(FakeDrag(files, over: view)), [])
        XCTAssertFalse(view.performDragOperation(FakeDrag(files, over: view)))
        XCTAssertNotEqual(view.draggingEntered(FakeDrag(text, over: view)), [])
    }

    func testAPageRefusesAPastedFileAndTakesPastedText() async throws {
        try "PASTE-SECRET".write(to: pages.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try write("paste.html", """
            <title>P</title><textarea id="t"></textarea><script>
            document.addEventListener('paste', e => {
              const d = e.clipboardData;
              webkit.messageHandlers.probe.postMessage('paste:' + d.files.length + ':' + d.getData('text/plain'));
              for (const f of d.files) { f.text().then(t => webkit.messageHandlers.probe.postMessage('file:' + t)); }
            });
            </script>
            """)
        let probe = PageProbe()
        let page = registry.page(for: try open(file: "paste.html", javascript: true), store: store)
        page.webView.configuration.userContentController.add(probe, name: "probe")
        let window = try host(page.webView)
        defer { window.orderOut(nil) }
        try await waitFor("loaded") { self.current?.loadState == .loaded }
        window.makeFirstResponder(page.webView)
        _ = try await page.webView.evaluateJavaScript("document.getElementById('t').focus(); true")

        let files = NSPasteboard(name: NSPasteboard.Name("agterm-test-\(UUID().uuidString)"))
        defer { files.releaseGlobally() }
        files.clearContents()
        files.writeObjects([pages.appendingPathComponent("secret.txt") as NSURL])
        XCTAssertFalse(page.webView.readSelection(from: files))

        let text = NSPasteboard(name: NSPasteboard.Name("agterm-test-\(UUID().uuidString)"))
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString("plain words", forType: .string)
        XCTAssertTrue(page.webView.readSelection(from: text))
        try await waitFor("text pasted") { probe.messages.contains("paste:0:plain words") }
        XCTAssertFalse(probe.messages.contains { $0.hasPrefix("file:") || $0.hasPrefix("paste:1") }, "\(probe.messages)")
    }

    func testPageScriptRunsOnlyWhenTheOverlayAllowsIt() async throws {
        let body = #"<title>S</title><p id="i">static</p><script>document.getElementById('i').textContent = 'inline'</script>"#
            + #"<script src="ext.js"></script><iframe srcdoc="<script>parent.document.documentElement.dataset.frame = 'ran'</script>"></iframe>"#
        try write("scripts.html", body)
        try "document.documentElement.dataset.ext = 'ran'".write(to: pages.appendingPathComponent("ext.js"), atomically: true, encoding: .utf8)
        let port = try await serve(.ipv4(.loopback), [
            "/": .init(body: "<!doctype html><html><body>\(body)</body></html>"),
            "/ext.js": .init(headers: ["Content-Type": "text/javascript"], body: "document.documentElement.dataset.ext = 'ran'"),
        ])
        let text = "<!doctype html><html><body>" + body.replacingOccurrences(
            of: #"<script src="ext.js">"#, with: #"<script src="data:text/javascript,document.documentElement.dataset.ext='ran'">"#)
            + "</body></html>"
        try text.write(to: pages.appendingPathComponent("text.html"), atomically: true, encoding: .utf8)

        for javascript in [false, true] {
            let sources: [(String, () throws -> HtmlOverlay)] = [
                ("text-loaded", { try self.open(file: "text.html", javascript: javascript) }),
                ("granted", { try self.open(file: "scripts.html", grant: self.pages.path, javascript: javascript) }),
                ("url", { try self.openURL("http://127.0.0.1:\(port)/", javascript: javascript) }),
            ]
            for (name, make) in sources {
                let page = registry.page(for: try make(), store: store)
                try await waitFor("\(name) loaded") { self.current?.loadState == .loaded }
                try await Task.sleep(for: .milliseconds(300))
                let seen = try await scriptEffects(page.webView)
                let expected = javascript ? "inline|ran|ran" : "static|none|none"
                XCTAssertEqual(seen, expected, "\(name) with javascript \(javascript)")
                let background = try await variable("--agterm-background", in: page.webView)
                XCTAssertFalse(background?.isEmpty ?? true, "\(name) keeps the theme variables")
                XCTAssertTrue(store.closeOverlay(session.id))
            }
        }
    }

    func testPageScriptStaysOffThroughReloadAndNavigation() async throws {
        try write("one.html", #"<title>one</title><p id="i">static</p><script>document.getElementById('i').textContent = 'inline'</script>"#)
        try write("two.html", #"<title>two</title><p id="i">static</p><script>document.getElementById('i').textContent = 'inline'</script>"#)
        let overlay = try open(file: "one.html", grant: pages.path)
        let page = registry.page(for: overlay, store: store)
        try await waitFor("one loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "one" }
        XCTAssertNil(registry.reload(overlay.id, target: .current, store: store))
        try await waitFor("one reloaded") { self.current?.loadState == .loaded }
        let afterReload = try await page.webView.evaluateJavaScript("document.getElementById('i').textContent")
        XCTAssertEqual(afterReload as? String, "static")
        _ = try await page.webView.evaluateJavaScript("location.href = 'two.html'")
        try await waitFor("two loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "two" }
        let afterNavigation = try await page.webView.evaluateJavaScript("document.getElementById('i').textContent")
        XCTAssertEqual(afterNavigation as? String, "static")
    }

    func testAPageClosingItsWindowClosesItsOverlayAsDismissed() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>done</title><script>window.close()</script>")])
        let page = try openURL("http://127.0.0.1:\(port)/", javascript: true)
        let live = registry.page(for: page, store: store)

        try await waitFor("the page closed its overlay") { !self.session.overlayActive }
        XCTAssertNil(session.htmlOverlay)
        XCTAssertNil(registry.existing(page.id))
        XCTAssertNil(live.webView.uiDelegate)
        XCTAssertEqual(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome, .dismissed)
    }

    func testAPageWithScriptOffCannotCloseItsOverlay() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>static</title><script>window.close()</script>")])
        let page = try openURL("http://127.0.0.1:\(port)/")
        _ = registry.page(for: page, store: store)

        try await waitFor("loaded") { self.current?.loadState == .loaded }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.htmlOverlay?.id, page.id)
        XCTAssertEqual(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome, .pending)
    }

    func testAPanePageClosingItsWindowAfterASwapClosesOnlyItsOwnSlot() async throws {
        store.toggleSplit(session.id)
        session.surface = StubSurface("left")
        session.splitSurface = StubSurface("right")
        let closing = try open(pane: .left, file: "a.html", javascript: true)
        let staying = try open(pane: .right, file: "b.html")
        let live = registry.page(for: closing, store: store)
        _ = registry.page(for: staying, store: store)
        try await waitFor("both loaded") {
            self.session.paneOverlay(.left)?.html?.loadState == .loaded && self.session.paneOverlay(.right)?.html?.loadState == .loaded
        }

        XCTAssertNil(store.swapPanes(session.id))
        _ = try await live.webView.evaluateJavaScript("window.close()")

        try await waitFor("the swapped page closed") { self.session.paneOverlay(.right) == nil }
        XCTAssertEqual(session.paneOverlay(.left)?.html?.id, staying.id)
        XCTAssertNil(registry.existing(closing.id))
    }

    func testAPageThatClosedDuringAnUndoableCloseStaysClosedAfterUndo() async throws {
        let page = try open()
        let live = registry.page(for: page, store: store)
        XCTAssertTrue(store.softCloseSession(session.id, grace: 60))

        live.webViewDidClose(live.webView)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(registry.existing(page.id))

        XCTAssertTrue(store.undoPendingClose())
        live.apply(try XCTUnwrap(session.htmlOverlay))
        try await waitFor("the restored page closed") { !self.session.overlayActive }
        XCTAssertNil(registry.existing(page.id))
    }

    func testAPageKeepsTheZoomThroughNavigationAndReloadAndANewPageOpensAtIt() async throws {
        registry.setZoom(1.5)
        let page = try open(grant: pages.path)
        let live = registry.page(for: page, store: store)
        XCTAssertEqual(live.webView.pageZoom, 1.5)
        try await waitFor("a loaded") { self.current?.loadState == .loaded }

        registry.setZoom(1.25)
        _ = try await live.webView.evaluateJavaScript("location.href = 'b.html'")
        try await waitFor("navigated to b") { self.current?.current?.page.hasSuffix("/b.html") == true && self.current?.loadState == .loaded }
        XCTAssertEqual(live.webView.pageZoom, 1.25)
        XCTAssertNil(registry.navigate(page.id, .back))
        try await waitFor("back on a") { self.current?.current?.page.hasSuffix("/a.html") == true && self.current?.loadState == .loaded }
        XCTAssertEqual(live.webView.pageZoom, 1.25)
        XCTAssertNil(registry.navigate(page.id, .forward))
        try await waitFor("forward on b") { self.current?.current?.page.hasSuffix("/b.html") == true && self.current?.loadState == .loaded }
        XCTAssertEqual(live.webView.pageZoom, 1.25)
        XCTAssertNil(registry.reload(page.id, target: .original, store: store))
        try await waitFor("reloaded a") { self.current?.current?.page.hasSuffix("/a.html") == true && self.current?.loadState == .loaded }
        XCTAssertEqual(live.webView.pageZoom, 1.25)

        XCTAssertTrue(store.closeOverlay(session.id))
        XCTAssertEqual(registry.page(for: try open(file: "b.html"), store: store).webView.pageZoom, 1.25)
    }

    func testNavigatingAPageThatWasNeverShownIsRefused() {
        XCTAssertEqual(registry.navigate(UUID(), .back), OverlayHtmlError.notRealized)
    }

    func testTaggedControlsRunOnRealInputWithPageScriptOffFromText() async throws {
        try await checkTaggedControls(grant: nil, destination: "about:blank", javascript: false)
    }

    func testTaggedControlsRunOnRealInputWithPageScriptOffFromAFolder() async throws {
        try await checkTaggedControls(grant: pages.path, destination: "b.html", javascript: false)
    }

    func testTaggedControlsRunOnRealInputWithPageScriptOn() async throws {
        try await checkTaggedControls(grant: pages.path, destination: "b.html", javascript: true)
    }

    func testAThemeChangeKeepsTaggedControlsWorking() async throws {
        let requests = recordDispatch()
        try write("tags.html", Self.taggedPage(destination: "b.html"))
        let page = registry.page(for: try open(file: "tags.html", grant: pages.path), store: store)
        let window = try present(page.webView)
        defer { window.orderOut(nil) }
        try await waitFor("loaded") { self.current?.loadState == .loaded }

        try write("tags.html", Self.taggedPage(destination: "b.html").replacingOccurrences(of: "<title>T</title>",
                                                                                         with: "<title>R</title>"))
        page.applyTheme(HtmlOverlayTheme(background: "#101010", foreground: "#e0e0e0", dark: true))
        try await waitForTitle("R", in: page.webView)
        try await waitFor("reloaded") { self.current?.loadState == .loaded }
        try await click("b", in: page.webView, window: window)
        try await waitFor("request after the theme change") { requests.value.count == 1 }
        XCTAssertEqual(requests.value.first?.cmd, .sessionSelect)
    }

    private final class Recorded { var value: [ControlRequest] = [] }

    private static func taggedPage(destination: String) -> String {
        """
        <title>T</title><script>document.title = 'page script ran'</script>
        <button type="button" id="b" data-agterm="session.select" data-agterm-target="3F2A">go</button>
        <button type="button" id="n" data-agterm="session.select" data-agterm-target="9C41"><span id="inner">in</span></button>
        <form id="f" data-agterm="session.rename" action="\(destination)">
          <input id="i" name="name" value="n"><button id="fb">rename</button>
        </form>
        <form action="\(destination)"><input id="p" name="v" value="1"></form>
        """
    }

    private func checkTaggedControls(grant: String?, destination: String, javascript: Bool) async throws {
        let requests = recordDispatch()
        try write("tags.html", Self.taggedPage(destination: destination))
        let page = registry.page(for: try open(file: "tags.html", grant: grant, javascript: javascript), store: store)
        let window = try present(page.webView)
        defer { window.orderOut(nil) }
        try await waitFor("loaded") { self.current?.loadState == .loaded }
        try await waitForTitle(javascript ? "page script ran" : "T", in: page.webView)
        let start = page.webView.url

        try await click("b", in: page.webView, window: window)
        try await waitFor("button request") { requests.value.count == 1 }
        XCTAssertEqual(requests.value.last?.cmd, .sessionSelect)
        XCTAssertEqual(requests.value.last?.target, "3F2A")

        try await click("inner", in: page.webView, window: window)
        try await waitFor("nested element request") { requests.value.count == 2 }
        XCTAssertEqual(requests.value.last?.target, "9C41")

        try await click("fb", in: page.webView, window: window)
        try await waitFor("submit button request") { requests.value.count == 3 }
        XCTAssertEqual(requests.value.last?.cmd, .sessionRename)

        try await pressReturn(in: "i", view: page.webView, window: window)
        try await waitFor("return request") { requests.value.count == 4 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(requests.value.count, 4, "each input sends one request")
        XCTAssertEqual(page.webView.url, start, "a tagged form never navigates")

        try await pressReturn(in: "p", view: page.webView, window: window)
        try await waitFor("the untagged form navigates") { page.webView.url != start }
        XCTAssertEqual(requests.value.count, 4)
    }

    func testAScriptedPageGetsEachReplyAndEveryRequestSettles() async throws {
        _ = recordDispatch { _ in ControlResponse(ok: true, result: ControlResult(text: "v1")) }
        try write("js.html", """
            <title>J</title><script>
            agterm.request('version').then(r => { document.title = 'ok:' + r.text });
            agterm.request('session.nope').catch(e => { document.body.dataset.err = e.message });
            agterm.request('zmx.reset').catch(e => { document.body.dataset.refused = e.message });
            </script>
            """)
        let page = registry.page(for: try open(file: "js.html", javascript: true), store: store)
        try await waitForTitle("ok:v1", in: page.webView)
        try await waitForScript("document.body.dataset.err", in: page.webView) { $0.hasPrefix("invalid request: ") }
        try await waitForScript("document.body.dataset.refused", in: page.webView) { $0 == "zmx.reset cannot be sent from a page" }
    }

    func testDataAgtermIntoShowsTheReplyOrTheErrorWithPageScriptOff() async throws {
        _ = recordDispatch { request in
            request.cmd == .version ? ControlResponse(ok: true, result: ControlResult(text: "v1"))
                : ControlResponse(ok: false, error: "no such session")
        }
        try write("into.html", """
            <title>I</title>
            <button type="button" id="ok" data-agterm="version" data-agterm-into="#out">v</button>
            <button type="button" id="bad" data-agterm="session.select" data-agterm-target="X" data-agterm-into="#err">s</button>
            <pre id="out"></pre><pre id="err"></pre>
            """)
        let page = registry.page(for: try open(file: "into.html"), store: store)
        try await waitForTitle("I", in: page.webView)
        _ = try await page.webView.evaluateJavaScript("document.getElementById('ok').click(); document.getElementById('bad').click()")
        try await waitForScript("document.getElementById('out').textContent", in: page.webView) { $0 == "v1" }
        try await waitForScript("document.getElementById('err').textContent", in: page.webView) { $0 == "no such session" }
    }

    func testFormControlsBecomeTypedArgumentsOverTheJsonBase() async throws {
        let requests = recordDispatch()
        try write("form.html", """
            <title>F</title>
            <form id="f" data-agterm="session.status" data-agterm-args='{"autoReset":true,"name":"base"}'>
              <input name="name" value="typed">
              <input type="number" name="sizePercent" value="80">
              <input type="number" name="lines" value="">
              <input type="checkbox" name="blink">
              <input name="text" value="skipped" disabled>
              <input type="radio" name="status" value="active"><input type="radio" name="status" value="completed" checked>
              <button>go</button>
            </form>
            """)
        let page = registry.page(for: try open(file: "form.html"), store: store)
        try await waitForTitle("F", in: page.webView)
        _ = try await page.webView.evaluateJavaScript("document.getElementById('f').requestSubmit()")
        try await waitFor("form request") { requests.value.count == 1 }
        let args = try XCTUnwrap(requests.value.first?.args)
        XCTAssertEqual(args.name, "typed")
        XCTAssertEqual(args.sizePercent, 80)
        XCTAssertNil(args.lines)
        XCTAssertEqual(args.blink, false)
        XCTAssertNil(args.text)
        XCTAssertEqual(args.status, "completed")
        XCTAssertEqual(args.autoReset, true)
    }

    func testTheClickedNamedButtonIsTheOnlyButtonSent() async throws {
        let requests = recordDispatch()
        try write("buttons.html", """
            <title>B</title>
            <form id="f" data-agterm="session.overlay.submit">
              <button id="main" name="value" value="main">Main</button><button id="dev" name="value" value="dev">Dev</button>
            </form>
            """)
        let page = registry.page(for: try open(file: "buttons.html"), store: store)
        try await waitForTitle("B", in: page.webView)
        _ = try await page.webView.evaluateJavaScript("document.getElementById('f').requestSubmit(document.getElementById('dev'))")
        try await waitFor("dev request") { requests.value.count == 1 }
        XCTAssertEqual(requests.value.first?.args?.value, "dev")
        _ = try await page.webView.evaluateJavaScript("document.getElementById('f').requestSubmit(document.getElementById('main'))")
        try await waitFor("main request") { requests.value.count == 2 }
        XCTAssertEqual(requests.value.last?.args?.value, "main")
    }

    func testControlsInADisabledFieldsetAreSkipped() async throws {
        let requests = recordDispatch()
        try write("fieldset.html", """
            <title>D</title>
            <form id="f" data-agterm="session.status" data-agterm-args='{"name":"base"}'>
              <fieldset disabled><input name="name" value="locked"><input type="checkbox" name="blink" checked></fieldset>
              <input name="status" value="idle">
            </form>
            """)
        let page = registry.page(for: try open(file: "fieldset.html"), store: store)
        try await waitForTitle("D", in: page.webView)
        _ = try await page.webView.evaluateJavaScript("document.getElementById('f').requestSubmit()")
        try await waitFor("form request") { requests.value.count == 1 }
        let args = try XCTUnwrap(requests.value.first?.args)
        XCTAssertEqual(args.name, "base")
        XCTAssertNil(args.blink)
        XCTAssertEqual(args.status, "idle")
    }

    func testARepeatedValueIsRefusedAndSendsNothing() async throws {
        let requests = recordDispatch()
        try write("repeat.html", """
            <title>R</title>
            <form id="twice" data-agterm="session.rename" data-agterm-into="#err">
              <input name="name" value="a"><input name="name" value="b">
            </form>
            <form id="multi" data-agterm="session.rename" data-agterm-into="#err2">
              <select name="name" multiple><option selected>a</option><option selected>b</option></select>
            </form>
            <pre id="err"></pre><pre id="err2"></pre>
            """)
        let page = registry.page(for: try open(file: "repeat.html"), store: store)
        try await waitForTitle("R", in: page.webView)
        _ = try await page.webView.evaluateJavaScript("document.getElementById('twice').requestSubmit(); document.getElementById('multi').requestSubmit()")
        try await waitForScript("document.getElementById('err').textContent", in: page.webView) { $0.contains("name") }
        try await waitForScript("document.getElementById('err2').textContent", in: page.webView) { $0.contains("name") }
        XCTAssertTrue(requests.value.isEmpty)
    }

    func testAFrameRequestIsRefused() async throws {
        let requests = recordDispatch()
        try write("frame.html", #"""
            <title>P</title>
            <iframe srcdoc="<script>window.webkit.messageHandlers.agterm.postMessage({cmd: 'version'})
              .then(() => { parent.document.title = 'leaked' }, e => { parent.document.title = 'refused:' + e.message })
            </script>"></iframe>
            """#)
        let page = registry.page(for: try open(file: "frame.html", javascript: true), store: store)
        try await waitForTitle("refused:requests from frames are refused", in: page.webView)
        XCTAssertTrue(requests.value.isEmpty)
    }

    func testAUrlPageGetsNoBridge() async throws {
        let port = try await serve(.ipv4(.loopback), ["/": .init(body: "<title>app</title>")])
        let page = registry.page(for: try openURL("http://127.0.0.1:\(port)/", javascript: true), store: store)
        try await waitFor("loaded") { self.current?.loadState == .loaded && self.current?.current?.title == "app" }
        let helper = try await page.webView.evaluateJavaScript("typeof window.agterm + '|' + typeof window.webkit?.messageHandlers?.agterm")
        XCTAssertEqual(helper as? String, "undefined|undefined")
        let bridge = try await page.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.agterm", in: nil,
                                                               contentWorld: HtmlOverlayBridge.world)
        XCTAssertEqual(bridge as? String, "undefined")
    }

    func testAReleasedPageSendsNothingFurther() async throws {
        let requests = recordDispatch()
        try write("tags.html", Self.taggedPage(destination: "about:blank"))
        let page = registry.page(for: try open(file: "tags.html"), store: store)
        try await waitForTitle("T", in: page.webView)
        XCTAssertTrue(store.closeOverlay(session.id))
        let handler = try await page.webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.agterm", in: nil,
                                                                contentWorld: HtmlOverlayBridge.world)
        XCTAssertEqual(handler as? String, "undefined")
        _ = try? await page.webView.evaluateJavaScript("document.getElementById('b').click()")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(requests.value.isEmpty)
    }

    private func recordDispatch(_ respond: @escaping (ControlRequest) -> ControlResponse = { _ in ControlResponse(ok: true) })
        -> Recorded {
        let recorded = Recorded()
        registry.dispatch = { request in
            recorded.value.append(request)
            return respond(request)
        }
        return recorded
    }

    private func waitForScript(_ script: String, in view: WKWebView, _ matches: @escaping (String) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while true {
            let value = try await view.evaluateJavaScript("String(\(script))") as? String ?? ""
            if matches(value) { return }
            guard Date() < deadline else { return XCTFail("\(script) never matched, last: \(value)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func present(_ view: NSView) throws -> NSWindow {
        let window = try host(view)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        return window
    }

    private func click(_ id: String, in view: WKWebView, window: NSWindow) async throws {
        let value = try await view.evaluateJavaScript("""
            (() => { const r = document.getElementById('\(id)').getBoundingClientRect();
                     return [r.x + r.width / 2, r.y + r.height / 2] })()
            """)
        let center = try XCTUnwrap(value as? [Double])
        let local = NSPoint(x: center[0], y: view.isFlipped ? center[1] : view.bounds.height - center[1])
        let point = view.convert(local, to: nil)
        let content = try XCTUnwrap(window.contentView)
        let hit = try XCTUnwrap(content.hitTest(content.convert(point, from: nil)))
        XCTAssertTrue(hit === view || hit.isDescendant(of: view), "the click must land on the page view")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
        }
    }

    private func pressReturn(in id: String, view: WKWebView, window: NSWindow) async throws {
        try await click(id, in: view, window: window)
        let responder = try XCTUnwrap(window.firstResponder)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
            if type == .keyDown { responder.keyDown(with: event) } else { responder.keyUp(with: event) }
        }
    }

    private func waitForTitle(_ title: String, in view: WKWebView) async throws {
        try await waitFor("title \(title)") { view.title == title }
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

    private func scriptEffects(_ view: WKWebView) async throws -> String? {
        let value = try await view.evaluateJavaScript("""
            [document.getElementById('i').textContent, document.documentElement.dataset.ext || 'none',
             document.documentElement.dataset.frame || 'none'].join('|')
            """)
        return value as? String
    }

    private func write(_ name: String, _ body: String) throws {
        try "<!doctype html><html><body>\(body)</body></html>"
            .write(to: pages.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // the drag-destination lookup AppKit runs, private and so reached through its implementation
    private func dropTarget(in container: NSView) throws -> NSView? {
        let selector = NSSelectorFromString("_hitTest:dragTypes:")
        let method = try XCTUnwrap(class_getInstanceMethod(type(of: container), selector))
        typealias Lookup = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
        var point = NSPoint(x: container.frame.midX, y: container.frame.midY)
        let types: NSSet = [NSPasteboard.PasteboardType.fileURL.rawValue]
        return unsafeBitCast(method_getImplementation(method), to: Lookup.self)(container, selector, &point, types)
    }

    private func open(pane: OverlayPane? = nil, file: String = "a.html", grant: String? = nil,
                      javascript: Bool = false) throws -> HtmlOverlay {
        let overlay = HtmlOverlay(source: .file(path: pages.appendingPathComponent(file).path, grantRoot: grant),
                                  javascript: javascript)
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: pane, overlay: overlay, sizePercent: nil))
        return overlay
    }

    private func openURL(_ address: String, javascript: Bool = false, persistent: Bool = false,
                         browse: Bool = false) throws -> HtmlOverlay {
        let overlay = HtmlOverlay(source: .url(try XCTUnwrap(URL(string: address))), javascript: javascript,
                                  persistent: persistent, browse: browse)
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }

    private func useProfile(_ name: String) {
        let profile = BrowserProfile(directory: directory.appendingPathComponent(name))
        profiles.append(profile)
        registry.profile = profile
    }

    private static let putRecord = """
        return await new Promise((resolve, reject) => {
            const open = indexedDB.open('d', 1)
            open.onupgradeneeded = () => open.result.createObjectStore('s')
            open.onerror = () => reject(open.error)
            open.onsuccess = () => {
                const write = open.result.transaction('s', 'readwrite')
                write.objectStore('s').put('iv', 'ik')
                write.onerror = () => reject(write.error)
                write.oncomplete = () => { open.result.close(); resolve(true) }
            }
        })
        """

    private static let getRecord = """
        return await new Promise((resolve, reject) => {
            const open = indexedDB.open('d', 1)
            open.onupgradeneeded = () => open.result.createObjectStore('s')
            open.onerror = () => reject(open.error)
            open.onsuccess = () => {
                const read = open.result.transaction('s').objectStore('s').get('ik')
                read.onerror = () => reject(read.error)
                read.onsuccess = () => { open.result.close(); resolve(read.result ?? null) }
            }
        })
        """

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
