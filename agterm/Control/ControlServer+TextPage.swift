import Foundation
import agtermCore

extension ControlServer {
    /// textFileRefusal reads and validates the file on the calling thread, nil when the page can open; a log page reads
    /// only the file's end, so its size is never refused.
    func textFileRefusal(_ path: String, log: TextLog?) -> ControlResponse? {
        let checked = log.map { TextProbe.checkLog(path: path, tail: $0.tail) } ?? TextProbe.check(path: path)
        guard case .failure(let failure) = checked else { return nil }
        return ControlResponse(ok: false, error: "session.overlay.open: \(failure)")
    }

    /// textLogRefusal refuses a log page the placement rule hands to a presenting Mac without live text pages, nil
    /// otherwise: that Mac would show it as a static page, so it is refused rather than changed.
    func textLogRefusal(in store: AppStore, sessionID id: UUID, options: ControlSessionOverlayOpenOptions) -> ControlResponse? {
        guard options.textLog != nil, store.pageBelongsRemote(id, pane: options.pane),
              store.presentationHub?.presenterSupports(PresentationHub.pageTextKind, session: id) != true else { return nil }
        return ControlResponse(ok: false, error: OverlayHtmlError.logRemote)
    }

    /// openTextLink reads and validates the file off the main actor, then rechecks eligibility, since the session
    /// may have changed meanwhile.
    func openTextLink(_ link: LinkPolicy.TextLink, forward: Int? = nil, completion: @escaping @MainActor (Bool) -> Void) {
        let id = link.session
        guard canShowLinkOverlay(session: id, forwarded: forward != nil) else { return completion(false) }
        let path = link.url.path(percentEncoded: false)
        // a presenting Mac without live text pages is handed the plain page it can show
        let log = link.opensAsLog && library.store(forSession: id).map {
            !$0.pageBelongsRemote(id, pane: nil) || $0.presentationHub?.presenterSupports(PresentationHub.pageTextKind, session: id) == true
        } == true
        Task { @MainActor [weak self] in
            let checked = log ? await TextProbe.checkLogDetached(path: path) : await TextProbe.checkDetached(path: path)
            guard let self, case .success = checked, canShowLinkOverlay(session: id, forwarded: forward != nil),
                  forwardIsCurrent(forward, session: id), let store = library.store(forSession: id) else { return completion(false) }
            if forward == nil { releaseHiddenClickedPage(session: id, persistent: false) }
            guard store.session(withID: id)?.overlayHidden(nil) != true else { return completion(false) }
            let page = HtmlSource.text(path: path, line: link.line)
            let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: link.sizePercent,
                                                           backgroundColor: nil, page: page, clicked: true,
                                                           textLog: log ? TextLog(tail: TextPage.defaultTail, follow: true) : nil,
                                                           forwarded: forward != nil)
            completion(openHtmlOverlay(in: store, sessionID: id, page: page, options: options).ok)
        }
    }

    /// setSessionOverlayFollow applies `mode` to the log page in the addressed slot; `result.text` is `following` or
    /// `paused`.
    func setSessionOverlayFollow(_ target: String?, window: String?, pane: OverlayPane?,
                                 mode: ControlToggleMode) async -> ControlResponse {
        await textPageAction(target, window: window, pane: pane, .follow(mode))
    }

    /// setSessionOverlayWrap applies `mode` to the text page in the addressed slot; `result.text` is `wrapped` or
    /// `unwrapped`.
    func setSessionOverlayWrap(_ target: String?, window: String?, pane: OverlayPane?,
                               mode: ControlToggleMode) async -> ControlResponse {
        await textPageAction(target, window: window, pane: pane, .wrap(mode))
    }

    /// searchSessionOverlay sets or closes the query in the model, which reaches the page whenever it exists; a step
    /// goes to the loaded page once and answers `N of M`.
    func searchSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?,
                              request: TextSearchRequest) async -> ControlResponse {
        await textPageAction(target, window: window, pane: pane, .search(request))
    }

    /// stepSessionOverlayChanges moves the loaded diff page once and answers `N of M`.
    func stepSessionOverlayChanges(_ target: String?, window: String?, pane: OverlayPane?,
                                   forward: Bool) async -> ControlResponse {
        await textPageAction(target, window: window, pane: pane, .changes(forward: forward))
    }

    /// textPageAction runs `action` on the text page in the addressed slot: on the presenting Mac when it shows the
    /// page there, here otherwise. Both answer with the same local command, so replies and refusals match.
    private func textPageAction(_ target: String?, window: String?, pane: OverlayPane?,
                                _ action: TextPageAction) async -> ControlResponse {
        let store: AppStore, id: UUID
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let response): return response
        case .success(let resolved): (store, id) = resolved
        }
        switch await store.remoteTextAction(id, pane: pane, action) {
        case .local: return await runTextPageAction(action, in: store, sessionID: id, pane: pane)
        case .failed(let error): return ControlResponse(ok: false, error: error)
        case .answered(let result):
            guard result.ok else { return ControlResponse(ok: false, error: result.error) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: result.text))
        }
    }

    /// runTextPageAction runs `action` on the text page this Mac shows in `pane`'s slot of session `id`.
    func runTextPageAction(_ action: TextPageAction, in store: AppStore, sessionID id: UUID,
                           pane: OverlayPane?) async -> ControlResponse {
        switch action {
        case .follow(let mode):
            switch store.setTextLogFollowing(id, pane: pane, mode: mode) {
            case .failure(let failure): return ControlResponse(ok: false, error: failure.message)
            case .success(let following):
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: following ? "following" : "paused"))
            }
        case .wrap(let mode):
            switch store.setTextWrap(id, pane: pane, mode: mode) {
            case .failure(let failure): return ControlResponse(ok: false, error: failure.message)
            case .success(let wrapped):
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: wrapped ? "wrapped" : "unwrapped"))
            }
        case .search(let request): return await searchTextPage(request, in: store, sessionID: id, pane: pane)
        case .changes(let forward): return await stepTextChanges(forward: forward, in: store, sessionID: id, pane: pane)
        }
    }

    private func searchTextPage(_ request: TextSearchRequest, in store: AppStore, sessionID id: UUID,
                                pane: OverlayPane?) async -> ControlResponse {
        let page: HtmlOverlay
        switch store.textSearchPage(id, pane: pane) {
        case .failure(let failure): return ControlResponse(ok: false, error: failure.message)
        case .success(let found): page = found
        }
        let forward: Bool
        switch request {
        case .query(let query):
            store.setTextSearch(page.id, query: query)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        case .close:
            store.setTextSearch(page.id, query: "")
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        case .next: forward = true
        case .previous: forward = false
        }
        guard let query = page.textSearch?.query else { return ControlResponse(ok: false, error: TextSearchFailure.noQuery.message) }
        guard let bridge = HtmlOverlayRegistry.shared.existing(page.id)?.textPage else {
            return ControlResponse(ok: false, error: TextSearchFailure.notLoaded.message)
        }
        switch await bridge.step(forward: forward, query: query, revision: page.searchRevision) {
        case .failure(let failure): return ControlResponse(ok: false, error: failure.message)
        case .success(let found): return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: "\(found.current) of \(found.matches)"))
        }
    }

    private func stepTextChanges(forward: Bool, in store: AppStore, sessionID id: UUID,
                                 pane: OverlayPane?) async -> ControlResponse {
        let page: HtmlOverlay
        switch store.textChangesPage(id, pane: pane) {
        case .failure(let failure): return ControlResponse(ok: false, error: failure.message)
        case .success(let found): page = found
        }
        guard let bridge = HtmlOverlayRegistry.shared.existing(page.id)?.textPage else {
            return ControlResponse(ok: false, error: TextChangesFailure.notLoaded.message)
        }
        switch await bridge.stepChange(forward: forward) {
        case .failure(let failure): return ControlResponse(ok: false, error: failure.message)
        case .success(let found): return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: "\(found.current) of \(found.count)"))
        }
    }
}
