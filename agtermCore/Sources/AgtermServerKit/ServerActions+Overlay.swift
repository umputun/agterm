import Foundation
import agtermCore

/// Overlays on agterm-server are drawn by the Mac presenting the session: a program runs here through the job its
/// helper claims, and every follow-up goes to that Mac through the core remote paths.
extension ServerActions {
    public func openSessionOverlay(_ target: String?, window: String?, options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        withSession(target, window: window) { session in
            if session.overlayHidden(options.pane) { return ControlResponse(ok: false, error: OverlayVisibilityError.hidden) }
            if let page = options.page { return openPage(page, in: session, options: options) }
            return openProgram(in: session, options: options)
        }
    }

    func openProgram(in session: Session, options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let context = OverlayLaunchContext(
            command: options.command,
            cwd: OverlayLaunchContext.cwd(explicit: options.cwd, session: session, homeDirectory: home),
            sessionEnvironment: panes.agtermEnvironment(session: session.id, workspace: store.workspace(forSession: session.id)?.id))
        switch store.openRemoteOverlay(session.id, options: options, context: context) {
        case .notPresented:
            return ControlResponse(ok: false, error: "no connected Mac to show the overlay")
        case .slotTaken:
            return ControlResponse(ok: false, error: options.pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen)
        case .paneMissing:
            return ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible)
        case .tooLarge:
            return ControlResponse(ok: false, error: OverlayResultError.tooLarge)
        case .pointsUnsupported:
            return ControlResponse(ok: false, error: OverlayPointError.remote)
        case .opened:
            streams.scheduleOverlayJobExpiry(after: OverlayJobs.launchWindow)
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    /// openPage checks a file page's file here, where it lives, then hands the page to the presenting Mac, which
    /// fetches its content over a page channel.
    func openPage(_ page: HtmlSource, in session: Session, options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        // with no Mac connected the log page waits for one; a connected one without live text pages would show it static
        if options.textLog != nil, let hub = store.presentationHub, hub.hasPresenter(session: session.id),
           !hub.presenterSupports(PresentationHub.pageTextKind, session: session.id) {
            return ControlResponse(ok: false, error: OverlayHtmlError.logRemote)
        }
        let checked: ControlSessionOverlayOpenOptions
        switch Self.checkedPage(page, options: options) {
        case .failure(let failure): return ControlResponse(ok: false, error: "session.overlay.open: \(failure.message)")
        case .success(let options): checked = options
        }
        let overlay = Self.pageOverlay(page, options: checked)
        switch streams.handOver(overlay, in: session, options: checked) {
        case .opened:
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString, pageID: overlay.id.uuidString))
        case .local: return ControlResponse(ok: false, error: "no connected Mac to show the page")
        case .slotTaken: return ControlResponse(ok: false, error: options.pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen)
        case .paneMissing: return ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible)
        case .unsupported: return ControlResponse(ok: false, error: "the connected Mac cannot show this page")
        case .loopback:
            return ControlResponse(ok: false, error: "a loopback url names agterm-server's host, so the Mac presenting the session cannot load it")
        case .tooLarge: return ControlResponse(ok: false, error: OverlayHtmlError.remoteTooLarge)
        case .pointsUnsupported: return ControlResponse(ok: false, error: OverlayPointError.remote)
        }
    }

    /// PageCheckFailure is why a file page's file cannot be shown.
    struct PageCheckFailure: Error, Equatable {
        let message: String
    }

    /// checkedPage reads a file page's file and returns the options the page opens with: a picture's pixel size,
    /// so the presenting Mac can size it, and a markdown page's link grant when it navigates. It touches only the
    /// file, so a click runs it off the main actor.
    nonisolated static func checkedPage(_ page: HtmlSource, options: ControlSessionOverlayOpenOptions)
        -> Result<ControlSessionOverlayOpenOptions, PageCheckFailure> {
        switch page {
        case .image(let path):
            switch ImageFile.pixels(path: path) {
            case .failure(let failure): return .failure(PageCheckFailure(message: "\(failure)"))
            case .success(let pixels): return .success(options.with(imagePixels: pixels))
            }
        case .markdown(let path):
            if case .failure(let failure) = MarkdownFile.check(path: path) { return .failure(PageCheckFailure(message: "\(failure)")) }
            return .success(options.navigation ? options.with(markdownLinks: MarkdownPage.linkGrant(for: path)) : options)
        case .text(let path, _):
            let checked = options.textLog.map { TextProbe.checkLog(path: path, tail: $0.tail) } ?? TextProbe.check(path: path)
            if case .failure(let failure) = checked { return .failure(PageCheckFailure(message: "\(failure)")) }
            return .success(options)
        case .document(let path):
            guard case .success(let data) = BoundedFile.read(path: path, maxBytes: DocumentPage.maxBytes), DocumentPage.page(data) != nil
            else { return .failure(PageCheckFailure(message: "not a readable UTF-8 html file: \(path)")) }
            return .success(options)
        case .file, .url, .replica, .unreadable:
            return .success(options)
        }
    }

    static func pageOverlay(_ page: HtmlSource, options: ControlSessionOverlayOpenOptions) -> HtmlOverlay {
        HtmlOverlay(source: page, navigation: options.navigation, javascript: options.javascript, chromeless: options.chromeless,
                    persistent: options.persistent, browse: options.browse, clicked: options.clicked, textLog: options.textLog,
                    markdownLinks: options.markdownLinks)
    }

    /// setSessionOverlayVisibility hides or shows the pages shown on the presenting Mac, as a Mac origin does; a program
    /// runs here only as that Mac's reservation, which neither origin hides.
    public func setSessionOverlayVisibility(_ target: String?, window: String?, pane: OverlayPane?,
                                            mode: OverlayVisibilityMode) -> ControlResponse {
        withSession(target, window: window) { session in
            if let failure = store.applyOverlayVisibility(session.id, pane: pane, mode: mode) {
                return ControlResponse(ok: false, error: failure.message)
            }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString, text: session.anyOverlayShown(pane) ? "shown" : "hidden"))
        }
    }

    public func reloadSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, current: Bool) -> ControlResponse {
        withSession(target, window: window) { session in
            pageCommandResponse(store.reloadRemotePage(session.id, pane: pane, current: current), session: session, pane: pane)
        }
    }

    public func navigateSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?,
                                       navigation: HtmlNavigation) -> ControlResponse {
        withSession(target, window: window) { session in
            pageCommandResponse(store.navigateRemotePage(session.id, pane: pane, navigation: navigation), session: session, pane: pane)
        }
    }

    public func submitSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, value: String) -> ControlResponse {
        withSession(target, window: window) { session in
            if let failure = store.submitHtmlOverlay(session.id, pane: pane, value: value) {
                return ControlResponse(ok: false, error: failure.message)
            }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    /// setSessionOverlayFollow sets following on the log page the presenting Mac shows in the addressed slot.
    public func setSessionOverlayFollow(_ target: String?, window: String?, pane: OverlayPane?,
                                        mode: ControlToggleMode) async -> ControlResponse {
        await textPageAction(target, window: window, pane: pane, .follow(mode))
    }

    /// setSessionOverlayWrap sets wrapping on the text page the presenting Mac shows in the addressed slot.
    public func setSessionOverlayWrap(_ target: String?, window: String?, pane: OverlayPane?,
                                      mode: ControlToggleMode) async -> ControlResponse {
        await textPageAction(target, window: window, pane: pane, .wrap(mode))
    }

    /// searchSessionOverlay sets, steps or closes the search on the text page the presenting Mac shows.
    public func searchSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?,
                                     request: TextSearchRequest) async -> ControlResponse {
        await textPageAction(target, window: window, pane: pane, .search(request))
    }

    /// stepSessionOverlayChanges steps the diff page the presenting Mac shows.
    public func stepSessionOverlayChanges(_ target: String?, window: String?, pane: OverlayPane?,
                                          forward: Bool) async -> ControlResponse {
        await textPageAction(target, window: window, pane: pane, .changes(forward: forward))
    }

    // a server shows no page itself, so an action the presenting Mac cannot run gets the store's refusal for the slot
    private func textPageAction(_ target: String?, window: String?, pane: OverlayPane?,
                                _ action: TextPageAction) async -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        let session: Session
        switch resolveSession(target) {
        case .success(let found): session = found
        case .failure(let refusal): return refusal.response
        }
        if let reply = await store.remoteTextAction(session.id, pane: pane, action).response(session: session.id) { return reply }
        var failure = OverlayHtmlError.notHtml
        switch action {
        case .follow(let mode): if case .failure(let refused) = store.setTextLogFollowing(session.id, pane: pane, mode: mode) { failure = refused.message }
        case .wrap(let mode): if case .failure(let refused) = store.setTextWrap(session.id, pane: pane, mode: mode) { failure = refused.message }
        case .search: if case .failure(let refused) = store.textSearchPage(session.id, pane: pane) { failure = refused.message }
        case .changes: if case .failure(let refused) = store.textChangesPage(session.id, pane: pane) { failure = refused.message }
        }
        return ControlResponse(ok: false, error: failure)
    }

    // `local` means no page is handed out on the slot, which on a headless origin means there is no page at all
    private func pageCommandResponse(_ command: RemotePageCommand, session: Session, pane: OverlayPane?) -> ControlResponse {
        switch command {
        case .sent: ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        case .refused(let error): ControlResponse(ok: false, error: error)
        case .local: ControlResponse(ok: false, error: store.htmlOverlayCommandFailure(session.id, pane: pane)?.message ?? OverlayHtmlError.notHtml)
        }
    }

    /// closeSessionOverlay closes the remote overlay on the slot, or a HUD in the session-wide one.
    public func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        withSession(target, window: window) { session in
            guard store.closeRemoteOverlay(session.id, pane: pane) || (pane == nil && store.closeOverlay(session.id)) else {
                return ControlResponse(ok: false, error: "no overlay")
            }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    public func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse {
        resizeSessionOverlay(target, window: window, sizePercent: sizePercent, points: OverlayPointSize())
    }

    public func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?,
                                     points: OverlayPointSize) -> ControlResponse {
        withSession(target, window: window) { session in
            guard let resized = store.resizeRemoteOverlay(session.id, sizePercent: sizePercent, points: points) else {
                return resizeHud(session, sizePercent: sizePercent, points: points)
            }
            if let error = resized.error { return ControlResponse(ok: false, error: error) }
            return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
        }
    }

    /// resizeHud records a HUD's new width and republishes it, keeping its deadline; the presenting Mac measures
    /// the height that width needs, as it does on open.
    private func resizeHud(_ session: Session, sizePercent: Int?, points: OverlayPointSize) -> ControlResponse {
        guard session.hudActive else { return ControlResponse(ok: false, error: "no overlay") }
        if !points.isEmpty { return ControlResponse(ok: false, error: OverlayPointResizeFailure.hud.message) }
        guard let sizePercent else { return ControlResponse(ok: false, error: OverlayHudError.fullResize) }
        store.resizeOverlay(session.id, sizePercent: sizePercent)
        store.publishHudResize(forSession: session.id)
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
    }

    public func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        withSession(target, window: window) { $0.overlayResult(pane: pane) }
    }
}
