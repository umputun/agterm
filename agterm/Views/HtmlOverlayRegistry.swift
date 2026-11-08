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
    /// closePageSession returns whether a page row's close was handled, a cancelled confirmation included.
    var closePageSession: (@MainActor (AppStore, UUID) -> Bool)?
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
    /// `replica` is the way back to the Mac that opened a page shown here for it.
    func page(for overlay: HtmlOverlay, store: AppStore, backgroundColor: String? = nil,
              replica: HtmlReplicaLink? = nil) -> HtmlOverlayPage {
        if let page = pages[overlay.id] { return page }
        let page = HtmlOverlayPage(overlay: overlay, store: store, backgroundColor: backgroundColor,
                                   theme: theme(backgroundColor: backgroundColor), browser: browser, sharing: sharing,
                                   storage: storage(for: overlay), replica: replica)
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

    /// retryPageCloses asks again for every page row close of `store` that a pending picker refused.
    func retryPageCloses(in store: AppStore) {
        for page in pages.values { page.retryClose(in: store) }
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
    private static let markdownWorld = WKContentWorld.world(name: "agterm-markdown")
    private var observations: [NSKeyValueObservation] = []
    // a main-frame load in flight, explicit or started by the page; it must end loaded or failed, so a
    // policy cancel of its redirect reports failed rather than leaving the page loading
    private var loadPending = false
    // a document this web content process still shows, which an interrupted load leaves in place
    private var committed = false
    // the address of the document a browsing page shows; nil until its first commit, when the page
    // reports its source instead
    private var shownURL: URL?
    // stays set while the session sits in an undoable close, where no slot is found to close, so a
    // restored page closes at its next mount; a page row's stays set while its window's picker refuses the
    // session close, and is spent once that close accepts it, confirmed or cancelled
    private var closeRequested = false
    // an image, markdown, text or document page reads its file off the main actor; a result is applied only while this still
    // counts the load that started it, so a close or a newer reload drops a slow read's late result
    private var textLoad = 0
    private(set) var textPage: TextPageBridge?
    private let storageFailure: String?
    private let replica: HtmlReplicaLink?
    private let revision: HtmlReplicaRevision
    /// usesSavedStore is true for a page built on the saved browser store.
    let usesSavedStore: Bool

    init(overlay: HtmlOverlay, store: AppStore, backgroundColor: String?, theme: HtmlOverlayTheme,
         browser: any HtmlBrowser, sharing: any HtmlSharing, storage: Storage, replica: HtmlReplicaLink? = nil) {
        id = overlay.id
        self.replica = replica
        let revision = HtmlReplicaRevision()
        revision.value = overlay.reloadRevision
        self.revision = revision
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
        if case .replica = overlay.source, let replica {
            var source: HtmlPageSchemeHandler.Source = { path in try await replica.fetch(path, revision) }
            if overlay.markdownLinks != nil { source = MarkdownPageSource.replicaLinkSource(replica, revision: revision) }
            configuration.setURLSchemeHandler(HtmlPageSchemeHandler(pageID: overlay.id, source: source), forURLScheme: HtmlPageSchemeHandler.scheme)
        } else if case .markdown = overlay.source, let grant = overlay.markdownLinks {
            let handler = HtmlPageSchemeHandler(pageID: overlay.id, source: MarkdownPageSource.linkSource(grant))
            configuration.setURLSchemeHandler(handler, forURLScheme: HtmlPageSchemeHandler.scheme)
        }
        webView = HtmlOverlayWebView(frame: .zero, configuration: configuration)
        webView.pageID = overlay.id
        // WKWebView has no public switch for a transparent canvas; this key lets an unstyled page show the
        // themed panel behind it while authored backgrounds still paint. A URL page keeps the browser's
        // opaque canvas, since a web app styled against it would lose its background here.
        if Self.styled(overlay.source, linked: replica != nil) || overlay.source.kind == .image {
            webView.setValue(false, forKey: "drawsBackground")
        }
        super.init()
        installScripts()
        if bridged {
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
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.urlChanged() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.reportPage() } },
        ]
        textPage = TextPageBridge.make(for: overlay, webView: webView, store: store, world: Self.markdownWorld) { [weak self] in self?.fail($0) }
        loadOriginal()
    }

    /// applyTheme gives later loads a changed theme. A file page wears it and reloads what it shows; a URL page
    /// gets the variables alone, at its next load. Nothing runs in the live document: script the app evaluates
    /// there carries a user gesture that the page's own code can borrow.
    func applyTheme(_ theme: HtmlOverlayTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        installScripts()
        if let textPage { return textPage.loadDocument(fresh: false) }
        if styled { reloadShown() }
    }

    // one set, because removing user scripts removes them all: the theme, the markdown or text renderer, and on a file
    // page the bridge adapter
    private func installScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: theme.script(themed: styled), injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.themeWorld))
        guard styled else { return }
        webView.underPageBackgroundColor = NSColor(agtermHex: theme.background)
        if overlay.source.kind == .markdown {
            controller.addUserScript(WKUserScript(source: MarkdownAssets.shared.script, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Self.markdownWorld))
        }
        if overlay.source.kind == .text {
            controller.addUserScript(WKUserScript(source: MarkdownAssets.shared.textScript, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: Self.markdownWorld))
        }
        guard bridged else { return }
        controller.addUserScript(WKUserScript(source: HtmlOverlayBridge.adapterScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: HtmlOverlayBridge.world))
        if overlay.javascript {
            controller.addUserScript(WKUserScript(source: HtmlOverlayBridge.helperScript, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .page))
        }
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
        // a page shown for another Mac acts there, so its request goes as sent and that Mac fills the defaults
        if let replica, !(replica.ownPageCommandsLocal && Self.addressesOwnPage(body)) {
            let bridge = replica.bridge
            Task {
                do {
                    let (value, error) = HtmlOverlayBridge.reply(raw: try await bridge(data))
                    reply(value, error)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
            return
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

    /// addressesOwnPage is a reload or navigation that names no target, batch or window, which the page means for
    /// itself; an explicit null counts as absent, as the bridge reads it.
    static func addressesOwnPage(_ body: Any) -> Bool {
        guard let request = body as? [String: Any], let command = request["cmd"] as? String,
              ["session.overlay.reload", "session.overlay.navigate"].contains(command) else { return false }
        let args = request["args"] as? [String: Any]
        let named = [request["target"], args?["targets"], args?["window"]].contains { $0 != nil && !($0 is NSNull) }
        return !named
    }

    private var styled: Bool { Self.styled(overlay.source, linked: replica != nil) }
    private var bridged: Bool { Self.bridged(overlay.source, linked: replica != nil) }

    private static func styled(_ source: HtmlSource, linked: Bool) -> Bool {
        [.markdown, .text, .document].contains(source.kind) || bridged(source, linked: linked)
    }

    // only a page its author wrote drives the control API; a markdown, text or clicked HTML file comes from untrusted output
    private static func bridged(_ source: HtmlSource, linked: Bool) -> Bool {
        switch source {
        case .file: return true
        case .replica(_, .html): return linked
        case .replica: return false
        case .url, .image, .markdown, .text, .document, .unreadable: return false
        }
    }

    /// apply takes the model's latest value and reloads when its revision moved. It also finishes a close
    /// the page asked for while its session was hidden.
    func apply(_ overlay: HtmlOverlay) {
        self.overlay = overlay
        textPage?.apply(overlay)
        closeIfRequested()
        guard overlay.reloadRevision != appliedRevision else { return }
        appliedRevision = overlay.reloadRevision
        revision.value = overlay.reloadRevision
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
            if case .replica = overlay.source { return OverlayHtmlError.remoteFile }
            if case .markdown = overlay.source { return OverlayHtmlError.markdownInOverlay }
            if case .text = overlay.source { return OverlayHtmlError.textInOverlay }
            if case .document = overlay.source { return OverlayHtmlError.documentInOverlay }
            guard let url = browserURL else { return OverlayHtmlError.unreadablePage }
            guard browser.open(url) else { return OverlayHtmlError.noBrowser }
        case .finder:
            if case .replica = overlay.source { return OverlayHtmlError.remoteFile }
            guard case .file = overlay.source, let url = pageURL else { return OverlayHtmlError.finderRequiresFile }
            sharing.reveal(url)
        }
        return nil
    }

    func copyLink() {
        guard let url = browserURL else { return }
        sharing.copy(url.absoluteString)
    }

    /// focusSearch moves the keyboard into a text page's search field, a replica's included.
    func focusSearch() {
        webView.window?.makeFirstResponder(webView)
        webView.callAsyncJavaScript("agtermTextFocusSearch()", arguments: [:], in: nil, in: Self.markdownWorld)
    }

    /// setOnScreen takes whether the page is shown; a page out of sight asks nothing, and its pending prompt
    /// goes with it.
    func setOnScreen(_ onScreen: Bool) {
        self.onScreen = onScreen
        textPage?.onScreen = onScreen
        if !onScreen { endPrompt() }
    }

    func close() {
        textLoad += 1
        textPage?.stop()
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

    // a file page without a grant and an image, text or document page, or a markdown page without a link grant, are
    // loaded from text: they sit at about:blank and cannot navigate, so the file they came from is both the current
    // page and what the user is looking at
    private var textLoaded: Bool {
        switch overlay.source {
        case .file(_, nil), .image, .text, .document: return true
        case .markdown: return overlay.markdownLinks == nil
        case .replica(_, let content): return content != .html && overlay.markdownLinks == nil
        default: return false
        }
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
        case .replica(let path, let content) where content == .html || overlay.markdownLinks != nil:
            guard replica != nil, let url = HtmlPageSchemeHandler.url(pageID: id, path: overlay.markdownLinks?.path ?? path) else {
                return fail(OverlayHtmlError.remoteFile)
            }
            webView.load(URLRequest(url: url))
        case .replica(let path, let content):
            guard replica != nil else { return fail(OverlayHtmlError.remoteFile) }
            textLoad += 1
            let load = textLoad
            Task { @MainActor [weak self] in
                guard let page = await self?.replicaContentPage(path: path, content: content), let self, textLoad == load else { return }
                switch page {
                case .failure(let failure): fail(failure.message)
                case .success(let html): await show(html, load: load)
                }
            }
        case .image(let path):
            loadBuilt { ImageProbe.load(path: path).map { probe, data in ImagePage.html(data: data, mimeType: probe.mimeType) } }
        case .markdown(let path):
            if let grant = overlay.markdownLinks, let url = HtmlPageSchemeHandler.url(pageID: id, path: grant.path) {
                webView.load(URLRequest(url: url))
                return
            }
            let style = MarkdownAssets.shared.style
            loadBuilt { MarkdownProbe.load(path: path).map { MarkdownPage.html(markdown: $0.markdown, images: $0.images, style: style) } }
        case .text:
            textPage?.loadDocument(fresh: true)
        case .document(let path): loadBuilt { DocumentProbe.load(path: path) }
        case .unreadable(let reason): fail(reason)
        }
    }

    private func loadBuilt<Failure: Error & CustomStringConvertible>(_ build: @escaping @Sendable () -> Result<String, Failure>) {
        textLoad += 1
        let load = textLoad
        Task { @MainActor [weak self] in
            let page = await Task.detached(priority: .userInitiated) { build() }.value
            guard let self, textLoad == load else { return }
            switch page {
            case .failure(let failure): fail(failure.description)
            case .success(let html): await show(html, load: load)
            }
        }
    }

    private func show(_ html: String, load: Int) async {
        let filtered = overlay.source.kind != .document ? true : await DocumentRules.shared.install(on: webView.configuration.userContentController)
        guard textLoad == load else { return }
        if filtered { webView.loadHTMLString(html, baseURL: nil) } else { fail(DocumentRules.unavailable) }
    }

    private typealias ReplicaContentFailure = HtmlReplicaLink.ReadFailure

    // the origin already judged these files, but the bytes are judged again here as a local file's would be, since
    // a file can change between the origin's check and this fetch
    private func replicaContentPage(path: String, content: ReplicaContent) async -> Result<String, ReplicaContentFailure> {
        switch content {
        case .html:
            return .failure(ReplicaContentFailure(message: OverlayHtmlError.remoteFile))
        case .image:
            let fetched = await fetchReplica(path, limit: ImagePage.maxBytes,
                                             local: (ImageProbe.Failure.tooLarge(path).description, ImageProbe.Failure.unreadable(path).description))
            guard case .success(let data) = fetched else { return fetched.map { _ in "" } }
            return await Task.detached(priority: .userInitiated) {
                ImageProbe.probe(data, path: path).map { ImagePage.html(data: data, mimeType: $0.mimeType) }
                    .mapError { ReplicaContentFailure(message: $0.description) }
            }.value
        case .markdown:
            let fetched = await fetchReplica(path, limit: MarkdownPage.maxBytes,
                                             local: (MarkdownProbe.Failure.tooLarge(path).description, MarkdownProbe.Failure.unreadable(path).description))
            guard case .success(let data) = fetched else { return fetched.map { _ in "" } }
            let fetch: @Sendable (String, Int) async -> Data? = { [weak self] path, limit in
                try? await self?.fetchReplica(path, limit: limit, local: ("", "")).get()
            }
            return await MarkdownPageSource.replica(markdown: data, path: path, fetch: fetch)
                .mapError { ReplicaContentFailure(message: $0.description) }
        case .text(let line):
            let fetched = await fetchReplica(path, limit: TextPage.maxBytes,
                                             local: (TextProbe.Failure.tooLarge(path).description, TextProbe.Failure.unreadable(path).description))
            guard case .success(let data) = fetched else { return fetched.map { _ in "" } }
            let style = MarkdownAssets.shared.textStyle
            return await Task.detached(priority: .userInitiated) {
                TextProbe.text(data, path: path)
                    .map { TextPage.html(text: $0, language: TextPage.language(forFile: path), line: line, style: style) }
                    .mapError { ReplicaContentFailure(message: $0.description) }
            }.value
        case .document:
            let fetched = await fetchReplica(path, limit: DocumentPage.maxBytes, local: (DocumentProbe.Failure.tooLarge(path).description, DocumentProbe.Failure.unreadable(path).description))
            guard case .success(let data) = fetched else { return fetched.map { _ in "" } }
            return await Task.detached(priority: .userInitiated) { DocumentProbe.html(data, path: path).mapError { ReplicaContentFailure(message: $0.description) } }.value
        }
    }

    private func fetchReplica(_ path: String, limit: Int,
                              local: (tooLarge: String, unreadable: String)) async -> Result<Data, ReplicaContentFailure> {
        guard let replica else { return .failure(ReplicaContentFailure(message: local.unreadable)) }
        return await replica.read(path, revision: revision, limit: limit, local: local)
    }

    // a file page opens its own file, never one it navigated to; a URL page opens what it shows, which its
    // policy keeps to HTTP(S); an unreadable page has neither
    private var browserURL: URL? {
        switch overlay.source {
        case .unreadable: return nil
        case .file(let path, _), .replica(let path, _), .image(let path), .markdown(let path), .text(let path, _), .document(let path):
            return URL(fileURLWithPath: path)
        case .url(let original):
            let shown = overlay.browse ? shownURL : webView.url
            guard let url = shown, url.scheme == "http" || url.scheme == "https" else { return original }
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

    // `webView.url` names a pending load before its document replaces the one shown, so a browsing page
    // takes its address at commit. A change on the shown origin is taken at once: it cannot change the
    // site named, and a fragment or pushState change has no commit to wait for
    private func urlChanged() {
        // a link page's pending load names a file not read yet, which may never load
        if let url = webView.url, let shownURL, HtmlSource.origin(of: url) == HtmlSource.origin(of: shownURL),
           overlay.markdownLinks == nil || url.path == shownURL.path {
            self.shownURL = url
        }
        reportPage()
    }

    private var pageURL: URL? {
        if overlay.browse, case .url(let source) = overlay.source { return shownURL ?? source }
        if textLoaded, case .file(let path, _) = overlay.source { return URL(fileURLWithPath: path) }
        if overlay.markdownLinks != nil, let shownURL { return URL(fileURLWithPath: shownURL.path) }
        // a replica's scheme address names this Mac's page id; what it shows is that path on the other Mac
        if let url = webView.url, url.scheme == HtmlSource.replicaScheme { return URL(fileURLWithPath: url.path) }
        if let url = webView.url, url.scheme != "about" { return url }
        switch overlay.source {
        case .file(let path, _), .replica(let path, _), .image(let path), .markdown(let path), .text(let path, _), .document(let path):
            return URL(fileURLWithPath: path)
        case .url(let url): return url
        case .unreadable: return nil
        }
    }

    private func reportPage() {
        guard webView.url != nil, let url = pageURL else { return }
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
        shownURL = webView.url
        reportPage()
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
        shownURL = nil
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
        // a link page also keeps its document when a followed link cannot be read
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 || overlay.markdownLinks != nil {
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
    /// close button does: a page row through its session close, any other page by closing only its overlay.
    func webViewDidClose(_: WKWebView) {
        closeRequested = true
        closeIfRequested()
    }

    /// retryClose asks again for a close this page kept while its window's picker blocked it.
    func retryClose(in store: AppStore) {
        guard self.store === store else { return }
        closeIfRequested()
    }

    // deferred because the close releases this page, clearing the delegate WebKit is calling through
    private func closeIfRequested() {
        guard closeRequested else { return }
        Task { [weak self] in
            guard let self, closeRequested, let store, let slot = store.htmlOverlaySlot(id) else { return }
            if slot.pane == nil, slot.session.content == .page, let close = HtmlOverlayRegistry.shared.closePageSession {
                // cleared across the hand-off: its confirmation runs a nested event loop, where `apply` or a retry
                // would otherwise ask a second time
                closeRequested = false
                closeRequested = !close(store, slot.session.id)
                return
            }
            store.closeHtmlOverlay(id)
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
