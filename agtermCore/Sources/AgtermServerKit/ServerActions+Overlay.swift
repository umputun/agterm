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
    /// fetches its content over a page channel. A picture goes with its pixel size so that Mac can size it.
    func openPage(_ page: HtmlSource, in session: Session, options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        var options = options
        switch page {
        case .image(let path):
            switch ImageFile.pixels(path: path) {
            case .failure(let failure): return ControlResponse(ok: false, error: "session.overlay.open: \(failure)")
            case .success(let pixels): options = options.with(imagePixels: pixels)
            }
        case .markdown(let path):
            if case .failure(let failure) = MarkdownFile.check(path: path) {
                return ControlResponse(ok: false, error: "session.overlay.open: \(failure)")
            }
            if options.navigation { options = options.with(markdownLinks: MarkdownPage.linkGrant(for: path)) }
        case .text(let path, _):
            if options.textLog != nil { return ControlResponse(ok: false, error: OverlayHtmlError.logRemote) }
            if case .failure(let failure) = TextProbe.check(path: path) {
                return ControlResponse(ok: false, error: "session.overlay.open: \(failure)")
            }
        case .file, .url, .replica, .document, .unreadable:
            break
        }
        let overlay = HtmlOverlay(source: page, navigation: options.navigation, javascript: options.javascript,
                                  chromeless: options.chromeless, persistent: options.persistent, browse: options.browse,
                                  clicked: options.clicked, textLog: options.textLog, markdownLinks: options.markdownLinks)
        switch store.openRemotePage(session.id, overlay: overlay, options: options) {
        case .opened:
            if page.kind != .url { streams.schedulePageClaimExpiry(after: AppStore.pageClaimWindow) }
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
