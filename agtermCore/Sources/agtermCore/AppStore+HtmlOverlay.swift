import Foundation

/// HtmlOverlayOpenFailure is why `AppStore.openHtmlOverlay` refused.
public enum HtmlOverlayOpenFailure: Equatable, Sendable {
    case unknownSession, alreadyOpen, paneNotVisible, presenter
}

/// HtmlOverlayCommandFailure is why a command addressing a page (`reload`, `navigate`) refused.
public enum HtmlOverlayCommandFailure: Error, Equatable, Sendable {
    case unknownSession, noOverlay, notHtml
    /// replica: the page is shown here for another Mac, whose ledger alone takes its answer.
    case replica
}

extension HtmlOverlayOpenFailure {
    /// message is the control error for this refusal; `pane` picks the pane-overlay wording.
    public func message(pane: OverlayPane?) -> String {
        switch self {
        case .unknownSession: return "no such session"
        case .alreadyOpen: return pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen
        case .paneNotVisible: return PaneOverlayError.paneNotVisible
        case .presenter: return OverlayHtmlError.presenter
        }
    }
}

extension HtmlOverlayCommandFailure {
    /// message is the control error for this refusal.
    public var message: String {
        switch self {
        case .unknownSession: return "no such session"
        case .noOverlay: return OverlayHtmlError.noOverlay
        case .notHtml: return OverlayHtmlError.notHtml
        case .replica: return OverlayHtmlError.replicaSubmit
        }
    }
}

/// TextLogFollowFailure is why `AppStore.setTextLogFollowing` refused.
public enum TextLogFollowFailure: Error, Equatable, Sendable {
    case page(HtmlOverlayCommandFailure)
    case notLog

    /// message is the control error for this refusal.
    public var message: String {
        switch self {
        case .page(let failure): return failure.message
        case .notLog: return "no log page"
        }
    }
}

/// TextSearchRequest is one `session.overlay.search` request: set a query, step to the next or previous match, or
/// close the search.
public enum TextSearchRequest: Equatable, Sendable {
    case query(String)
    case next
    case previous
    case close
}

/// TextSearchFailure is why a page search request was refused.
public enum TextSearchFailure: Error, Equatable, Sendable {
    case page(HtmlOverlayCommandFailure)
    case notText
    case remote
    case notLoaded
    case noQuery

    /// message is the control error for this refusal.
    public var message: String {
        switch self {
        case .page(let failure): return failure.message
        case .notText: return "no text page"
        case .remote: return "remote page: search it on the Mac that shows it"
        case .notLoaded: return "page not loaded"
        case .noQuery: return "no search query: set one first"
        }
    }
}

/// TextChangesFailure is why a `session.overlay.changes` step was refused.
public enum TextChangesFailure: Error, Equatable, Sendable {
    case page(HtmlOverlayCommandFailure)
    case notDiff
    case remote
    case notLoaded
    case noChanges

    /// message is the control error for this refusal.
    public var message: String {
        switch self {
        case .page(let failure): return failure.message
        case .notDiff: return "no diff page"
        case .remote: return "remote page: step it on the Mac that shows it"
        case .notLoaded: return "page not loaded"
        case .noChanges: return "no changes"
        }
    }
}

extension AppStore {
    /// openHtmlOverlay opens a page in the session-wide slot (`pane` nil) or one pane's slot, with the slot
    /// rules of `openOverlay`/`openPaneOverlay`. Refused when the placement rule hands the slot to the presenting
    /// Mac, which `openRemotePage` serves. NOT persisted.
    public func openHtmlOverlay(_ sessionID: UUID, pane: OverlayPane?, overlay: HtmlOverlay, sizePercent: Int?,
                                points: OverlayPointSize = OverlayPointSize(),
                                backgroundColor: String? = nil) -> HtmlOverlayOpenFailure? {
        guard let session = session(withID: sessionID) else { return .unknownSession }
        if pageBelongsRemote(session, pane: pane) { return .presenter }
        if let pane {
            guard session.paneOverlay(pane) == nil else { return .alreadyOpen }
            guard session.rendersPane(pane) else { return .paneNotVisible }
            session.setPaneOverlayExitCode(nil, pane: pane)
            session.remoteOverlays.clearFailure(pane)
            var slot = PaneOverlay(html: overlay, backgroundColor: backgroundColor)
            slot.holdsSessionCover = session.coverOverlayActive
            session.setPaneOverlay(slot, pane: pane)
            if overlay.replicaOf == nil { HtmlPageOutcomes.shared.register(overlay.id) }
            scheduleTreeChanged()
            return nil
        }
        if session.hudActive { closeOverlay(sessionID) }
        guard !session.overlayActive else { return .alreadyOpen }
        session.overlaySlotGeneration += 1
        session.overlayExitCode = nil
        session.remoteOverlays.clearFailure(nil)
        session.overlaySizePercent = sizePercent.map { min(100, max(1, $0)) }
        session.overlayPoints = sizePercent == nil ? OverlayPointSize() : points
        session.overlayBackgroundColor = backgroundColor
        session.htmlOverlay = overlay
        session.overlayActive = true
        if overlay.replicaOf == nil { HtmlPageOutcomes.shared.register(overlay.id) }
        scheduleTreeChanged()
        return nil
    }

    /// submitHtmlOverlay answers the page in the slot `pane` addresses with `value`, then closes it. The answer is
    /// recorded before the close, whose release would otherwise record the page dismissed.
    public func submitHtmlOverlay(_ sessionID: UUID, pane: OverlayPane?, value: String) -> HtmlOverlayCommandFailure? {
        if let page = session(withID: sessionID)?.remoteOverlays.slot(pane)?.page {
            HtmlPageOutcomes.shared.submit(page.overlay.id, value: value)
            closeRemoteOverlay(sessionID, pane: pane)
            return nil
        }
        let page: HtmlOverlay
        switch htmlOverlay(sessionID, pane: pane) {
        case .success(let found): page = found
        case .failure(let failure): return failure
        }
        if page.replicaOf != nil { return .replica }
        HtmlPageOutcomes.shared.submit(page.id, value: value)
        if let pane { closePaneOverlay(sessionID, pane: pane) } else { closeOverlay(sessionID) }
        return nil
    }

    /// htmlOverlayCommandFailure is why the slot `pane` addresses cannot take a page command, nil when it
    /// holds a page.
    public func htmlOverlayCommandFailure(_ sessionID: UUID, pane: OverlayPane?) -> HtmlOverlayCommandFailure? {
        switch htmlOverlay(sessionID, pane: pane) {
        case .success: return nil
        case .failure(let failure): return failure
        }
    }

    /// reloadHtmlOverlay asks the app to reload the page, keeping the slot, its identity and the web view.
    public func reloadHtmlOverlay(_ sessionID: UUID, pane: OverlayPane?,
                                  target: HtmlReloadTarget = .original) -> HtmlOverlayCommandFailure? {
        let page: HtmlOverlay
        switch htmlOverlay(sessionID, pane: pane) {
        case .success(let found): page = found
        case .failure(let failure): return failure
        }
        updateHtmlOverlay(page.id) {
            $0.reloadRevision += 1
            $0.reloadTarget = target
            $0.loadState = .loading
            $0.loadError = nil
            if target == .original { $0.current = nil }
        }
        return nil
    }

    /// setHtmlLoadState records what the web view reported for page `id` wherever its slot now is, including
    /// a session hidden by an undoable close. No-op once the page has left its slot.
    public func setHtmlLoadState(_ id: UUID, state: HtmlLoadState, error: String?) {
        updateHtmlOverlay(id) {
            $0.loadState = state
            $0.loadError = error
        }
    }

    /// setHtmlPage records what the web view now shows, as `setHtmlLoadState` does.
    public func setHtmlPage(_ id: UUID, _ info: HtmlPageInfo?) {
        updateHtmlOverlay(id) { $0.current = info }
    }

    /// setTextLogFollowing applies `mode` to the log page in the slot `pane` addresses and returns whether it now
    /// follows. A change emits `tree.changed`.
    public func setTextLogFollowing(_ sessionID: UUID, pane: OverlayPane?,
                                    mode: ControlToggleMode) -> Result<Bool, TextLogFollowFailure> {
        let page: HtmlOverlay
        switch htmlOverlay(sessionID, pane: pane) {
        case .success(let found): page = found
        case .failure(let failure): return .failure(.page(failure))
        }
        if page.replicaOf != nil { return .failure(.page(.replica)) }
        guard let state = page.logState else { return .failure(.notLog) }
        let following: Bool
        switch mode {
        case .on: following = true
        case .off: following = false
        case .toggle: following = !state.following
        }
        setTextLogFollowing(page.id, following: following)
        return .success(following)
    }

    /// setTextLogFollowing records whether log page `id` follows its file, as the page reported it after a scroll,
    /// wherever its slot now is. A change emits `tree.changed`; a page that is not a log page is left alone.
    public func setTextLogFollowing(_ id: UUID, following: Bool) {
        var changed = false
        updateHtmlOverlay(id) {
            guard $0.logState != nil, $0.logState?.following != following else { return }
            $0.logState?.following = following
            changed = true
        }
        if changed { scheduleTreeChanged() }
    }

    /// setTextLogReport records what the app last read for log page `id`. Written only on a change and never
    /// emitted, so a follower's ticks wake no hook.
    public func setTextLogReport(_ id: UUID, _ report: TextLogReport) {
        updateHtmlOverlay(id) {
            guard $0.logState != nil, $0.logState?.report != report else { return }
            $0.logState?.report = report
        }
    }

    /// textSearchPage finds the local text page in the slot `pane` addresses, for a search request. A slot the placement
    /// rule hands to the presenting Mac is refused, since presentation state carries no search.
    public func textSearchPage(_ sessionID: UUID, pane: OverlayPane?) -> Result<HtmlOverlay, TextSearchFailure> {
        if pageBelongsRemote(sessionID, pane: pane) { return .failure(.remote) }
        switch htmlOverlay(sessionID, pane: pane) {
        case .failure(let failure): return .failure(.page(failure))
        case .success(let page):
            guard case .text = page.source else { return .failure(.notText) }
            return .success(page)
        }
    }

    /// setTextSearch sets text page `id`'s query, an empty one closing the search, from control or the page's own
    /// field. A change bumps `searchRevision`, clears the report, emits `tree.changed` and returns the new revision;
    /// nil for no change or a page that is not a text page.
    @discardableResult public func setTextSearch(_ id: UUID, query: String) -> Int? {
        var revision: Int?
        updateHtmlOverlay(id) {
            guard case .text = $0.source, ($0.textSearch?.query ?? "") != query else { return }
            $0.searchRevision += 1
            $0.textSearch = query.isEmpty ? nil : TextSearch(query: query)
            revision = $0.searchRevision
        }
        if revision != nil { scheduleTreeChanged() }
        return revision
    }

    /// setTextSearchReport records the page's matches and current match for `query` at `revision`, dropped when either
    /// is not the model's, so counts never land under another query. Never emitted, like `setTextLogReport`.
    public func setTextSearchReport(_ id: UUID, revision: Int, query: String, matches: Int, current: Int) {
        updateHtmlOverlay(id) {
            guard $0.searchRevision == revision, var search = $0.textSearch, search.query == query else { return }
            search.matches = matches
            search.current = current
            if search != $0.textSearch { $0.textSearch = search }
        }
    }

    /// textChangesPage finds the local diff page in the slot `pane` addresses, for a change step, with the slot
    /// refusals of `textSearchPage`.
    public func textChangesPage(_ sessionID: UUID, pane: OverlayPane?) -> Result<HtmlOverlay, TextChangesFailure> {
        switch textSearchPage(sessionID, pane: pane) {
        case .failure(.page(let failure)): return .failure(.page(failure))
        case .failure(.remote): return .failure(.remote)
        case .failure: return .failure(.notDiff)
        case .success(let page):
            guard case .text(let path, _) = page.source, page.textLog == nil, TextPage.isDiff(file: path) else {
                return .failure(.notDiff)
            }
            return .success(page)
        }
    }

    /// setTextChangesReport records a diff page's count and current change, nil clearing it while a fresh read is
    /// under way. Never emitted, like `setTextSearchReport`.
    public func setTextChangesReport(_ id: UUID, changes: TextChanges?) {
        updateHtmlOverlay(id) {
            guard case .text = $0.source, $0.textChanges != changes else { return }
            $0.textChanges = changes
        }
    }

    /// htmlOverlaySlot finds the slot holding page `id` in a visible session, nil once the page left it.
    public func htmlOverlaySlot(_ id: UUID) -> (session: Session, pane: OverlayPane?)? {
        for session in workspaces.flatMap(\.sessions) {
            if session.htmlOverlayActive, session.htmlOverlay?.id == id { return (session, nil) }
            if let pane = OverlayPane.allCases.first(where: { session.paneOverlay($0)?.html?.id == id }) {
                return (session, pane)
            }
        }
        return nil
    }

    /// closeHtmlOverlay closes page `id` wherever its slot now is: the toolbar's close button, whose view
    /// cannot trust the pane it was built for after a swap.
    @discardableResult public func closeHtmlOverlay(_ id: UUID) -> Bool {
        guard let slot = htmlOverlaySlot(id) else { return false }
        return slot.pane.map { closePaneOverlay(slot.session.id, pane: $0) } ?? closeOverlay(slot.session.id)
    }

    /// htmlOverlayNodes lists the pages in `session`'s slots, session-wide first: a local page as its web view last
    /// reported it, a page shown on the presenting Mac as that Mac last reported it, with no zoom of this Mac's.
    func htmlOverlayNodes(_ session: Session, zoom: Double?) -> [ControlHtmlOverlayNode]? {
        let remote = Dictionary(remotePageNodes(session).map { ($0.pane, $0.page) }, uniquingKeysWith: { first, _ in first })
        let nodes = ([nil] + OverlayPane.allCases).compactMap { (pane: OverlayPane?) -> ControlHtmlOverlayNode? in
            let local = pane.map { session.paneOverlay($0)?.html } ?? (session.htmlOverlayActive ? session.htmlOverlay : nil)
            if let local { return htmlOverlayNode(local, pane: pane, zoom: zoom, hidden: session.overlayOutOfSight(pane)) }
            guard let page = remote[pane] else { return nil }
            return htmlOverlayNode(page.overlay, pane: pane, zoom: nil, hidden: page.hidden, remote: true)
        }
        return nodes.isEmpty ? nil : nodes
    }

    private func htmlOverlayNode(_ page: HtmlOverlay, pane: OverlayPane?, zoom: Double?, hidden: Bool,
                                 remote: Bool = false) -> ControlHtmlOverlayNode {
        var file: String?, cwd: String?, url: String?, image: String?, markdown: String?, document: String?
        var text: ControlTextOverlayNode?
        switch page.source {
        case .file(let path, let grantRoot): (file, cwd) = (path, grantRoot)
        case .url(let address): url = address.absoluteString
        case .replica(let path, .html): file = path
        case .image(let path), .replica(let path, .image): image = path
        case .markdown(let path), .replica(let path, .markdown): markdown = path
        case .document(let path), .replica(let path, .document): document = path
        case .text(let path, let line), .replica(let path, .text(let line)):
            let log = page.logState
            text = ControlTextOverlayNode(file: path, language: TextPage.language(forFile: path), line: line,
                                          tail: page.textLog?.tail, following: log?.following, lines: log?.report.lines,
                                          clipped: log?.report.clipped, waiting: log?.report.waiting,
                                          unreadable: log?.report.unreadable,
                                          search: page.textSearch.map {
                                              ControlTextSearchNode(query: $0.query, matches: $0.matches, current: $0.current)
                                          },
                                          changes: page.textChanges.map { ControlTextChangesNode(count: $0.count, current: $0.current) })
        }
        return ControlHtmlOverlayNode(pane: pane?.rawValue, file: file, cwd: cwd, url: url, image: image, markdown: markdown, document: document, text: text,
                                      state: page.loadState.rawValue,
                                      error: page.loadError, page: page.current?.page, title: page.current?.title,
                                      canGoBack: page.current?.canGoBack, canGoForward: page.current?.canGoForward,
                                      navigation: page.navigation ? true : nil, javascript: page.javascript,
                                      chromeless: page.chromeless, zoom: zoom, id: page.id.uuidString,
                                      persistent: page.persistent, browse: page.browse, hidden: hidden ? true : nil,
                                      remote: remote ? true : nil, replica: page.replicaOf == nil ? nil : true,
                                      clicked: page.clicked ? true : nil)
    }

    private func htmlOverlay(_ sessionID: UUID, pane: OverlayPane?) -> Result<HtmlOverlay, HtmlOverlayCommandFailure> {
        guard let session = session(withID: sessionID) else { return .failure(.unknownSession) }
        let occupied = pane.map { session.paneOverlay($0) != nil } ?? (session.overlayActive && !session.hudActive)
        guard occupied else { return .failure(.noOverlay) }
        let page = pane.map { session.paneOverlay($0)?.html } ?? session.htmlOverlay
        return page.map { .success($0) } ?? .failure(.notHtml)
    }

    private func updateHtmlOverlay(_ id: UUID, _ change: (inout HtmlOverlay) -> Void) {
        let sessions = workspaces.flatMap(\.sessions) + pendingCloseMembers().map(\.session)
        var replica = false
        for session in sessions where session.updateHtmlOverlay(id, { change(&$0); replica = $0.replicaOf != nil }) {
            if replica { onReplicaPageChanged?(id) }
            return
        }
    }
}
