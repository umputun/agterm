import WebKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class FakeBrowser: HtmlBrowser {
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
final class FakeSharing: HtmlSharing {
    var revealed: [URL] = []
    var copied: [String] = []

    func reveal(_ url: URL) { revealed.append(url) }
    func copy(_ text: String) { copied.append(text) }
}

/// HtmlPageTestCase is the fixture the page registry tests share: one session in a fresh store, a pages
/// folder, the registry with recording browser and sharing seams, and the waits a loading web view needs.
@MainActor
class HtmlPageTestCase: XCTestCase {
    var directory: URL!
    var pages: URL!
    var store: AppStore!
    var session: Session!
    let registry = HtmlOverlayRegistry.shared
    let browser = FakeBrowser()
    let sharing = FakeSharing()

    var current: HtmlOverlay? { session.htmlOverlay ?? session.paneOverlay(.left)?.html }

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
    }

    override func tearDown() async throws {
        registry.browser = SystemBrowser()
        registry.sharing = SystemHtmlSharing()
        registry.setZoom(1)
        registry.dispatch = nil
        registry.closePageSession = nil
        store.closeSession(session.id)
        try await afterSessionClose()
        try? FileManager.default.removeItem(at: directory)
    }

    /// afterSessionClose runs once the session's pages are released and before the folder is removed.
    func afterSessionClose() async throws {}

    func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("\(what) not reached within \(timeout)s: \(String(describing: current))")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func waitForScript(_ script: String, in view: WKWebView, _ matches: @escaping (String) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while true {
            let value = try await view.evaluateJavaScript("String(\(script))") as? String ?? ""
            if matches(value) { return }
            guard Date() < deadline else { return XCTFail("\(script) never matched, last: \(value)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func variable(_ name: String, in view: WKWebView) async throws -> String? {
        let value = try await view.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('\(name)').trim()")
        return value as? String
    }

    func waitForVariable(_ name: String, _ expected: String, in view: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try await variable(name, in: view) != expected {
            guard Date() < deadline else { return XCTFail("\(name) never became \(expected)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func host(_ view: NSView) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = try XCTUnwrap(window.contentView).bounds
        window.contentView?.addSubview(view)
        return window
    }

    /// fetched lists the origin paths a `replicaLink` page asked for, in order.
    var fetched: [String] = []

    /// replicaLink serves a replica page's fetches from this Mac's disk, as a page channel serves them from the origin.
    func replicaLink() -> HtmlReplicaLink {
        HtmlReplicaLink(fetch: { [weak self] path, _ in
            self?.fetched.append(path)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return HtmlPageResource(mimeType: "application/octet-stream", chunks: AsyncThrowingStream {
                $0.yield(data)
                $0.finish()
            })
        }, bridge: { _ in throw RemotePageChannel.Failure.closed })
    }

    /// openReplica opens a page shown for another Mac whose file is `path` there.
    func openReplica(_ path: String, _ content: ReplicaContent) -> HtmlOverlay {
        let overlay = HtmlOverlay(source: .replica(path: path, content: content), replicaOf: UUID())
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: overlay, sizePercent: nil))
        return overlay
    }

    func writePNG(_ name: String, width: Int) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = pages.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }
}
