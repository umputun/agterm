import Foundation

/// HtmlSource is what a page overlay shows.
public enum HtmlSource: Equatable, Sendable {
    /// file is an absolute, standardized path, and its base URL when a `grantRoot` is set. grantRoot is the
    /// directory WebKit may read from; nil grants no file access, so the app loads the file's text instead,
    /// because WebKit reads a single-file grant as the file's whole folder.
    case file(path: String, grantRoot: String?)
    /// url is a web page, pinned to its origin by the navigation policy.
    case url(URL)
    /// replica is a page another Mac opened, shown here from bytes fetched over its page channel: `path` is its
    /// path on that Mac, whose own rules decide what else may be fetched, and `content` what kind of page it is.
    /// It is never a path on this Mac, so nothing reads it from the local disk.
    case replica(path: String, content: ReplicaContent)
    /// image is a picture shown on a page of its own, embedded in the page's HTML so the page gets no file
    /// grant, theme or bridge.
    case image(path: String)
    /// markdown is a markdown file the app renders with its pictures embedded: no file grant or bridge,
    /// but themed.
    case markdown(path: String)
    /// text is a source, config or log file shown read-only, scrolled to `line` when one is set: no file
    /// grant, bridge, link or navigation, but themed.
    case text(path: String, line: Int?)
    /// document is an HTML file a terminal click named, so untrusted: the app reads its text and loads it with no
    /// file grant or bridge, themed like a file page.
    case document(path: String)
    /// unreadable is a saved page row whose descriptor this build cannot use: it loads nothing and shows `reason`
    /// as its failed state, so the row stays a page instead of restoring as a terminal.
    case unreadable(reason: String)

    /// kind is what the page shows, a replica counted as the kind its origin opened.
    public var kind: HtmlPageKind {
        switch self {
        case .file: return .file
        case .url: return .url
        case .image: return .image
        case .markdown: return .markdown
        case .text: return .text
        case .document: return .document
        case .unreadable: return .unreadable
        case .replica(_, let content):
            switch content {
            case .html: return .file
            case .image: return .image
            case .markdown: return .markdown
            case .text: return .text
            case .document: return .document
            }
        }
    }

    /// imagePath is the picture an `.image` page shows, nil for every other source.
    public var imagePath: String? {
        if case .image(let path) = self { return path }
        return nil
    }

    /// markdownPath is the file a `.markdown` page renders, nil for every other source.
    public var markdownPath: String? {
        if case .markdown(let path) = self { return path }
        return nil
    }

    /// textPath is the file a `.text` page shows, nil for every other source.
    public var textPath: String? {
        if case .text(let path, _) = self { return path }
        return nil
    }

    /// webURL parses `--url`: an absolute http or https URL with a host, nil for anything else.
    public static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), HtmlOrigin(url) != nil else { return nil }
        return url
    }

    /// replicaScheme is the URL scheme a replica page loads from.
    public static let replicaScheme = "agterm-page"

    /// isLoopback says whether `--url` names this Mac by one of three exact hosts: 127.0.0.1, ::1 or localhost.
    /// Ranges and aliases never match, so WebKit cannot read an accepted host as a different one.
    public static func isLoopback(_ text: String) -> Bool {
        guard let url = webURL(text), let host = HtmlOrigin(url)?.host else { return false }
        return ["127.0.0.1", "::1", "localhost"].contains(host)
    }
}

/// ReplicaContent is the kind of page a replica's origin opened: an HTML file it loads as is, or a picture,
/// markdown, text or clicked HTML file this Mac builds a page from. An image carries its oriented pixel size for sizing.
public enum ReplicaContent: Equatable, Sendable {
    case html
    case image(width: Int, height: Int)
    case markdown
    case text(line: Int?)
    case document
}

/// HtmlPageKind is what a page shows, independent of which Mac read its file.
public enum HtmlPageKind: Equatable, Sendable {
    case file, url, image, markdown, text, document, unreadable
}

/// HtmlOrigin is a web page's origin: lowercase scheme and host plus the effective port, so an omitted
/// port equals the scheme's default.
struct HtmlOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    /// display spells the origin as a user compares it: the port only when it is not the scheme's default.
    var display: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == (scheme == "https" ? 443 : 80) ? "\(scheme)://\(name)" : "\(scheme)://\(name):\(port)"
    }
}

/// TextLog is a text page's request to show only a log's last `tail` lines, following its end when `follow` is set.
public struct TextLog: Equatable, Sendable {
    public let tail: Int
    public let follow: Bool

    public init(tail: Int, follow: Bool) {
        self.tail = tail
        self.follow = follow
    }
}

/// TextLogReport is what the app last read for a log page: the lines shown, a clipped first line, a file that is
/// missing (`waiting`) or turned binary (`unreadable`, the last good text still shown).
public struct TextLogReport: Equatable, Sendable {
    public var lines = 0
    public var clipped = false
    public var waiting = false
    public var unreadable = false

    public init(lines: Int = 0, clipped: Bool = false, waiting: Bool = false, unreadable: Bool = false) {
        self.lines = lines
        self.clipped = clipped
        self.waiting = waiting
        self.unreadable = unreadable
    }
}

/// TextLogState is a log page's live state: whether it follows the file, and the app's last report.
public struct TextLogState: Equatable, Sendable {
    public var following: Bool
    public var report: TextLogReport

    public init(following: Bool, report: TextLogReport = TextLogReport()) {
        self.following = following
        self.report = report
    }
}

/// TextChanges is a diff page's count of changes, a change being one run of removed and added lines, and the one it
/// last stepped to, from 1 and 0 before any step.
public struct TextChanges: Equatable, Sendable {
    public let count: Int
    public let current: Int

    public init(count: Int, current: Int) {
        self.count = count
        self.current = current
    }
}

/// TextSearch is a text page's search: the query and the page's last report on it, `current` counted from 1 and 0
/// with no match.
public struct TextSearch: Equatable, Sendable {
    public let query: String
    public var matches: Int
    public var current: Int

    public init(query: String, matches: Int = 0, current: Int = 0) {
        self.query = query
        self.matches = matches
        self.current = current
    }
}

/// HtmlZoom is the page-zoom ladder the font-size commands walk on an HTML page, one factor for every page.
public enum HtmlZoom {
    static let steps: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let smallest = 0.5, largest = 3.0

    /// resolve bounds a stored factor to the ladder's range; nil and a non-finite value mean actual size.
    static func resolve(_ stored: Double?) -> Double {
        guard let stored, stored.isFinite else { return 1 }
        return min(largest, max(smallest, stored))
    }

    /// applying maps a font binding action (`increase_font_size:1`, `decrease_font_size:1`, `reset_font_size`)
    /// to the next factor from `zoom`, nil for any other action. An off-ladder factor steps to its neighbor.
    public static func applying(fontAction action: String, to zoom: Double) -> Double? {
        switch action.split(separator: ":").first {
        case "increase_font_size": return steps.first { $0 > zoom } ?? largest
        case "decrease_font_size": return steps.last { $0 < zoom } ?? smallest
        case "reset_font_size": return 1
        default: return nil
        }
    }
}

/// HtmlOverlay is a page occupying an overlay slot (`session.overlay.open --html` or `--url`) in place of a
/// program. `id` travels with the value, so a pane swap or promotion moves the page and the app's web view
/// follows it; every adapter callback addresses the page by that id.
public struct HtmlOverlay: Equatable, Sendable {
    /// stripHeight is the identity strip's height in points; chromeHeight adds the rule under it.
    public static let stripHeight = 28.0
    public static let chromeHeight = stripHeight + 1

    public let id: UUID
    public let source: HtmlSource
    /// navigation adds history, reload, browser and source-sharing buttons to the identity strip.
    public internal(set) var navigation: Bool
    /// javascript lets the page run its own scripts; agterm's theme script runs either way.
    public let javascript: Bool
    /// chromeless drops the identity strip: a file page, or a URL page on a loopback host whose frames stay on
    /// its origin, since nothing else names whose content it shows.
    public let chromeless: Bool
    /// persistent puts a URL page on the saved browser store; every other page gets an in-memory one of its own.
    public let persistent: Bool
    /// browse lets a URL page's main frame leave its original origin for any HTTP(S) site.
    public let browse: Bool
    /// clicked marks a page a terminal click opened, which `AppStore.releaseHiddenClickedPage` lets a later click
    /// replace. Local: presentation frames do not carry it.
    public let clicked: Bool
    /// replicaOf is the page id on the Mac that opened the page, set only on a page shown here for it.
    public let replicaOf: UUID?
    /// markdownLinks is what a markdown page may follow links within, set only with navigation.
    public internal(set) var markdownLinks: MarkdownLinkGrant?
    /// textLog makes a text page a log page; logState is that page's live state, set exactly when textLog is.
    public let textLog: TextLog?
    public var logState: TextLogState?
    /// textSearch is a text page's search, nil with none; searchRevision changes with every query set or closed, and a
    /// page report naming another revision is dropped.
    public internal(set) var textSearch: TextSearch?
    public internal(set) var searchRevision = 0
    /// textChanges is a diff page's last report on its changes, nil until it reports and on any other page.
    public internal(set) var textChanges: TextChanges?
    public var loadState: HtmlLoadState = .loading
    public var loadError: String?
    /// current is what the web view shows now, as the adapter last reported it; nil until the first load
    /// finishes and after a reload of the original file.
    public var current: HtmlPageInfo?
    /// reloadRevision is bumped by `AppStore.reloadHtmlOverlay`; when it changes the adapter reloads what
    /// `reloadTarget` names.
    public var reloadRevision = 0
    public var reloadTarget = HtmlReloadTarget.original

    /// init drops navigation from a markdown page without `markdownLinks`, so its strip never offers Back and
    /// Forward its links cannot use.
    public init(source: HtmlSource, navigation: Bool = false, javascript: Bool = false, chromeless: Bool = false,
                persistent: Bool = false, browse: Bool = false, clicked: Bool = false, id: UUID = UUID(),
                replicaOf: UUID? = nil, textLog: TextLog? = nil, markdownLinks: MarkdownLinkGrant? = nil) {
        self.id = id
        self.textLog = textLog
        logState = textLog.map { TextLogState(following: $0.follow) }
        self.clicked = clicked
        self.replicaOf = replicaOf
        self.source = source
        let links = navigation ? markdownLinks : nil
        self.markdownLinks = links
        self.navigation = navigation && (source.kind != .markdown || links != nil)
        self.javascript = javascript
        self.chromeless = chromeless
        self.persistent = persistent
        self.browse = browse
    }

    /// grantError says why `file` cannot be opened under `grantRoot`, nil when it can. Both must be absolute, and the file
    /// must sit strictly inside the grant by whole path components, so `/a/bc` is not inside `/a/b`. A grant naming the
    /// file itself is refused: WebKit widens a single-file grant to the file's whole folder. `/` and `home` are
    /// refused as overly broad grants.
    public static func grantError(file: String, grantRoot: String?, home: String = NSHomeDirectory()) -> String? {
        guard file.hasPrefix("/") else { return "html file must be an absolute path" }
        guard let grantRoot else { return nil }
        guard grantRoot.hasPrefix("/") else { return "cwd must be an absolute path" }
        guard ![components("/"), components(home)].contains(components(grantRoot)) else {
            return "cwd must not be / or the home directory"
        }
        guard components(grantRoot) != components(file) else { return "cwd must be a directory containing the html file" }
        return contains(grantRoot, file) ? nil : "html file is outside cwd"
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        components(path).starts(with: components(root))
    }

    private static func components(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    }
}

extension HtmlSource {
    /// origin returns an HTTP(S) origin without URL credentials, nil for other schemes.
    public static func origin(of url: URL) -> String? { HtmlOrigin(url)?.display }
}

extension HtmlOverlay {
    /// withoutLinks is this page with no link grant, as a presenter that cannot follow links is handed it: a
    /// markdown page loses its Back and Forward with the grant.
    func withoutLinks() -> HtmlOverlay {
        var page = self
        page.markdownLinks = nil
        page.navigation = navigation && source.kind != .markdown
        return page
    }

    /// identity names what the panel shows from what the app loaded, never from the page's title, which the
    /// page writes and could dress as a prompt: the file shown, the origin a URL page is confined to, or
    /// for a browsing page the origin of the document it shows now. A browsing page on a document with no
    /// web origin, `about:blank`, is named by that address: no site is shown, so none is claimed.
    public var identity: String {
        switch source {
        case .file(let path, _): return URL(fileURLWithPath: current?.page ?? path).lastPathComponent
        case .replica(let path, .html), .replica(let path, .markdown): return URL(fileURLWithPath: current?.page ?? path).lastPathComponent
        case .replica(let path, _): return URL(fileURLWithPath: path).lastPathComponent
        case .markdown(let path): return URL(fileURLWithPath: current?.page ?? path).lastPathComponent
        case .image(let path), .text(let path, _), .document(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .unreadable: return "unreadable page"
        case .url(let url):
            let shown = browse ? current.map { URL(string: $0.page).flatMap(HtmlOrigin.init)?.display ?? $0.page } : nil
            return shown ?? HtmlOrigin(url)?.display ?? url.absoluteString
        }
    }
}

/// HtmlPageInfo is the page the web view shows and where its history can go; `page` differs from the
/// overlay's source after a navigation.
public struct HtmlPageInfo: Equatable, Sendable {
    public let page: String
    public let title: String?
    public let canGoBack: Bool
    public let canGoForward: Bool

    public init(page: String, title: String?, canGoBack: Bool, canGoForward: Bool) {
        self.page = page
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}

/// HtmlReloadTarget is what a reload loads: the original source (`overlay.reload`, the artifact an agent
/// rewrote) or the page the user navigated to (`--current`, the toolbar button).
public enum HtmlReloadTarget: Sendable {
    case original, current
}

/// HtmlNavigation is a history step or hand-off `session.overlay.navigate` and the toolbar perform.
public enum HtmlNavigation: String, CaseIterable, Sendable {
    case back, forward, browser, finder
}

/// HtmlOverlayTheme is the terminal theme as a page sees it. Every page gets it as custom properties
/// (`--agterm-background`, `--agterm-foreground`, `--agterm-color-0` to `15`) that apply nothing until the page
/// uses them; a themed page, one agterm shows from a file, also gets the scheme and text color as its default
/// look. All of it sits at zero specificity. A file page's background is painted behind its transparent web view
/// instead of set in CSS, because a CSS background on `html` would stop an authored `body` background filling
/// the canvas.
public struct HtmlOverlayTheme: Equatable, Sendable {
    public let background: String
    public let foreground: String
    public let dark: Bool
    /// palette holds the 16 ANSI colors by slot, an invalid entry kept empty so the others keep their index;
    /// empty when the theme did not supply exactly 16.
    public let palette: [String]

    /// init takes `#rrggbb` colors; anything else falls back to a plain dark or light pair, since the values
    /// end up inside a stylesheet.
    public init(background: String, foreground: String, dark: Bool, palette: [String] = []) {
        let valid = WatermarkConfig.isValidColorHex(background) && WatermarkConfig.isValidColorHex(foreground)
        self.background = valid ? background : (dark ? "#1e1e1e" : "#ffffff")
        self.foreground = valid ? foreground : (dark ? "#d4d4d4" : "#1e1e1e")
        self.dark = dark
        self.palette = palette.count == 16 ? palette.map { WatermarkConfig.isValidColorHex($0) ? $0 : "" } : []
    }

    func stylesheet(themed: Bool) -> String {
        let look = themed ? "color-scheme: \(dark ? "dark" : "light"); color: \(foreground); " : ""
        let slots = palette.enumerated().compactMap { $1.isEmpty ? nil : "--agterm-color-\($0): \($1); " }.joined()
        return ":where(html) { \(look)--agterm-background: \(background); --agterm-foreground: \(foreground); \(slots)}"
    }

    /// script prepends the stylesheet as element `agterm-theme`; it runs at document start, before the page's
    /// own styles.
    public func script(themed: Bool) -> String {
        """
        (() => {
          const style = document.createElement('style');
          style.id = 'agterm-theme';
          style.textContent = '\(stylesheet(themed: themed))';
          document.documentElement.prepend(style);
        })();
        """
    }
}

/// HtmlLoadState is the page's load progress as the app's web view last reported it.
public enum HtmlLoadState: String, Codable, Sendable {
    case loading, loaded, failed
}

/// HtmlNavigationTarget is where a navigation would land; a nil WebKit target frame is a new window.
public enum HtmlNavigationTarget: Sendable {
    case mainFrame, subframe, newWindow
}

/// HtmlNavigationAction is a frame navigation the web view asks about. Subresource loads never reach it.
public struct HtmlNavigationAction: Sendable {
    public let url: URL
    public let target: HtmlNavigationTarget
    public let userActivated: Bool

    public init(url: URL, target: HtmlNavigationTarget, userActivated: Bool) {
        self.url = url
        self.target = target
        self.userActivated = userActivated
    }
}

public enum HtmlNavigationDecision: Sendable {
    case allow, openExternal, cancel
}

/// HtmlNavigationPolicy bounds file navigation by its grant and URL main-frame navigation by its origin; a
/// browsing page's main frame may go to any HTTP(S) origin.
/// openExternal requires app confirmation because WebKit reports synthetic clicks as link activations.
public enum HtmlNavigationPolicy {
    public static func decide(_ action: HtmlNavigationAction, overlay: HtmlOverlay) -> HtmlNavigationDecision {
        // ahead of the shared exits: a text page shows only the document the app built, so not even a
        // user-activated web link or another about: address leaves it
        if overlay.source.kind == .text {
            return action.target == .mainFrame && action.url.absoluteString == "about:blank" ? .allow : .cancel
        }
        let scheme = action.url.scheme?.lowercased()
        let web = scheme == "http" || scheme == "https"
        if action.target == .newWindow { return web && action.userActivated ? .openExternal : .cancel }
        if scheme == "about" { return .allow }
        switch overlay.source {
        case .file(_, let grantRoot):
            if web { return action.userActivated ? .openExternal : .cancel }
            guard scheme == "file", let grantRoot else { return .cancel }
            return HtmlOverlay.contains(grantRoot, action.url.path) ? .allow : .cancel
        case .replica(_, .html):
            if web { return action.userActivated ? .openExternal : .cancel }
            let own = action.url.host?.lowercased() == overlay.id.uuidString.lowercased()
            return scheme == HtmlSource.replicaScheme && own ? .allow : .cancel
        case .image, .replica(_, .image):
            return .cancel
        case .markdown, .replica(_, .markdown):
            if web { return action.userActivated ? .openExternal : .cancel }
            return followsLink(action, overlay: overlay) ? .allow : .cancel
        case .document, .replica(_, .document):
            return web && action.userActivated ? .openExternal : .cancel
        case .replica(_, .text), .text, .unreadable:
            return .cancel
        case .url(let original):
            guard web else { return .cancel }
            if HtmlOrigin(action.url) == HtmlOrigin(original) || overlay.browse { return .allow }
            if action.target == .subframe, !overlay.chromeless { return .allow }
            return action.userActivated ? .openExternal : .cancel
        }
    }

    // the page's own scheme address of a markdown file inside its grant; the source serving it judges the
    // canonical file again, so this check is lexical only
    private static func followsLink(_ action: HtmlNavigationAction, overlay: HtmlOverlay) -> Bool {
        let url = action.url
        guard let grant = overlay.markdownLinks, action.target == .mainFrame, url.scheme?.lowercased() == HtmlSource.replicaScheme,
              url.host?.lowercased() == overlay.id.uuidString.lowercased(),
              LinkPolicy.markdownExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return MarkdownPage.lexicalPath(url.path, folder: grant.root) != nil
    }
}

/// HtmlOverlayReleases carries the one signal the app's web-view registry needs from the model: a page left
/// its slot for good. Fired exactly once per page by every path that empties a slot holding one, so the
/// registry never keeps a page running after its session, pane or overlay is gone.
@MainActor
public final class HtmlOverlayReleases {
    public static let shared = HtmlOverlayReleases()
    public var onRelease: ((UUID) -> Void)?
    /// onReplicaRelease is told a page shown for another Mac left its slot, with its local and origin ids, so
    /// that Mac can free the page whatever closed it here.
    public var onReplicaRelease: ((_ local: UUID, _ origin: UUID) -> Void)?
    /// onServedRelease is told any page left its slot, so the channels serving it to other Macs can end.
    public var onServedRelease: ((UUID) -> Void)?

    func release(_ overlay: HtmlOverlay?) {
        guard let overlay else { return }
        HtmlPageOutcomes.shared.dismiss(overlay.id)
        onRelease?(overlay.id)
        onServedRelease?(overlay.id)
        if let origin = overlay.replicaOf { onReplicaRelease?(overlay.id, origin) }
    }
}
