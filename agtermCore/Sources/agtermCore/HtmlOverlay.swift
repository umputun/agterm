import Foundation

/// HtmlSource is what a page overlay shows.
public enum HtmlSource: Equatable, Sendable {
    /// file is an absolute, standardized path, and its base URL when a `grantRoot` is set. grantRoot is the
    /// directory WebKit may read from; nil grants no file access, so the app loads the file's text instead,
    /// because WebKit reads a single-file grant as the file's whole folder.
    case file(path: String, grantRoot: String?)
    /// url is a web page, pinned to its origin by the navigation policy.
    case url(URL)

    /// webURL parses `--url`: an absolute http or https URL with a host, nil for anything else.
    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), HtmlOrigin(url) != nil else { return nil }
        return url
    }
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
}

/// HtmlOverlay is a page occupying an overlay slot (`session.overlay.open --html` or `--url`) in place of a
/// program. `id` travels with the value, so a pane swap or promotion moves the page and the app's web view
/// follows it; every adapter callback addresses the page by that id.
public struct HtmlOverlay: Equatable, Sendable {
    public let id: UUID
    public let source: HtmlSource
    /// navigation shows the toolbar (back, forward, reload, title, browser); without it the panel carries
    /// only a close button and the page gets the full height.
    public let navigation: Bool
    public var loadState: HtmlLoadState = .loading
    public var loadError: String?
    /// current is what the web view shows now, as the adapter last reported it; nil until the first load
    /// finishes and after a reload of the original file.
    public var current: HtmlPageInfo?
    /// reloadRevision is bumped by `AppStore.reloadHtmlOverlay`; when it changes the adapter reloads what
    /// `reloadTarget` names.
    public var reloadRevision = 0
    public var reloadTarget = HtmlReloadTarget.original

    public init(source: HtmlSource, navigation: Bool = false, id: UUID = UUID()) {
        self.id = id
        self.source = source
        self.navigation = navigation
    }

    /// grantError says why `file` cannot be opened under `grantRoot`, nil when it can. Both must be absolute, and the file
    /// must sit strictly inside the grant by whole path components, so `/a/bc` is not inside `/a/b`. A grant naming the
    /// file itself is refused: WebKit widens a single-file grant to the file's whole folder.
    public static func grantError(file: String, grantRoot: String?) -> String? {
        guard file.hasPrefix("/") else { return "html file must be an absolute path" }
        guard let grantRoot else { return nil }
        guard grantRoot.hasPrefix("/") else { return "cwd must be an absolute path" }
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
    case back, forward, browser
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

    /// script installs or replaces the stylesheet in element `agterm-theme`; it runs at document start,
    /// before the page's own styles, and again on a theme change.
    public func script(themed: Bool) -> String {
        """
        (() => {
          let style = document.getElementById('agterm-theme');
          if (!style) {
            style = document.createElement('style');
            style.id = 'agterm-theme';
            document.documentElement.prepend(style);
          }
          style.textContent = '\(stylesheet(themed: themed))';
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

/// HtmlNavigationPolicy decides frame navigations for a page overlay. A file page stays inside its explicit
/// grant; a URL page stays on its original URL's origin in the main frame. A clicked http(s) link leaving
/// either boundary opens in the default browser, its redirects included, since WebKit reports a redirect with
/// the click's navigation type; a redirect elsewhere during a load nobody clicked is refused.
public enum HtmlNavigationPolicy {
    public static func decide(_ action: HtmlNavigationAction, overlay: HtmlOverlay) -> HtmlNavigationDecision {
        let scheme = action.url.scheme?.lowercased()
        let web = scheme == "http" || scheme == "https"
        if action.target == .newWindow { return web && action.userActivated ? .openExternal : .cancel }
        if scheme == "about" { return .allow }
        switch overlay.source {
        case .file(_, let grantRoot):
            if web { return action.userActivated ? .openExternal : .cancel }
            guard scheme == "file", let grantRoot else { return .cancel }
            return HtmlOverlay.contains(grantRoot, action.url.path) ? .allow : .cancel
        case .url(let original):
            guard web else { return .cancel }
            if action.target == .subframe || HtmlOrigin(action.url) == HtmlOrigin(original) { return .allow }
            return action.userActivated ? .openExternal : .cancel
        }
    }
}

/// HtmlOverlayReleases carries the one signal the app's web-view registry needs from the model: a page left
/// its slot for good. Fired exactly once per page by every path that empties a slot holding one, so the
/// registry never keeps a page running after its session, pane or overlay is gone.
@MainActor
public final class HtmlOverlayReleases {
    public static let shared = HtmlOverlayReleases()
    public var onRelease: ((UUID) -> Void)?

    func release(_ overlay: HtmlOverlay?) {
        guard let overlay else { return }
        onRelease?(overlay.id)
    }
}
