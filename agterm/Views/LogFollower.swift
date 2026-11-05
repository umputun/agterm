import Foundation
import WebKit
import agtermCore

/// LogFollower keeps a log page's view of its file. While the page follows and is shown it checks the file by path once
/// a second and reads its end only when it changed, so a rotated, truncated or recreated log is picked up by the next
/// check; it keeps the last snapshot and the paused scroll offset for a rebuilt document, and reports to the store.
@MainActor
final class LogFollower {
    /// Reader reads `path`'s last lines, nil when the file still has the given stamp.
    typealias Reader = @Sendable (String, Int, BoundedFile.FileStamp?) -> Result<TextProbe.LogRead?, TextProbe.Failure>

    static let handlerName = "agtermLogScroll"

    let path: String
    let tail: Int
    private(set) var snapshot: LogTail.Snapshot?
    private(set) var report = TextLogReport()
    private(set) var following: Bool
    /// anchor is the scroll offset the page last reported while paused.
    private(set) var anchor: Double?
    /// onScreen gates the ticks with `following`; coming back on screen ticks at once.
    var onScreen = true { didSet { if onScreen != oldValue { updateLoop() } } }

    private let pageID: UUID
    private weak var store: AppStore?
    private weak var webView: WKWebView?
    private let world: WKContentWorld
    private let read: Reader
    private let interval: Duration
    private var stamp: BoundedFile.FileStamp?
    // bumped by every read, so only the newest read lands
    private var readSequence = 0
    // bumped by a pause, so no tick lands on the view a user scrolled into; a document build is never dropped by it
    private var pauseEpoch = 0
    // bumped by every document build and by stop, so a slow build cannot replace a newer one
    private var documentLoad = 0
    // set from a document build until its renderer reports ready: ticks wait and nothing is pushed, since the old
    // document or a renderer not yet defined would drop it, and the ready report delivers the latest state instead
    private var documentPending = false
    private var loop: Task<Void, Never>?

    init(path: String, log: TextLog, following: Bool, pageID: UUID, store: AppStore?, webView: WKWebView?,
         world: WKContentWorld, interval: Duration = .seconds(1),
         read: @escaping Reader = { TextProbe.loadLog(path: $0, tail: $1, unchangedFrom: $2) }) {
        self.path = path
        tail = log.tail
        self.following = following
        self.pageID = pageID
        self.store = store
        self.webView = webView
        self.world = world
        self.interval = interval
        self.read = read
    }

    /// make builds the follower of a log page and registers its page handler; nil for any other page.
    static func make(for overlay: HtmlOverlay, webView: WKWebView, store: AppStore?, world: WKContentWorld) -> LogFollower? {
        guard case .text(let path, _) = overlay.source, let log = overlay.textLog else { return nil }
        let follower = LogFollower(path: path, log: log, following: overlay.logState?.following ?? log.follow, pageID: overlay.id,
                                   store: store, webView: webView, world: world)
        let handler = PageHandler()
        handler.follower = follower
        webView.configuration.userContentController.add(handler, contentWorld: world, name: handlerName)
        follower.updateLoop()
        return follower
    }

    /// loadDocument builds the page from a fresh read, or from the cached snapshot and anchor when `fresh` is false:
    /// an explicit reload reads the file again, a theme change redraws what is shown. A read that failed after the
    /// open was accepted shows an empty page marked waiting or unreadable, which the next good read fills.
    func loadDocument(fresh: Bool) {
        documentLoad += 1
        documentPending = true
        let load = documentLoad
        Task { [weak self] in
            guard let self else { return }
            if fresh || snapshot == nil { await refresh() }
            guard load == documentLoad else { return }
            let snapshot = snapshot ?? LogTail.Snapshot(text: "", lines: 0, clipped: false)
            let html = TextPage.html(text: snapshot.text, language: TextPage.language(forFile: path), line: nil,
                                     style: MarkdownAssets.shared.textStyle,
                                     log: TextLogState(following: following, report: report), anchor: following ? nil : anchor)
            webView?.loadHTMLString(html, baseURL: nil)
        }
    }

    /// setFollowing takes the model's value: the page's bar follows it, a pause drops any read in flight, and a
    /// resume ticks at once.
    func setFollowing(_ value: Bool) {
        guard value != following else { return }
        // a pause from control or the model freezes the view where it is, not where an earlier scroll left it
        if !value { anchor = nil }
        applyFollowing(value)
        if !documentPending {
            webView?.callAsyncJavaScript("agtermTextSetFollowing(following)", arguments: ["following": value], in: nil, in: world)
        }
    }

    /// scrolled takes the page's report of a user scroll: its offset, and whether it now sits at the bottom. The
    /// follower takes the change before the model does, so a read already in flight cannot replace a frozen view.
    func scrolled(following value: Bool, top: Double?) {
        anchor = top
        guard value != following else { return }
        applyFollowing(value)
        store?.setTextLogFollowing(pageID, following: value)
    }

    /// rendererReady takes the new document's report that it can take updates, and hands it the latest state, which a
    /// read during the build may have changed.
    func rendererReady() {
        guard documentPending else { return }
        documentPending = false
        push()
        webView?.callAsyncJavaScript("agtermTextSetFollowing(following)", arguments: ["following": following], in: nil, in: world)
    }

    /// tick checks the file once and shows a change unless a newer read or a pause overtook it. A page that left its
    /// slot, or whose document is being rebuilt, reads nothing.
    func tick() async {
        guard !documentPending, store?.htmlOverlaySlot(pageID) != nil else { return }
        readSequence += 1
        let mine = readSequence, epoch = pauseEpoch
        let result = await readDetached(unchangedFrom: stamp)
        guard mine == readSequence, epoch == pauseEpoch else { return }
        apply(result)
    }

    /// stop ends the ticks and drops every read and build in flight.
    func stop() {
        loop?.cancel()
        loop = nil
        readSequence += 1
        pauseEpoch += 1
        documentLoad += 1
    }

    private func applyFollowing(_ value: Bool) {
        following = value
        if !value { pauseEpoch += 1 }
        updateLoop()
    }

    // a forced read: it replaces the cache even when the file is unchanged, and no tick runs beside it
    private func refresh() async {
        readSequence += 1
        let mine = readSequence
        let result = await readDetached(unchangedFrom: nil)
        guard mine == readSequence else { return }
        apply(result)
    }

    private func readDetached(unchangedFrom: BoundedFile.FileStamp?) async -> Result<TextProbe.LogRead?, TextProbe.Failure> {
        let read = read, path = path, tail = tail
        return await Task.detached(priority: .utility) { read(path, tail, unchangedFrom) }.value
    }

    private func apply(_ result: Result<TextProbe.LogRead?, TextProbe.Failure>) {
        switch result {
        case .success(nil):
            return
        case .success(let read?):
            // a binary end keeps its stamp, so the next tick skips an unchanged file instead of reading it again
            stamp = read.stamp
            guard let shown = read.snapshot else {
                var next = report
                next.unreadable = true
                next.waiting = false
                return publish(next, push: next != report)
            }
            snapshot = shown
            publish(TextLogReport(lines: shown.lines, clipped: shown.clipped), push: true)
        case .failure:
            stamp = nil
            var next = report
            next.waiting = true
            next.unreadable = false
            publish(next, push: next != report)
        }
    }

    private func publish(_ next: TextLogReport, push shouldPush: Bool) {
        report = next
        store?.setTextLogReport(pageID, next)
        if shouldPush, !documentPending { push() }
    }

    // highlighting is dropped past `TextPage.maxHighlightBytes`, as the first document drops it
    private func push() {
        let text = snapshot?.text ?? ""
        let language = text.utf8.count <= TextPage.maxHighlightBytes ? TextPage.language(forFile: path) : nil
        let arguments: [String: Any] = ["text": text, "clipped": report.clipped, "waiting": report.waiting,
                                        "unreadable": report.unreadable, "language": language ?? NSNull()]
        webView?.callAsyncJavaScript("agtermTextUpdate(text, clipped, waiting, unreadable, language)", arguments: arguments,
                                     in: nil, in: world)
    }

    private func updateLoop() {
        let run = following && onScreen
        guard run != (loop != nil) else { return }
        loop?.cancel()
        loop = nil
        guard run else { return }
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let follower = self else { return }
                    await follower.tick()
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    // accepts only the page's own reports from its main frame: a user scroll, or a new document ready for updates
    private final class PageHandler: NSObject, WKScriptMessageHandler {
        weak var follower: LogFollower?

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            if body["ready"] as? Bool == true {
                follower?.rendererReady()
                return
            }
            guard let following = body["following"] as? Bool else { return }
            follower?.scrolled(following: following, top: (body["top"] as? NSNumber)?.doubleValue)
        }
    }
}
