import AppKit
import WebKit
import agtermCore

/// HtmlOverlayRegistry owns the web view of every open HTML overlay, keyed by the page's id rather than
/// by a host view or a pane, so a page survives remounts, session switches, pane swaps and the soft-close
/// window. It drops a page only when the model releases it through `HtmlOverlayReleases`.
@MainActor
final class HtmlOverlayRegistry {
    static let shared = HtmlOverlayRegistry()
    private var pages: [UUID: HtmlOverlayPage] = [:]
    private var appearanceObserver: NSObjectProtocol?

    /// install connects the model's release signal and the theme refresh; called once at launch.
    func install() {
        HtmlOverlayReleases.shared.onRelease = { [weak self] in self?.release($0) }
        guard appearanceObserver == nil else { return }
        appearanceObserver = NotificationCenter.default.addObserver(forName: .agtermAppearanceChanged, object: nil,
                                                                    queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshThemes() }
        }
    }

    /// page returns the live page for `overlay`, creating and loading its web view on first use.
    /// `backgroundColor` is the overlay's `--background-color`, which replaces the theme background.
    func page(for overlay: HtmlOverlay, store: AppStore, backgroundColor: String? = nil) -> HtmlOverlayPage {
        if let page = pages[overlay.id] { return page }
        let page = HtmlOverlayPage(overlay: overlay, store: store, backgroundColor: backgroundColor,
                                   theme: theme(backgroundColor: backgroundColor))
        pages[overlay.id] = page
        return page
    }

    /// theme is the terminal theme's colors as a page's default style, the overlay's own background first.
    func theme(backgroundColor: String?) -> HtmlOverlayTheme {
        let background = backgroundColor.flatMap { NSColor(agtermHex: $0) } ?? GhosttyApp.shared.terminalBackgroundColor
            ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1)
        let foreground = GhosttyApp.shared.terminalForegroundColor ?? .white
        let srgb = background.usingColorSpace(.sRGB) ?? background
        return HtmlOverlayTheme(background: background.agtermHexString ?? "", foreground: foreground.agtermHexString ?? "",
                                dark: ThemeBrightness.isDark(red: srgb.redComponent, green: srgb.greenComponent,
                                                             blue: srgb.blueComponent),
                                palette: GhosttyApp.shared.terminalPalette)
    }

    private func refreshThemes() {
        for page in pages.values { page.applyTheme(theme(backgroundColor: page.backgroundColor)) }
    }

    func existing(_ id: UUID) -> HtmlOverlayPage? { pages[id] }

    func release(_ id: UUID) {
        pages.removeValue(forKey: id)?.close()
    }

    /// focusCover gives first responder to the page covering `session` and returns true when a page
    /// covers it, mounted or not: the caller must then leave the hidden terminal beneath alone.
    @discardableResult func focusCover(of session: Session) -> Bool {
        guard let overlay = session.topmostHtmlOverlay else { return false }
        if let view = pages[overlay.id]?.webView, let window = view.window, !view.holdsFocus,
           !view.deferFocusToAsk(in: session) {
            window.makeFirstResponder(view)
        }
        return true
    }

    /// refocus returns the keyboard to whatever covers `session` after a cover closed or changed.
    func refocus(_ session: Session) {
        if focusCover(of: session) { return }
        (session.topmostSurface as? GhosttySurfaceView)?.focusAfterReparent()
    }

    /// navigate performs a history step or the browser hand-off on page `id`, the one path the toolbar and
    /// `session.overlay.navigate` share. Returns the refusal, nil on success.
    func navigate(_ id: UUID, _ navigation: HtmlNavigation) -> String? {
        guard let page = pages[id] else { return OverlayHtmlError.notRealized }
        return page.navigate(navigation)
    }

    /// reload is the other shared path: the toolbar reloads the current page, `session.overlay.reload` either.
    /// A page already shown reloads now, even with its pane hidden and no host to push the new revision.
    @discardableResult func reload(sessionID: UUID, pane: OverlayPane?, target: HtmlReloadTarget,
                                   store: AppStore) -> HtmlOverlayCommandFailure? {
        if let failure = store.reloadHtmlOverlay(sessionID, pane: pane, target: target) { return failure }
        let session = store.session(withID: sessionID)
        if let overlay = pane.map({ session?.paneOverlay($0)?.html }) ?? session?.htmlOverlay {
            pages[overlay.id]?.apply(overlay)
        }
        return nil
    }

    @discardableResult func reload(_ id: UUID, target: HtmlReloadTarget, store: AppStore) -> HtmlOverlayCommandFailure? {
        guard let slot = store.htmlOverlaySlot(id) else { return .noOverlay }
        return reload(sessionID: slot.session.id, pane: slot.pane, target: target, store: store)
    }
}

/// HtmlOverlayPage is one page's web view and the delegates that keep the model in step with it: load
/// state, the page and title shown, history, and the navigation policy.
@MainActor
final class HtmlOverlayPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let webView: HtmlOverlayWebView
    let backgroundColor: String?
    private var overlay: HtmlOverlay
    private weak var store: AppStore?
    private var appliedRevision: Int
    private var observations: [NSKeyValueObservation] = []
    // a main-frame load in flight, explicit or started by the page; it must end loaded or failed, so a
    // policy cancel of its redirect reports failed rather than leaving the page loading
    private var loadPending = false
    // a document this web content process still shows, which an interrupted load leaves in place
    private var committed = false

    init(overlay: HtmlOverlay, store: AppStore, backgroundColor: String?, theme: HtmlOverlayTheme) {
        id = overlay.id
        self.overlay = overlay
        self.store = store
        self.backgroundColor = backgroundColor
        appliedRevision = overlay.reloadRevision
        let configuration = WKWebViewConfiguration()
        // an in-memory store per page: cookies and storage last as long as this overlay and reach no other
        configuration.websiteDataStore = .nonPersistent()
        webView = HtmlOverlayWebView(frame: .zero, configuration: configuration)
        webView.pageID = overlay.id
        // WKWebView has no public switch for a transparent canvas; this key lets an unstyled page show the
        // themed panel behind it while authored backgrounds still paint. A URL page keeps the browser's
        // opaque canvas, since a web app styled against it would lose its background here.
        if case .file = overlay.source { webView.setValue(false, forKey: "drawsBackground") }
        super.init()
        applyTheme(theme)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setAccessibilityIdentifier("htmlOverlay.page")
        let id = overlay.id
        webView.onFocus = { [weak store] in
            guard let slot = store?.htmlOverlaySlot(id), let pane = slot.pane else { return }
            slot.session.splitFocused = pane == .right
        }
        // mirrors deferMouseToAsk: a click on a session-wide page beside a pane ask selects the uncovered pane,
        // or the next refocus hands the keys back to the ask
        webView.onClick = { [weak store] in
            guard let slot = store?.htmlOverlaySlot(id), slot.pane == nil, let target = slot.session.askTargetPane else { return }
            slot.session.splitFocused = target == .left
        }
        webView.onUserInput = { [weak store] in store?.noteUserActivity() }
        observations = [
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
        ]
        loadOriginal()
    }

    /// applyTheme sets the theme for later loads and restyles the document already shown; only a file page
    /// takes it as its look, a URL page gets the variables alone.
    func applyTheme(_ theme: HtmlOverlayTheme) {
        let script = theme.script(themed: themed)
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if themed { webView.underPageBackgroundColor = NSColor(agtermHex: theme.background) }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private var themed: Bool {
        if case .file = overlay.source { return true }
        return false
    }

    /// apply takes the model's latest value and reloads when its revision moved.
    func apply(_ overlay: HtmlOverlay) {
        self.overlay = overlay
        guard overlay.reloadRevision != appliedRevision else { return }
        appliedRevision = overlay.reloadRevision
        // before a first commit WebKit has nothing to reload, so the source is loaded again instead
        if overlay.reloadTarget == .current, !textLoaded, webView.url != nil {
            loadPending = true
            webView.reload()
        } else {
            loadOriginal()
        }
    }

    func navigate(_ navigation: HtmlNavigation) -> String? {
        switch navigation {
        case .back:
            guard webView.canGoBack else { return OverlayHtmlError.noHistory(.back) }
            webView.goBack()
        case .forward:
            guard webView.canGoForward else { return OverlayHtmlError.noHistory(.forward) }
            webView.goForward()
        case .browser:
            NSWorkspace.shared.open(pageURL)
        }
        return nil
    }

    func close() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onFocus = nil
        webView.onClick = nil
        webView.onUserInput = nil
        webView.removeFromSuperview()
    }

    // a file page without a grant is loaded from its text: it sits at about:blank and cannot navigate, so
    // the file it came from is both its current page and what the user is looking at
    private var textLoaded: Bool {
        if case .file(_, nil) = overlay.source { return true }
        return false
    }

    private func loadOriginal() {
        loadPending = true
        switch overlay.source {
        case .url(let url):
            webView.load(URLRequest(url: url))
        case .file(let path, let grantRoot?):
            webView.loadFileURL(URL(fileURLWithPath: path), allowingReadAccessTo: URL(fileURLWithPath: grantRoot))
        case .file(let path, nil):
            do {
                webView.loadHTMLString(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), baseURL: nil)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private var pageURL: URL {
        if textLoaded, case .file(let path, _) = overlay.source { return URL(fileURLWithPath: path) }
        if let url = webView.url, url.scheme != "about" { return url }
        switch overlay.source {
        case .file(let path, _): return URL(fileURLWithPath: path)
        case .url(let url): return url
        }
    }

    private func reportPage() {
        guard webView.url != nil else { return }
        let url = pageURL
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        store?.setHtmlPage(id, HtmlPageInfo(page: url.isFileURL ? url.path : url.absoluteString, title: title,
                                            canGoBack: webView.canGoBack, canGoForward: webView.canGoForward))
    }

    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let target: HtmlNavigationTarget = action.targetFrame.map { $0.isMainFrame ? .mainFrame : .subframe } ?? .newWindow
        let userActivated = action.navigationType == .linkActivated
        let decision = HtmlNavigationPolicy.decide(HtmlNavigationAction(url: url, target: target, userActivated: userActivated),
                                                   overlay: overlay)
        if decision == .openExternal { NSWorkspace.shared.open(url) }
        if decision == .cancel, target == .mainFrame, !userActivated, loadPending {
            fail("navigation blocked: \(url.absoluteString)")
        }
        return decision == .allow ? .allow : .cancel
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        loadPending = true
        store?.setHtmlLoadState(id, state: .loading, error: nil)
    }

    func webView(_: WKWebView, didCommit _: WKNavigation!) {
        committed = true
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        loadPending = false
        store?.setHtmlLoadState(id, state: .loaded, error: nil)
        reportPage()
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        committed = false
        fail("web content process terminated")
    }

    // a navigation this policy cancelled, or one superseded by the next, is not a failed page: the policy
    // reports its own cancel of a pending load, and the superseding load has its own outcome
    private func reportFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        // "Frame load interrupted", 102 in the legacy WebKit domain: a policy cancel this page already reported,
        // or WebKit dropping a response it cannot show, which leaves any document already shown in place
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            guard loadPending else { return }
            guard committed else { return fail(nsError.localizedDescription) }
            loadPending = false
            store?.setHtmlLoadState(id, state: .loaded, error: nil)
            reportPage()
            return
        }
        fail(nsError.localizedDescription)
    }

    private func fail(_ message: String) {
        loadPending = false
        store?.setHtmlLoadState(id, state: .failed, error: message)
    }

    func webView(_: WKWebView, createWebViewWith _: WKWebViewConfiguration, for _: WKNavigationAction,
                 windowFeatures _: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_: WKWebView, runJavaScriptAlertPanelWithMessage _: String, initiatedByFrame _: WKFrameInfo) async {}

    func webView(_: WKWebView, runJavaScriptConfirmPanelWithMessage _: String,
                 initiatedByFrame _: WKFrameInfo) async -> Bool { false }

    func webView(_: WKWebView, runJavaScriptTextInputPanelWithPrompt _: String, defaultText _: String?,
                 initiatedByFrame _: WKFrameInfo) async -> String? { nil }

    func webView(_: WKWebView, runOpenPanelWith _: WKOpenPanelParameters,
                 initiatedByFrame _: WKFrameInfo) async -> [URL]? { nil }

    func webView(_: WKWebView, decideMediaCapturePermissionsFor _: WKSecurityOrigin, initiatedBy _: WKFrameInfo,
                 type _: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
}

/// HtmlOverlayWebView reports focus and input to the model: a click on a pane page moves split focus like a
/// click on a pane program does, and typing counts as activity so auto-follow cannot switch sessions.
final class HtmlOverlayWebView: WKWebView {
    var pageID: UUID?
    var onFocus: (() -> Void)?
    var onClick: (() -> Void)?
    var onUserInput: (() -> Void)?
    private var parkedDragTypes: [NSPasteboard.PasteboardType] = []

    /// setDropsEnabled keeps a page that is not on screen out of drag-destination lookup, which SwiftUI
    /// opacity does not do; a rejecting `draggingEntered` would still swallow the drop.
    func setDropsEnabled(_ enabled: Bool) {
        if enabled {
            guard !parkedDragTypes.isEmpty else { return }
            registerForDraggedTypes(parkedDragTypes)
            parkedDragTypes = []
        } else if !registeredDraggedTypes.isEmpty {
            parkedDragTypes = registeredDraggedTypes
            unregisterDraggedTypes()
        }
    }

    /// deferFocusToAsk hands the keyboard to a pending ask or picker that owns this page's slot, as a pane
    /// terminal does, and returns true when it did.
    func deferFocusToAsk(in session: Session) -> Bool {
        let pane = OverlayPane.allCases.first { session.paneOverlay($0)?.html?.id == pageID }
        guard GhosttySurfaceView.pickOwnsFocus(in: window, session: session, pane: pane) else { return false }
        AskKeyCatcher.KeyCatcherView.sessionCatchers.object(forKey: session.id as NSUUID)?.grabFocus()
        return true
    }

    var holdsFocus: Bool {
        (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    override func keyDown(with event: NSEvent) {
        onUserInput?()
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onUserInput?()
        onFocus?()
        onClick?()
        super.mouseDown(with: event)
    }
}
