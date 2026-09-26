import Foundation

/// HtmlOverlay is a local HTML file occupying an overlay slot (`session.overlay.open --html`) in place of a
/// program. `id` travels with the value, so a pane swap or promotion moves the page and the app's web view
/// follows it; every adapter callback addresses the page by that id.
public struct HtmlOverlay: Equatable, Sendable {
    public let id: UUID
    /// file is the absolute, standardized path of the page, which is also its base URL.
    public let file: String
    /// grantRoot is the directory WebKit may read from; nil grants the file alone.
    public let grantRoot: String?
    public var loadState: HtmlLoadState = .loading
    public var loadError: String?
    /// current is what the web view shows now, as the adapter last reported it; nil until the first load
    /// finishes and after a reload of the original file.
    public var current: HtmlPageInfo?
    /// reloadRevision is bumped by `AppStore.reloadHtmlOverlay`; when it changes the adapter reloads what
    /// `reloadTarget` names.
    public var reloadRevision = 0
    public var reloadTarget = HtmlReloadTarget.original

    public init(file: String, grantRoot: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.file = file
        self.grantRoot = grantRoot
    }

    /// readAccessPath is the path passed to WebKit's `allowingReadAccessTo`.
    public var readAccessPath: String { grantRoot ?? file }

    /// grantError says why `file` cannot be opened under `grantRoot`, nil when it can. Both must be absolute, and the file
    /// must sit inside the grant by whole path components, so `/a/bc` is not inside `/a/b`.
    public static func grantError(file: String, grantRoot: String?) -> String? {
        guard file.hasPrefix("/") else { return "html file must be an absolute path" }
        guard let grantRoot else { return nil }
        guard grantRoot.hasPrefix("/") else { return "cwd must be an absolute path" }
        return contains(grantRoot, file) ? nil : "html file is outside cwd"
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        let rootParts = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return parts.starts(with: rootParts)
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

/// HtmlNavigationPolicy decides frame navigations for an HTML overlay: files inside the grant and `about:`
/// (blank and srcdoc frames) load in place, a clicked main-frame http(s) link opens in the default browser,
/// and everything else is blocked, new windows included.
public enum HtmlNavigationPolicy {
    public static func decide(_ action: HtmlNavigationAction, overlay: HtmlOverlay) -> HtmlNavigationDecision {
        if action.target == .newWindow { return .cancel }
        switch action.url.scheme?.lowercased() {
        case "file":
            return HtmlOverlay.contains(overlay.readAccessPath, action.url.path) ? .allow : .cancel
        case "about":
            return .allow
        case "http", "https":
            return action.target == .mainFrame && action.userActivated ? .openExternal : .cancel
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
