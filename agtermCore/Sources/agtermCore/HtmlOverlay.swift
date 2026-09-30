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

    /// display spells the origin as a user compares it: the port only when it is not the scheme's default.
    var display: String {
        let name = host.contains(":") ? "[\(host)]" : host
        return port == (scheme == "https" ? 443 : 80) ? "\(scheme)://\(name)" : "\(scheme)://\(name):\(port)"
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
    public let id: UUID
    public let source: HtmlSource
    /// navigation adds history, reload, browser and source-sharing buttons to the identity strip.
    public let navigation: Bool
    /// javascript lets the page run its own scripts; agterm's theme script runs either way.
    public let javascript: Bool
    /// chromeless drops the identity strip, file pages only: the strip is what names a URL page's origin.
    public let chromeless: Bool
    public var loadState: HtmlLoadState = .loading
    public var loadError: String?
    /// current is what the web view shows now, as the adapter last reported it; nil until the first load
    /// finishes and after a reload of the original file.
    public var current: HtmlPageInfo?
    /// reloadRevision is bumped by `AppStore.reloadHtmlOverlay`; when it changes the adapter reloads what
    /// `reloadTarget` names.
    public var reloadRevision = 0
    public var reloadTarget = HtmlReloadTarget.original

    public init(source: HtmlSource, navigation: Bool = false, javascript: Bool = false, chromeless: Bool = false,
                id: UUID = UUID()) {
        self.id = id
        self.source = source
        self.navigation = navigation
        self.javascript = javascript
        self.chromeless = chromeless
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
    /// identity names what the panel shows from what the app loaded, never from the page's title, which the
    /// page writes and could dress as a prompt: the file shown, or the origin a URL page is confined to.
    public var identity: String {
        switch source {
        case .file(let path, _): URL(fileURLWithPath: current?.page ?? path).lastPathComponent
        case .url(let url): HtmlOrigin(url)?.display ?? url.absoluteString
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

/// HtmlNavigationPolicy bounds file navigation by its grant and URL main-frame navigation by its origin.
/// openExternal requires app confirmation because WebKit reports synthetic clicks as link activations.
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
        HtmlPageOutcomes.shared.dismiss(overlay.id)
        onRelease?(overlay.id)
    }
}
