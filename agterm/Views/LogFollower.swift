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

    /// Shift is how the text a push carries relates to what the page shows: `dropped` lines left its front, `cut`
    /// when the new start falls inside a line, `replaced` when the file is not the one the page's text came from.
    struct Shift: Equatable {
        var dropped = 0
        var cut = false
        var replaced = false
    }

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
    // what the page was last given, which the next push's shift is measured against
    private var pageSnapshot: LogTail.Snapshot?
    private var pageStamp: BoundedFile.FileStamp?
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

    /// loadDocument builds the page from a fresh read, or from the cached snapshot and anchor when `fresh` is false:
    /// an explicit reload reads the file again, a theme change redraws what is shown. A read that failed after the
    /// open was accepted shows an empty page marked waiting or unreadable, which the next good read fills.
    func loadDocument(fresh: Bool, search: TextPage.SearchState? = nil) {
        documentLoad += 1
        documentPending = true
        let load = documentLoad
        Task { [weak self] in
            guard let self else { return }
            if fresh || snapshot == nil { await refresh() }
            guard load == documentLoad else { return }
            let shown = snapshot ?? LogTail.Snapshot(text: "", lines: 0, clipped: false)
            pageSnapshot = snapshot
            pageStamp = stamp
            let html = TextPage.html(text: shown.text, language: TextPage.language(forFile: path), line: nil,
                                     style: MarkdownAssets.shared.textStyle, log: TextLogState(following: following, report: report),
                                     anchor: following ? nil : anchor, search: search)
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
        let shift = Self.shift(from: pageSnapshot, stamp: pageStamp, to: snapshot, stamp: stamp)
        pageSnapshot = snapshot
        pageStamp = stamp
        let arguments: [String: Any] = ["text": text, "clipped": report.clipped, "waiting": report.waiting,
                                        "unreadable": report.unreadable, "language": language ?? NSNull(),
                                        "shift": ["dropped": shift.dropped, "cut": shift.cut, "replaced": shift.replaced]]
        webView?.callAsyncJavaScript("agtermTextUpdate(text, clipped, waiting, unreadable, language, shift)", arguments: arguments,
                                     in: nil, in: world)
    }

    /// shift compares two snapshots of one file by their start offsets, counting the line feeds in the bytes the
    /// newer one no longer shows; another file, a shrunk one or a start that moved back is a replacement.
    static func shift(from old: LogTail.Snapshot?, stamp oldStamp: BoundedFile.FileStamp?, to new: LogTail.Snapshot?,
                      stamp newStamp: BoundedFile.FileStamp?) -> Shift {
        guard let old, let new, old != new || oldStamp != newStamp else { return Shift() }
        guard let oldStamp, let newStamp, oldStamp.device == newStamp.device, oldStamp.inode == newStamp.inode,
              newStamp.size >= oldStamp.size, new.startOffset >= old.startOffset else { return Shift(replaced: true) }
        let bytes = Array(old.text.utf8)
        let gone = min(new.startOffset - old.startOffset, bytes.count)
        guard gone < bytes.count else {
            let unterminated = bytes.last.map { $0 != lineFeed && $0 != carriageReturn } ?? false
            return Shift(dropped: lineBreaks(bytes, before: bytes.count) + (unterminated ? 1 : 0))
        }
        return Shift(dropped: lineBreaks(bytes, before: gone), cut: gone > 0 && !breakEnds(bytes, at: gone))
    }

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    // LF, CRLF and a lone CR are each one break, as the page counts lines once it normalizes them
    private static func lineBreaks(_ bytes: [UInt8], before end: Int) -> Int {
        (0..<end).reduce(0) { $0 + (bytes[$1] == lineFeed || isLoneCR(bytes, $1) ? 1 : 0) }
    }

    private static func breakEnds(_ bytes: [UInt8], at index: Int) -> Bool {
        bytes[index - 1] == lineFeed || isLoneCR(bytes, index - 1)
    }

    private static func isLoneCR(_ bytes: [UInt8], _ index: Int) -> Bool {
        bytes[index] == carriageReturn && (index + 1 == bytes.count || bytes[index + 1] != lineFeed)
    }

    func updateLoop() {
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
}
