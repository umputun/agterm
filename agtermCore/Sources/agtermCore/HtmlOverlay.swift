import Foundation

/// HtmlOverlay is a local HTML file occupying an overlay slot (`session.overlay.open --html`) in place of a
/// program. `id` travels with the value, so a pane swap or promotion moves the page and the app's web view
/// follows it; every adapter callback addresses the page by that id.
public struct HtmlOverlay: Equatable, Sendable {
    public let id: UUID
    /// file is the absolute, standardized path of the page, and its base URL when a `grantRoot` is set.
    public let file: String
    /// grantRoot is the directory WebKit may read from. nil grants no file access at all: the app loads the
    /// file's text rather than its URL, because WebKit reads a single-file grant as the file's whole folder.
    public let grantRoot: String?
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

    public init(file: String, grantRoot: String? = nil, navigation: Bool = false, id: UUID = UUID()) {
        self.id = id
        self.file = file
        self.grantRoot = grantRoot
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
/// overlay's `file` after an in-grant navigation.
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

/// HtmlReloadTarget is what a reload loads: the file the overlay was opened with (`overlay.reload`, the
/// artifact an agent rewrote) or the page the user navigated to (`--current`, the toolbar button).
public enum HtmlReloadTarget: Sendable {
    case original, current
}

/// HtmlNavigation is a history step or hand-off `session.overlay.navigate` and the toolbar perform.
public enum HtmlNavigation: String, CaseIterable, Sendable {
    case back, forward, browser
}

/// HtmlOverlayTheme is the default look a page gets when it styles nothing itself: the terminal theme's
/// background, text color and light/dark scheme. The stylesheet carries only the scheme and text color, at
/// zero specificity; the background is painted behind a transparent web view instead, because a CSS
/// background on `html` would stop an authored `body` background from filling the canvas.
public struct HtmlOverlayTheme: Equatable, Sendable {
    public let background: String
    public let foreground: String
    public let dark: Bool

    /// init takes `#rrggbb` colors; anything else falls back to a plain dark or light pair, since the values
    /// end up inside a stylesheet.
    public init(background: String, foreground: String, dark: Bool) {
        let valid = WatermarkConfig.isValidColorHex(background) && WatermarkConfig.isValidColorHex(foreground)
        self.background = valid ? background : (dark ? "#1e1e1e" : "#ffffff")
        self.foreground = valid ? foreground : (dark ? "#d4d4d4" : "#1e1e1e")
        self.dark = dark
    }

    var stylesheet: String {
        ":where(html) { color-scheme: \(dark ? "dark" : "light"); color: \(foreground); }"
    }

    /// script installs or replaces the stylesheet in element `agterm-theme`; it runs at document start,
    /// before the page's own styles, and again on a theme change.
    public var script: String {
        """
        (() => {
          let style = document.getElementById('agterm-theme');
          if (!style) {
            style = document.createElement('style');
            style.id = 'agterm-theme';
            document.documentElement.prepend(style);
          }
          style.textContent = '\(stylesheet)';
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

/// HtmlNavigationPolicy decides frame navigations for an HTML overlay: files inside the grant (none without
/// one) and `about:` (the text-loaded page, blank and srcdoc frames) load in place, a clicked http(s) link opens
/// in the default browser whatever frame or window it targets, and everything else is blocked.
public enum HtmlNavigationPolicy {
    public static func decide(_ action: HtmlNavigationAction, overlay: HtmlOverlay) -> HtmlNavigationDecision {
        let scheme = action.url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" { return action.userActivated ? .openExternal : .cancel }
        if action.target == .newWindow { return .cancel }
        switch scheme {
        case "file":
            guard let root = overlay.grantRoot else { return .cancel }
            return HtmlOverlay.contains(root, action.url.path) ? .allow : .cancel
        case "about":
            return .allow
        default:
            return .cancel
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
