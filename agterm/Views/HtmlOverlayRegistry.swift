import AppKit
import WebKit
import agtermCore

/// HtmlOverlayRegistry owns the web view of every open HTML overlay, keyed by the page's id rather than
/// by a host view or a pane, so a page survives remounts, session switches, pane swaps and the soft-close
/// window. It drops a page only when the model releases it through `HtmlOverlayReleases`.
@MainActor
final class HtmlOverlayRegistry {
    static let shared = HtmlOverlayRegistry()
    /// browser receives every URL a page hands off; pages created later use whatever is set here.
    var browser: any HtmlBrowser = SystemBrowser()
    var sharing: any HtmlSharing = SystemHtmlSharing()
    /// zoom is the page zoom every page shows at, pushed by `SettingsModel`.
    private(set) var zoom = 1.0
    /// dispatch runs the requests pages send; `ControlServer` supplies it, and pages read it when a request arrives.
    var dispatch: HtmlBridgeDispatch?
    /// windowID names the window a store belongs to, so a page's untargeted request stays in its own window.
    var windowID: (@MainActor (AppStore) -> String?)?
    /// profile names the saved browser store of this state directory; setting it drops the store built
    /// from the one before.
    var profile: BrowserProfile? { didSet { persistentStore = nil } }
    private var persistentStore: WKWebsiteDataStore?
    /// removeWebsiteData empties a store and returns once WebKit is done.
    var removeWebsiteData: @MainActor (WKWebsiteDataStore) async -> Void = {
        await $0.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    // the main actor is free while WebKit removes data, so a page opened then would write into the store
    // being emptied
    private var clearing = false
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
                                   theme: theme(backgroundColor: backgroundColor), browser: browser, sharing: sharing,
                                   storage: storage(for: overlay))
        page.webView.pageZoom = zoom
        pages[overlay.id] = page
        return page
    }

    /// persistentStoreFailure builds the saved store on first use and says why it cannot be used, nil when
    /// it can. The open adapter asks before it accepts a persistent page, so the refusal reaches the caller.
    func persistentStoreFailure() -> String? {
        if clearing { return BrowserClearError.clearing }
        guard persistentStore == nil else { return nil }
        guard let profile else { return OverlayHtmlError.persistentUnavailable }
        do {
            persistentStore = WKWebsiteDataStore(forIdentifier: try profile.identifier())
            return nil
        } catch let failure as BrowserProfile.Failure {
            return failure.description
        } catch {
            return error.localizedDescription
        }
    }

    /// clearPersistentStore removes everything the saved store holds and says why it could not, nil when it
    /// did. A profile never created has nothing to remove and is not created for it. A registered persistent
    /// page blocks it, a soft-closed one included: its login lives in memory and would be written back.
    func clearPersistentStore() async -> String? {
        if clearing { return BrowserClearError.clearing }
        let open = pages.values.filter(\.usesSavedStore).count
        if open > 0 { return BrowserClearError.pagesOpen(open) }
        guard let profile else { return OverlayHtmlError.persistentUnavailable }
        do {
            guard try profile.existingIdentifier() != nil else { return nil }
        } catch let failure as BrowserProfile.Failure {
            return failure.description
        } catch {
            return error.localizedDescription
        }
        if let failure = persistentStoreFailure() { return failure }
        guard let persistentStore else { return OverlayHtmlError.persistentUnavailable }
        clearing = true
        defer { clearing = false }
        await removeWebsiteData(persistentStore)
        return nil
    }

    // a persistent page whose store cannot be used gets no store at all: an in-memory one would hold a
    // login the user asked to keep
    private func storage(for overlay: HtmlOverlay) -> HtmlOverlayPage.Storage {
        guard overlay.persistent, case .url = overlay.source else { return .ready(.nonPersistent()) }
        if let failure = persistentStoreFailure() { return .unavailable(failure) }
        return persistentStore.map(HtmlOverlayPage.Storage.ready) ?? .unavailable(OverlayHtmlError.persistentUnavailable)
    }

    func setZoom(_ zoom: Double) {
        self.zoom = zoom
        for page in pages.values { page.webView.pageZoom = zoom }
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

    /// navigate shares the toolbar's history and hand-off actions with the control API.
    func navigate(_ id: UUID, _ navigation: HtmlNavigation) -> String? {
        guard let page = pages[id] else { return OverlayHtmlError.notRealized }
        return page.navigate(navigation)
    }

    func copyLink(_ id: UUID) {
        pages[id]?.copyLink()
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
    /// Storage is the browser store a page is built on, or the reason it has none and loads nothing.
    enum Storage {
        case ready(WKWebsiteDataStore)
        case unavailable(String)
    }

    let id: UUID
    let webView: HtmlOverlayWebView
    let backgroundColor: String?
    private var overlay: HtmlOverlay
    private weak var store: AppStore?
    private var appliedRevision: Int
    private let browser: any HtmlBrowser
    private let sharing: any HtmlSharing
    private var prompt: UUID?
    private var dismissPrompt: (() -> Void)?
    // a declined prompt silences the page until real input reaches its view: script can click links in a
    // loop, but it cannot make native mouse or key events
    private var promptsSilenced = false
    private var onScreen = true
    private var theme: HtmlOverlayTheme
    private static let themeWorld = WKContentWorld.world(name: "agterm-theme")
    private var observations: [NSKeyValueObservation] = []
    // a main-frame load in flight, explicit or started by the page; it must end loaded or failed, so a
    // policy cancel of its redirect reports failed rather than leaving the page loading
    private var loadPending = false
    // a document this web content process still shows, which an interrupted load leaves in place
    private var committed = false
    // stays set while the session sits in an undoable close, where no slot is found to close, so a
    // restored page closes at its next mount
    private var closeRequested = false
    private let storageFailure: String?
    /// usesSavedStore is true for a page built on the saved browser store.
    let usesSavedStore: Bool

    init(overlay: HtmlOverlay, store: AppStore, backgroundColor: String?, theme: HtmlOverlayTheme,
         browser: any HtmlBrowser, sharing: any HtmlSharing, storage: Storage) {
        id = overlay.id
        self.browser = browser
        self.sharing = sharing
        self.overlay = overlay
        self.store = store
        self.backgroundColor = backgroundColor
        appliedRevision = overlay.reloadRevision
        self.theme = theme
        let configuration = WKWebViewConfiguration()
        switch storage {
        case .ready(let dataStore):
            configuration.websiteDataStore = dataStore
            storageFailure = nil
            usesSavedStore = dataStore.isPersistent
        case .unavailable(let failure):
            configuration.websiteDataStore = .nonPersistent()
            storageFailure = failure
            usesSavedStore = false
        }
        // the page's own scripts only; the theme user script and app evaluation run either way
        configuration.defaultWebpagePreferences.allowsContentJavaScript = overlay.javascript
        webView = HtmlOverlayWebView(frame: .zero, configuration: configuration)
        webView.pageID = overlay.id
        // WKWebView has no public switch for a transparent canvas; this key lets an unstyled page show the
        // themed panel behind it while authored backgrounds still paint. A URL page keeps the browser's
        // opaque canvas, since a web app styled against it would lose its background here.
        if case .file = overlay.source { webView.setValue(false, forKey: "drawsBackground") }
        super.init()
        installScripts()
        if themed {
            let handler = HtmlOverlayBridgeHandler()
            handler.page = self
            let controller = webView.configuration.userContentController
            controller.addScriptMessageHandler(handler, contentWorld: HtmlOverlayBridge.world, name: HtmlOverlayBridge.handlerName)
            if overlay.javascript {
                controller.addScriptMessageHandler(handler, contentWorld: .page, name: HtmlOverlayBridge.handlerName)
            }
        }
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
        // a split collapse or pane move takes the view out of its window with no visibility update
        webView.onDetach = { [weak self] in self?.endPrompt() }
        webView.onUserInput = { [weak self, weak store] in
            self?.promptsSilenced = false
            store?.noteUserActivity()
        }
        observations = [
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
        ]
        loadOriginal()
    }

    /// applyTheme gives later loads a changed theme. A file page wears it and reloads what it shows; a URL page
    /// gets the variables alone, at its next load. Nothing runs in the live document: script the app evaluates
    /// there carries a user gesture that the page's own code can borrow.
    func applyTheme(_ theme: HtmlOverlayTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        installScripts()
        if themed { reloadShown() }
    }

    // one set, because removing user scripts removes them all: the theme, and on a file page the bridge adapter
    private func installScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: theme.script(themed: themed), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.themeWorld))
        guard themed else { return }
        controller.addUserScript(WKUserScript(source: HtmlOverlayBridge.adapterScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: HtmlOverlayBridge.world))
        if overlay.javascript {
            controller.addUserScript(WKUserScript(source: HtmlOverlayBridge.helperScript, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
        webView.underPageBackgroundColor = NSColor(agtermHex: theme.background)
    }

    /// handleBridgeRequest runs one request the page sent and answers it through `reply` exactly once.
    /// The page is resolved where it sits NOW, so a request after a swap or a move acts from its new place, and a
    /// page that left its slot is refused before anything runs.
    func handleBridgeRequest(_ body: Any, mainFrame: Bool, reply: @escaping @MainActor (Any?, String?) -> Void) {
        guard mainFrame else { return reply(nil, "requests from frames are refused") }
        guard let store, let slot = store.htmlOverlaySlot(id) else { return reply(nil, "page closed") }
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body) else {
            return reply(nil, "invalid request")
        }
        let registry = HtmlOverlayRegistry.shared
        let origin = HtmlBridgePage(window: registry.windowID?(store), session: slot.session.id, pane: slot.pane)
        let request: ControlRequest
        switch HtmlBridge.request(from: data, page: origin) {
        case .success(let built): request = built
        case .failure(let refusal): return reply(nil, refusal.message)
        }
        guard let dispatch = registry.dispatch else { return reply(nil, "control is unavailable") }
        Task {
            let (value, error) = HtmlOverlayBridge.reply(await dispatch(request))
            reply(value, error)
        }
    }

    private var themed: Bool {
        if case .file = overlay.source { return true }
        return false
    }

    /// apply takes the model's latest value and reloads when its revision moved. It also finishes a close
    /// the page asked for while its session was hidden.
    func apply(_ overlay: HtmlOverlay) {
        self.overlay = overlay
        closeIfRequested()
        guard overlay.reloadRevision != appliedRevision else { return }
        appliedRevision = overlay.reloadRevision
        if overlay.reloadTarget == .current { reloadShown() } else { loadOriginal() }
    }

    private func reloadShown() {
        // before a first commit WebKit has nothing to reload, so the source is loaded again instead
        if !textLoaded, committed {
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
            guard browser.open(browserURL) else { return OverlayHtmlError.noBrowser }
        case .finder:
            guard case .file = overlay.source else { return OverlayHtmlError.finderRequiresFile }
            sharing.reveal(pageURL)
        }
        return nil
    }

    func copyLink() {
        sharing.copy(browserURL.absoluteString)
    }

    /// setOnScreen takes whether the page is shown; a page out of sight asks nothing, and its pending prompt
    /// goes with it.
    func setOnScreen(_ onScreen: Bool) {
        self.onScreen = onScreen
        if !onScreen { endPrompt() }
    }

    func close() {
        endPrompt()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onFocus = nil
        webView.onClick = nil
        webView.onUserInput = nil
        webView.onDetach = nil
        webView.removeFromSuperview()
    }

    // a file page without a grant is loaded from its text: it sits at about:blank and cannot navigate, so
    // the file it came from is both its current page and what the user is looking at
    private var textLoaded: Bool {
        if case .file(_, nil) = overlay.source { return true }
        return false
    }

    private func loadOriginal() {
        if let storageFailure { return fail(storageFailure) }
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

    // a file page opens its own file, never one it navigated to; a URL page opens what it shows, which its
    // policy keeps to HTTP(S)
    private var browserURL: URL {
        switch overlay.source {
        case .file(let path, _):
            return URL(fileURLWithPath: path)
        case .url(let original):
            guard let url = webView.url, url.scheme == "http" || url.scheme == "https" else { return original }
            return url
        }
    }

    // a page's own hand-off asks first, one prompt at a time; a request while one is up is dropped
    private func askToOpen(_ url: URL) {
        guard onScreen, prompt == nil, !promptsSilenced else { return }
        let token = UUID()
        prompt = token
        let dismiss = browser.confirm(url, over: webView) { [weak self] approved in self?.answer(token, url, approved) }
        guard prompt == token else { return }
        guard let dismiss else {
            prompt = nil
            return
        }
        dismissPrompt = dismiss
    }

    private func answer(_ token: UUID, _ url: URL, _ approved: Bool) {
        guard prompt == token else { return }
        prompt = nil
        dismissPrompt = nil
        if approved {
            _ = browser.open(url)
        } else {
            promptsSilenced = true
        }
    }

    private func endPrompt() {
        let dismiss = dismissPrompt
        prompt = nil
        dismissPrompt = nil
        dismiss?()
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
        if decision == .openExternal { askToOpen(url) }
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
        // a clicked link's redirect handed to the browser, or WebKit dropping a response it cannot show; each
        // leaves any document already shown in place
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

    /// webViewDidClose closes the overlay of a page whose `window.close()` WebKit accepted, as the panel's
    /// close button does.
    func webViewDidClose(_: WKWebView) {
        closeRequested = true
        closeIfRequested()
    }

    // deferred because the close releases this page, clearing the delegate WebKit is calling through
    private func closeIfRequested() {
        guard closeRequested else { return }
        Task { [weak self] in
            guard let self, closeRequested else { return }
            store?.closeHtmlOverlay(id)
        }
    }

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

@MainActor
protocol HtmlSharing {
    func reveal(_ url: URL)
    func copy(_ text: String)
}

struct SystemHtmlSharing: HtmlSharing {
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// HtmlBrowser hands a page's URLs to the user's web browser. `confirm` puts a nonblocking prompt over `view`,
/// calls `done` once with the answer, and returns what dismisses it, or nil when it could show nothing.
@MainActor
protocol HtmlBrowser {
    func confirm(_ url: URL, over view: NSView, _ done: @escaping (Bool) -> Void) -> (() -> Void)?
    func open(_ url: URL) -> Bool
}

/// SystemBrowser opens with the default web browser whatever the URL's type, so a file shows as a page rather
/// than going to the app its type maps to.
struct SystemBrowser: HtmlBrowser {
    func confirm(_ url: URL, over view: NSView, _ done: @escaping (Bool) -> Void) -> (() -> Void)? {
        guard let window = view.window, window.attachedSheet == nil else { return nil }
        let alert = NSAlert()
        alert.messageText = "Open \(HtmlSource.origin(of: url) ?? url.absoluteString) in your browser?"
        alert.informativeText = url.absoluteString
        // cancel first makes it the Return default, so typing meant for the page cannot approve a surprise prompt
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        alert.beginSheetModal(for: window) { done($0 == .alertSecondButtonReturn) }
        return { [weak window] in window?.endSheet(alert.window, returnCode: .abort) }
    }

    func open(_ url: URL) -> Bool {
        guard let web = URL(string: "https://example.com"), let app = NSWorkspace.shared.urlForApplication(toOpen: web) else {
            return false
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

/// HtmlOverlayWebView reports focus and input to the model: a click on a pane page moves split focus like a
/// click on a pane program does, and typing counts as activity so auto-follow cannot switch sessions.
final class HtmlOverlayWebView: WKWebView {
    var pageID: UUID?
    var onFocus: (() -> Void)?
    var onClick: (() -> Void)?
    var onUserInput: (() -> Void)?
    var onDetach: (() -> Void)?
    private var parkedDragTypes: [NSPasteboard.PasteboardType] = []
    private var dropsEnabled = true

    /// setDropsEnabled keeps a page that is not on screen out of drag-destination lookup, which SwiftUI
    /// opacity does not do; a rejecting `draggingEntered` would still swallow the drop.
    func setDropsEnabled(_ enabled: Bool) {
        dropsEnabled = enabled
        if enabled {
            guard !parkedDragTypes.isEmpty else { return }
            registerForDraggedTypes(parkedDragTypes)
            parkedDragTypes = []
        } else if !registeredDraggedTypes.isEmpty {
            parkedDragTypes = registeredDraggedTypes
            unregisterDraggedTypes()
        }
    }

    // a web view answers AppKit's drag-destination lookup for any point in its frame, whatever types it has
    // registered, so parking them is not enough: an off-screen page declines here and AppKit moves on to the
    // views stacked beneath it; the selector is absent from the headers, so forwarding uses the base IMP
    @objc(_hitTest:dragTypes:) func dragDestination(at point: UnsafeMutablePointer<NSPoint>, types: NSSet) -> NSView? {
        let selector = #selector(dragDestination(at:types:))
        guard dropsEnabled, let method = class_getInstanceMethod(WKWebView.self, selector) else { return nil }
        typealias Lookup = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
        return unsafeBitCast(method_getImplementation(method), to: Lookup.self)(self, selector, point, types)
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onDetach?() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    // a dropped or pasted file reaches the page's script with its contents, so a drag or paste carrying files
    // is refused while text and links still go through; in a terminal the same paste gives only a path
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.carriesFiles(sender.draggingPasteboard) ? [] : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.carriesFiles(sender.draggingPasteboard) ? [] : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.carriesFiles(sender.draggingPasteboard) ? false : super.performDragOperation(sender)
    }

    // the paste selectors are absent from Swift's WKWebView interface, so forwarding uses the base IMP
    @objc(paste:) func pasteRefusingFiles(_ sender: Any?) {
        forwardPaste(#selector(pasteRefusingFiles(_:)), sender)
    }

    @objc(pasteAsPlainText:) func pasteAsPlainTextRefusingFiles(_ sender: Any?) {
        forwardPaste(#selector(pasteAsPlainTextRefusingFiles(_:)), sender)
    }

    @objc(readSelectionFromPasteboard:) func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let selector = #selector(readSelection(from:))
        guard !Self.carriesFiles(pasteboard), let method = class_getInstanceMethod(WKWebView.self, selector) else { return false }
        typealias Read = @convention(c) (AnyObject, Selector, NSPasteboard) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Read.self)(self, selector, pasteboard)
    }

    private func forwardPaste(_ selector: Selector, _ sender: Any?) {
        guard !Self.carriesFiles(.general), let method = class_getInstanceMethod(WKWebView.self, selector) else {
            return NSSound.beep()
        }
        typealias Paste = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(method_getImplementation(method), to: Paste.self)(self, selector, sender as AnyObject?)
    }

    private static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        let promises = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.types?.contains(where: promises.contains) == true
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
