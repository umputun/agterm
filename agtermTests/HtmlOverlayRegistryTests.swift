import XCTest
@testable import agterm
import agtermCore

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
        let overlay = HtmlOverlay(file: pages.appendingPathComponent(file).path, grantRoot: grant)
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: pane, overlay: overlay, sizePercent: nil))
        return overlay
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
