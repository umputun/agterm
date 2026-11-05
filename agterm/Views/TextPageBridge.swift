import Foundation
import WebKit
import agtermCore

/// TextPageBridge is the app side of a local text page, static or log: it builds the document, takes the page's
/// reports through one message handler, and hands the page the model's search. A log page's file reading stays in
/// `LogFollower`, which the bridge owns.
@MainActor
final class TextPageBridge {
    static let handlerName = "agtermTextPage"

    let follower: LogFollower?
    var onScreen = true { didSet { follower?.onScreen = onScreen } }

    private let path: String
    private let line: Int?
    private let pageID: UUID
    private weak var store: AppStore?
    private weak var webView: WKWebView?
    private let world: WKContentWorld
    private let onFail: (String) -> Void
    private var search = TextPage.SearchState(query: "", revision: 0, current: 0)
    // the revisions the page's own field produced, so their pushes reach it as echoes and never overwrite its typing
    private var typedRevisions: Set<Int> = []
    // a static page's text, kept so a theme change redraws without reading the file again
    private var text: String?
    // bumped by every document build and by stop, so a slow build cannot replace a newer one
    private var documentLoad = 0
    // set from a document build until its renderer reports ready; the ready report delivers the latest search
    private var documentPending = false

    init(path: String, line: Int?, follower: LogFollower?, pageID: UUID, store: AppStore?, webView: WKWebView?,
         world: WKContentWorld, onFail: @escaping (String) -> Void) {
        self.path = path
        self.line = line
        self.follower = follower
        self.pageID = pageID
        self.store = store
        self.webView = webView
        self.world = world
        self.onFail = onFail
    }

    /// make builds the bridge of a local text page and registers its page handler; nil for any other page.
    static func make(for overlay: HtmlOverlay, webView: WKWebView, store: AppStore?, world: WKContentWorld,
                     onFail: @escaping (String) -> Void) -> TextPageBridge? {
        guard case .text(let path, let line) = overlay.source else { return nil }
        let follower = overlay.textLog.map {
            LogFollower(path: path, log: $0, following: overlay.logState?.following ?? $0.follow, pageID: overlay.id,
                        store: store, webView: webView, world: world)
        }
        let bridge = TextPageBridge(path: path, line: line, follower: follower, pageID: overlay.id, store: store,
                                    webView: webView, world: world, onFail: onFail)
        bridge.search = Self.searchState(of: overlay)
        let handler = PageHandler()
        handler.bridge = bridge
        webView.configuration.userContentController.add(handler, contentWorld: world, name: handlerName)
        follower?.updateLoop()
        return bridge
    }

    /// loadDocument builds the page from a fresh read, or from what it showed when `fresh` is false: an explicit
    /// reload reads the file again, a theme change redraws. The search rides the document, so a rebuild keeps the
    /// query and the current match without moving.
    func loadDocument(fresh: Bool) {
        documentLoad += 1
        documentPending = true
        if let follower { return follower.loadDocument(fresh: fresh, search: search) }
        let load = documentLoad, path = path
        Task { [weak self] in
            // a shown page reopens where it was, so a theme change or a reload never moves the view
            let top = self?.text == nil ? nil : await self?.scrollTop()
            if fresh || self?.text == nil {
                let read = await Task.detached(priority: .userInitiated) { TextProbe.load(path: path) }.value
                guard let self, load == documentLoad else { return }
                switch read {
                case .failure(let failure): return onFail(failure.description)
                case .success(let text): self.text = text
                }
            }
            guard let self, load == documentLoad, let text else { return }
            let html = TextPage.html(text: text, language: TextPage.language(forFile: path), line: line,
                                     style: MarkdownAssets.shared.textStyle, anchor: top, search: search)
            webView?.loadHTMLString(html, baseURL: nil)
        }
    }

    private func scrollTop() async -> Double? {
        let value = try? await webView?.evaluateJavaScript("document.scrollingElement.scrollTop", in: nil, contentWorld: world)
        return (value as? NSNumber)?.doubleValue
    }

    /// apply takes the model's latest value: following for a log page, and a search whose revision moved.
    func apply(_ overlay: HtmlOverlay) {
        follower?.setFollowing(overlay.logState?.following ?? false)
        let next = Self.searchState(of: overlay)
        let moved = next.revision != search.revision
        search = next
        if moved, !documentPending { pushSearch() }
    }

    /// step moves to the next or previous match of the model's query, applying that query first when the page holds
    /// an older revision, and answers the page's count and the match it reached.
    func step(forward: Bool, query: String, revision: Int) async -> Result<(matches: Int, current: Int), TextSearchFailure> {
        guard !documentPending, let webView else { return .failure(.notLoaded) }
        let arguments: [String: Any] = ["forward": forward, "query": query, "revision": revision]
        let value = try? await webView.callAsyncJavaScript("return agtermTextSearchStep(forward, query, revision)",
                                                           arguments: arguments, in: nil, contentWorld: world)
        guard let body = value as? [String: Any], let matches = (body["matches"] as? NSNumber)?.intValue,
              let current = (body["current"] as? NSNumber)?.intValue else { return .failure(.notLoaded) }
        return .success((matches, current))
    }

    /// stop ends the follower and drops every build in flight.
    func stop() {
        documentLoad += 1
        follower?.stop()
    }

    private func rendererReady() {
        guard documentPending else { return }
        documentPending = false
        follower?.rendererReady()
        pushSearch()
    }

    private func report(_ body: [String: Any]) {
        guard let revision = (body["revision"] as? NSNumber)?.intValue, let query = body["query"] as? String,
              let matches = (body["matches"] as? NSNumber)?.intValue, let current = (body["current"] as? NSNumber)?.intValue
        else { return }
        store?.setTextSearchReport(pageID, revision: revision, query: query, matches: matches, current: current)
    }

    private func typed(_ query: String) {
        guard let revision = store?.setTextSearch(pageID, query: query) else { return }
        typedRevisions.insert(revision)
    }

    private func pushSearch() {
        let typed = typedRevisions.contains(search.revision)
        typedRevisions = typedRevisions.filter { $0 > search.revision }
        webView?.callAsyncJavaScript("agtermTextSearchSet(query, revision, typed)",
                                     arguments: ["query": search.query, "revision": search.revision, "typed": typed],
                                     in: nil, in: world)
    }

    private static func searchState(of overlay: HtmlOverlay) -> TextPage.SearchState {
        TextPage.SearchState(query: overlay.textSearch?.query ?? "", revision: overlay.searchRevision,
                             current: overlay.textSearch?.current ?? 0)
    }

    // accepts only the page's own reports from its main frame: a new document ready for updates, a user scroll on a
    // log page, a query typed into the field, or the matches the page found
    private final class PageHandler: NSObject, WKScriptMessageHandler {
        weak var bridge: TextPageBridge?

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let bridge else { return }
            if body["ready"] as? Bool == true {
                bridge.rendererReady()
                return
            }
            if let query = body["search"] as? String {
                bridge.typed(query)
                return
            }
            if let report = body["report"] as? [String: Any] {
                bridge.report(report)
                return
            }
            guard let following = body["following"] as? Bool else { return }
            bridge.follower?.scrolled(following: following, top: (body["top"] as? NSNumber)?.doubleValue)
        }
    }
}
