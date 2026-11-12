import Foundation
import WebKit
import agtermCore

/// TextPageBridge is the app side of a text page, static or log, local or shown for another Mac: it builds the
/// document, takes the page's reports through one message handler, and hands the page the model's search. A log page's
/// reading stays in `LogFollower`, which the bridge owns.
@MainActor
final class TextPageBridge {
    static let handlerName = "agtermTextPage"

    /// Reads is where a page's text comes from: a file on this Mac, or the Mac that opened a replica.
    struct Reads {
        let text: @MainActor () async -> Result<String, HtmlReplicaLink.ReadFailure>
        let log: LogFollower.Reader

        static func local(_ path: String) -> Reads {
            Reads(text: {
                await Task.detached(priority: .userInitiated) { TextProbe.load(path: path) }.value
                    .mapError { HtmlReplicaLink.ReadFailure(message: $0.description) }
            }, log: LogFollower.fileReader)
        }
    }

    let follower: LogFollower?
    var onScreen = true { didSet { follower?.onScreen = onScreen } }

    private let path: String
    private let line: Int?
    private let readText: @MainActor () async -> Result<String, HtmlReplicaLink.ReadFailure>
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
    // a diff page's current change, handed to a rebuild from the same text so a theme change keeps it
    private var change = 0
    // the wrap the page shows: last handed, built with, or reported by its own toggle
    private var wrap = false

    /// init builds the bridge of a text page reading through `reads` and registers its page handler; nil for any
    /// other page.
    init?(for overlay: HtmlOverlay, reads: Reads, webView: WKWebView, store: AppStore?, world: WKContentWorld,
          onFail: @escaping (String) -> Void) {
        let file: String, at: Int?
        switch overlay.source {
        case .text(let path, let line), .replica(let path, .text(let line)): (file, at) = (path, line)
        default: return nil
        }
        path = file
        line = at
        readText = reads.text
        follower = overlay.textLog.map {
            LogFollower(path: file, log: $0, following: overlay.logState?.following ?? $0.follow, pageID: overlay.id,
                        store: store, webView: webView, world: world, read: reads.log)
        }
        pageID = overlay.id
        self.store = store
        self.webView = webView
        self.world = world
        self.onFail = onFail
        search = Self.searchState(of: overlay)
        wrap = overlay.textWrap
        let handler = PageHandler()
        handler.bridge = self
        webView.configuration.userContentController.add(handler, contentWorld: world, name: Self.handlerName)
        follower?.updateLoop()
    }

    /// loadDocument builds the page from a fresh read, or from what it showed when `fresh` is false: an explicit
    /// reload reads the file again, a theme change redraws. The search rides the document, so a rebuild keeps the
    /// query and the current match without moving.
    func loadDocument(fresh: Bool) {
        documentLoad += 1
        documentPending = true
        if let follower { return follower.loadDocument(fresh: fresh, search: search, wrap: wrap) }
        let load = documentLoad, path = path, readText = readText
        Task { [weak self] in
            // a shown page reopens where it was, so a theme change or a reload never moves the view
            let top = self?.text == nil ? nil : await self?.scrollTop()
            if fresh || self?.text == nil {
                // the file may now hold other changes; the old page can still step during the read, so the change
                // the new one opens on resets only after it
                if let self { store?.setTextChangesReport(pageID, changes: nil) }
                let read = await readText()
                guard let self, load == documentLoad else { return }
                switch read {
                case .failure(let failure): return onFail(failure.message)
                case .success(let text): self.text = text
                }
                change = 0
            }
            guard let self, load == documentLoad, let text else { return }
            let html = TextPage.html(text: text, language: TextPage.language(forFile: path), line: line,
                                     style: MarkdownAssets.shared.textStyle, anchor: top, search: search, change: change,
                                     wrap: wrap)
            webView?.loadHTMLString(html, baseURL: nil)
        }
    }

    private func scrollTop() async -> Double? {
        let value = try? await webView?.evaluateJavaScript("document.scrollingElement.scrollTop", in: nil, contentWorld: world)
        return (value as? NSNumber)?.doubleValue
    }

    /// apply takes the model's latest value: following for a log page, the wrap, and a search whose revision moved.
    func apply(_ overlay: HtmlOverlay) {
        follower?.setFollowing(overlay.logState?.following ?? false)
        if overlay.textWrap != wrap {
            wrap = overlay.textWrap
            if !documentPending { pushWrap() }
        }
        let next = Self.searchState(of: overlay)
        let moved = next.revision != search.revision
        search = next
        if moved, !documentPending { pushSearch() }
    }

    /// step moves to the next or previous match of the model's query, applying that query first when the page holds
    /// an older revision, and answers the page's count and the match it reached. The model takes the result before
    /// the answer, a move pausing a following log as the page does, so state read right after never lags the page.
    func step(forward: Bool, query: String, revision: Int) async -> Result<(matches: Int, current: Int), TextSearchFailure> {
        guard !documentPending, let webView else { return .failure(.notLoaded) }
        let arguments: [String: Any] = ["forward": forward, "query": query, "revision": revision]
        let value = try? await webView.callAsyncJavaScript("return agtermTextSearchStep(forward, query, revision)",
                                                           arguments: arguments, in: nil, contentWorld: world)
        guard let body = value as? [String: Any], let matches = (body["matches"] as? NSNumber)?.intValue,
              let current = (body["current"] as? NSNumber)?.intValue else { return .failure(.notLoaded) }
        store?.setTextSearchReport(pageID, revision: revision, query: query, matches: matches, current: current)
        if matches > 0, follower?.following == true { store?.setTextLogFollowing(pageID, following: false) }
        return .success((matches, current))
    }

    /// stepChange moves a diff page to its next or previous change and answers the page's count and the change it
    /// reached, which the model takes before the answer.
    func stepChange(forward: Bool) async -> Result<TextChanges, TextChangesFailure> {
        guard !documentPending, let webView else { return .failure(.notLoaded) }
        let value = try? await webView.callAsyncJavaScript("return agtermTextChangeStep(forward)", arguments: ["forward": forward],
                                                           in: nil, contentWorld: world)
        guard let body = value as? [String: Any], let changes = Self.changes(body) else { return .failure(.notLoaded) }
        guard changes.count > 0 else { return .failure(.noChanges) }
        changesReport(body)
        return .success(changes)
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
        pushWrap()
    }

    private func report(_ body: [String: Any]) {
        guard let revision = (body["revision"] as? NSNumber)?.intValue, let query = body["query"] as? String,
              let matches = (body["matches"] as? NSNumber)?.intValue, let current = (body["current"] as? NSNumber)?.intValue
        else { return }
        store?.setTextSearchReport(pageID, revision: revision, query: query, matches: matches, current: current)
    }

    private func changesReport(_ body: [String: Any]) {
        guard let changes = Self.changes(body) else { return }
        change = changes.current
        store?.setTextChangesReport(pageID, changes: changes)
    }

    private static func changes(_ body: [String: Any]) -> TextChanges? {
        guard let count = (body["count"] as? NSNumber)?.intValue, let current = (body["current"] as? NSNumber)?.intValue
        else { return nil }
        return TextChanges(count: count, current: current)
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

    // the page already shows its own toggle, so apply compares a later model value against it and a control call
    // crossing the toggle still reaches the page
    private func wrapped(_ value: Bool) {
        wrap = value
        store?.setTextWrap(pageID, wrapped: value)
    }

    private func pushWrap() {
        webView?.callAsyncJavaScript("agtermTextSetWrap(wrap)", arguments: ["wrap": wrap], in: nil, in: world)
    }

    private static func searchState(of overlay: HtmlOverlay) -> TextPage.SearchState {
        TextPage.SearchState(query: overlay.textSearch?.query ?? "", revision: overlay.searchRevision,
                             current: overlay.textSearch?.current ?? 0)
    }

    // accepts only the page's own reports from its main frame
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
            if let changes = body["changes"] as? [String: Any] {
                bridge.changesReport(changes)
                return
            }
            if let wrap = body["wrap"] as? Bool {
                bridge.wrapped(wrap)
                return
            }
            guard let following = body["following"] as? Bool else { return }
            bridge.follower?.scrolled(following: following, top: (body["top"] as? NSNumber)?.doubleValue)
        }
    }
}
