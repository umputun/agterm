import WebKit
import XCTest
import os
@testable import agterm

private final class Flag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

@MainActor
final class HtmlPageSchemeHandlerTests: XCTestCase {
    private let pageID = UUID()
    private var handler: HtmlPageSchemeHandler?
    private var webView: WKWebView?

    private nonisolated static let files: [String: (String, Data)] = [
        "/index.html": ("text/html", Data("""
            <!doctype html><html><head><link rel="stylesheet" href="style.css">
            <script type="module" src="main.js"></script></head>
            <body><img id="dot" src="img/dot.svg"></body></html>
            """.utf8)),
        "/style.css": ("text/css", Data("body { color: rgb(1, 2, 3); }".utf8)),
        "/main.js": ("text/javascript", Data("import { dep } from './lib/dep.js'; window.moduleRan = dep;".utf8)),
        "/lib/dep.js": ("text/javascript", Data("export const dep = 'dep-ok';".utf8)),
        "/data.txt": ("text/plain", Data("fetched-ok".utf8)),
        "/img/dot.svg": ("image/svg+xml", Data("<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'/>".utf8)),
    ]

    override func tearDown() async throws {
        webView?.stopLoading()
        webView = nil
        handler = nil
        try await super.tearDown()
    }

    func testAPageLoadsItsStylesheetImageAndModulesThroughTheHandler() async throws {
        let view = load(Self.staticSource)
        try await waitForJS(view, "window.moduleRan", equals: "dep-ok")
        try await waitForJS(view, "document.getElementById('dot').naturalWidth", equals: 1)
        try await waitForJS(view, "getComputedStyle(document.body).color", equals: "rgb(1, 2, 3)")
    }

    func testFetchAndHistoryWorkOnTheCustomScheme() async throws {
        let view = load(Self.staticSource)
        try await waitForJS(view, "window.moduleRan", equals: "dep-ok")
        _ = try await view.evaluateJavaScript("fetch('data.txt').then(r => r.text()).then(t => window.fetched = t); 0")
        try await waitForJS(view, "window.fetched", equals: "fetched-ok")

        _ = try await view.evaluateJavaScript("history.pushState({}, '', 'second')")
        try await waitForJS(view, "location.pathname", equals: "/second")
        XCTAssertTrue(view.canGoBack)
        view.goBack()
        try await waitForJS(view, "location.pathname", equals: "/index.html")
        XCTAssertTrue(view.canGoForward)
        view.goForward()
        try await waitForJS(view, "location.pathname", equals: "/second")
    }

    func testAStoppedRequestCancelsItsSourceAndASlowOneBlocksNoOther() async throws {
        let cancelled = Flag()
        let view = load { path in
            guard path == "/slow.bin" else { return try await Self.staticSource(path) }
            let chunks = AsyncThrowingStream<Data, Error> { continuation in
                continuation.onTermination = { _ in cancelled.set() }
            }
            return HtmlPageResource(mimeType: "application/octet-stream", chunks: chunks)
        }
        try await waitForJS(view, "window.moduleRan", equals: "dep-ok")
        _ = try await view.evaluateJavaScript("""
            window.ctl = new AbortController();
            fetch('slow.bin', {signal: window.ctl.signal}).then(r => r.text()).catch(() => window.aborted = true);
            fetch('data.txt').then(r => r.text()).then(t => window.fetched = t);
            0
            """)
        try await waitForJS(view, "window.fetched", equals: "fetched-ok")
        XCTAssertFalse(cancelled.isSet, "the slow request must still be pending")

        _ = try await view.evaluateJavaScript("window.ctl.abort()")
        try await waitForJS(view, "window.aborted", equals: true)
        try await waitFor("source cancelled") { cancelled.isSet }
    }

    func testARequestForAnotherPageNeverReachesTheSource() async throws {
        let reached = Flag()
        let view = load { path in
            if path == "/data.txt" { reached.set() }
            return try await Self.staticSource(path)
        }
        try await waitForJS(view, "window.moduleRan", equals: "dep-ok")
        let other = try XCTUnwrap(HtmlPageSchemeHandler.url(pageID: UUID(), path: "data.txt"))
        _ = try await view.evaluateJavaScript("""
            fetch('\(other.absoluteString)').then(() => window.other = 'loaded', () => window.other = 'failed'); 0
            """)
        try await waitForJS(view, "window.other", equals: "failed")
        XCTAssertFalse(reached.isSet)
    }

    private nonisolated static let staticSource: HtmlPageSchemeHandler.Source = { path in
        guard let (mime, data) = files[path] else { throw URLError(.fileDoesNotExist) }
        return HtmlPageResource(mimeType: mime, chunks: AsyncThrowingStream { continuation in
            let half = data.count / 2
            continuation.yield(data.prefix(half))
            continuation.yield(data.dropFirst(half))
            continuation.finish()
        })
    }

    private func load(_ source: @escaping HtmlPageSchemeHandler.Source) -> WKWebView {
        let handler = HtmlPageSchemeHandler(pageID: pageID, source: source)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: HtmlPageSchemeHandler.scheme)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        self.handler = handler
        webView = view
        if let url = HtmlPageSchemeHandler.url(pageID: pageID, path: "index.html") { view.load(URLRequest(url: url)) }
        return view
    }

    private func waitForJS<T: Equatable>(_ view: WKWebView, _ script: String, equals expected: T,
                                         timeout: TimeInterval = 10) async throws {
        var last: Any?
        try await waitFor("\(script) == \(expected), last \(String(describing: last))", timeout: timeout) {
            last = try? await view.evaluateJavaScript(script)
            return (last as? T) == expected
        }
    }

    private func waitFor(_ what: @autoclosure () -> String, timeout: TimeInterval = 10,
                         _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else { return XCTFail("\(what()) not reached within \(timeout)s") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
