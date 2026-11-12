/// Error strings for `session.overlay.result`, shared so the `agtermctl --block` poll matches the
/// server's wording exactly (the poll retries while the overlay is still running, by `error` string).
public enum OverlayResultError {
    public static let stillRunning = "overlay still running"
    public static let noResult = "no overlay result"
    /// An overlay a viewer showed that ended without an exit code: `launch-failed`, `canceled`, `unknown`.
    public static func ended(_ outcome: String) -> String { "overlay ended: \(outcome)" }
    /// The overlay runs on another Mac's surface, so this Mac has nothing to read or copy.
    public static let shownElsewhere = "overlay is shown on another Mac"
    /// The stream the overlay was handed to is gone, so nothing can reach the surface to resize it.
    public static let viewerGone = "the viewer showing this overlay is gone"
    /// presenterSilent answers a text page action the presenting Mac sent no result for within the deadline.
    public static let presenterSilent = "presenter did not answer"
    /// The command and its environment exceed what the helper reads in one frame.
    public static let tooLarge = "overlay command too large to show on another Mac"
}

/// Error strings for `session.overlay.*` aimed at a session whose overlay slot holds a HUD. The slot is
/// shared, so these rejections need the live session and fire in `ControlServer`, not the dispatcher.
/// `session.overlay.close` is deliberately absent: closing a HUD is a courtesy the shared teardown gives.
public enum OverlayHudError {
    /// A HUD runs the app's painter, not the caller's program, so there is no status to report — and
    /// `overlayActive` alone would otherwise answer the misleading "overlay still running".
    public static let noResult = "no overlay result: the slot holds a hud"
    /// A HUD is always floating (`AppStore.openHud`): it must never cover the session it is a message about.
    /// A percent is accepted but bounded by `HudLayout.clampSizePercent(_:for:)`.
    public static let fullResize = "a hud is always floating: pass --size-percent, not --full"
    /// `session.hud.update`/`.close` against a slot that holds no HUD — empty, or running a caller's program.
    public static let noHud = "no hud"
    /// `session.overlay.copy`/`.text` against a HUD. The panel paints agterm's own message, so reading it
    /// would hand a caller back the text it wrote rather than a program's output, and the slot being
    /// occupied is not enough to tell the two apart.
    public static let noRead = "no overlay to read: the slot holds a hud"
    /// The body file the helper reads could not be written, so the panel would paint nothing or stale text.
    public static let writeFailed = "could not write the hud message"
}

/// BrowserClearError holds the reasons the saved browser store cannot be cleared or opened right now.
public enum BrowserClearError {
    public static let clearing = "browser storage is being cleared"

    public static func pagesOpen(_ count: Int) -> String {
        "\(count) persistent \(count == 1 ? "page" : "pages") still open"
    }
}

/// OverlayHtmlError holds the error strings for `session.overlay.*` against an HTML page.
public enum OverlayHtmlError {
    public static let commandAndHtml = "session.overlay.open takes a command or --html, not both"
    public static let commandAndURL = "session.overlay.open takes a command or --url, not both"
    public static let htmlAndURL = "session.overlay.open takes --html or --url, not both"
    public static let waitWithHtml = "session.overlay.open: --wait cannot be combined with --html"
    public static let waitWithURL = "session.overlay.open: --wait cannot be combined with --url"
    /// cwdWithURL: a web page reads no local files, so there is no grant to give it.
    public static let cwdWithURL = "session.overlay.open: --cwd cannot be combined with --url"
    public static let invalidURL = "session.overlay.open: --url must be an absolute http or https URL"
    public static let navigationWithoutPage = "session.overlay.open: --navigation requires --html, --url or --markdown"
    public static let javascriptWithoutPage = "session.overlay.open: --js requires --html or --url"
    public static let chromelessRequiresFile = "session.overlay.open: --chromeless requires --html or a loopback --url"
    /// chromelessRequiresLoopback: the strip is what names a URL page's origin, so only this Mac's may drop it.
    public static let chromelessRequiresLoopback =
        "session.overlay.open: --chromeless with --url requires a loopback host: 127.0.0.1, ::1 or localhost"
    public static let chromelessWithNavigation = "session.overlay.open: --chromeless cannot be combined with --navigation"
    public static let chromelessWithBrowse = "session.overlay.open: --chromeless cannot be combined with --browse"
    public static let persistentRequiresURL = "session.overlay.open: --persistent requires --url"
    public static let persistentUnavailable = "persistent browser storage is not available"
    public static let browseRequiresURL = "session.overlay.open: --browse requires --url"
    public static let oneSource = "session.overlay.open takes one of a command, --html, --url, --image, --markdown or --text"
    /// imageOptions: a picture page runs no script, navigates nowhere and reads only its own file.
    public static let imageOptions =
        "session.overlay.open: --image takes no --wait, --cwd, --navigation, --js, --chromeless, --persistent or --browse"
    public static let imageNotAbsolute = "session.overlay.open: --image must be an absolute path"
    public static let imageType = "session.overlay.open: --image must be a png, jpg, jpeg, gif or webp file"
    public static let markdownOptions =
        "session.overlay.open: --markdown takes no --wait, --cwd, --js, --chromeless, --persistent or --browse"
    public static let markdownNotAbsolute = "session.overlay.open: --markdown must be an absolute path"
    public static let markdownType = "session.overlay.open: --markdown must be a .md or .markdown file"
    public static let textOptions =
        "session.overlay.open: --text takes no --wait, --cwd, --navigation, --js, --chromeless, --persistent or --browse"
    public static let textNotAbsolute = "session.overlay.open: --text must be an absolute path"
    public static let textType = "session.overlay.open: --text must be a source, config, text or log file"
    public static let lineWithoutText = "session.overlay.open: --line requires --text"
    public static let lineNotPositive = "session.overlay.open: --line must be 1 or more"
    public static let tailWithoutText = "session.overlay.open: --tail and --follow-file require --text"
    public static let tailWithLine = "session.overlay.open: --tail and --follow-file cannot be combined with --line"
    public static let logRemote = "session.overlay.open: the Mac presenting this session cannot show a log page"
    public static let tailRange = "session.overlay.open: --tail must be 1...\(TextPage.maxTail)"
    public static let searchRequest = "session.overlay.search needs text, --next, --prev or --close"
    public static let searchTextWithStep = "session.overlay.search: text cannot be combined with --next, --prev or --close"
    public static let companionNeedsPage = "a page companion needs --html or --url"
    public static let pageSessionNeedsPage = "a page session needs --html or --url"
    public static let serverLoopbackRow = "a page on agterm-server's loopback cannot be a page session: no Mac would reach it"
    /// presenter: a page is shown on this Mac, so it is refused while another Mac presents the session.
    public static let presenter = "a viewer presents this session: an html overlay would open where nobody sees it"
    public static let noOverlay = "no overlay"
    public static let notHtml = "the overlay is not an html page"
    public static let navigation = "session.overlay.navigate requires back, forward, browser or finder"
    public static let finderRequiresFile = "show in Finder requires a file page"
    /// markdownInOverlay: a markdown page is rendered by the app, so a browser would get the raw file instead.
    public static let markdownInOverlay = "a markdown page opens only in its overlay"
    /// textInOverlay: a text page is built by the app, so a browser would get the raw file instead.
    public static let textInOverlay = "a text page opens only in its overlay"
    /// documentInOverlay: a clicked HTML file came from terminal output, and a browser would run its scripts.
    public static let documentInOverlay = "a clicked html page opens only in its overlay"
    /// unreadablePage: a saved page this build could not read has no file or address to hand anywhere.
    public static let unreadablePage = "the saved page could not be read"
    /// remoteFile: a file page shown for another Mac has no file here to reveal or open.
    public static let remoteFile = "the page's file is on another Mac"
    /// remotePage: Finder and Browser are refused for a file page shown on the presenting Mac.
    public static let remotePage = "page is shown on another Mac"
    /// replicaSubmit: a page shown here for another Mac is answered there, through the page itself.
    public static let replicaSubmit = "submit on the Mac that opened the page"
    /// remoteLoopback: a loopback URL names this Mac, so the presenting Mac cannot load it.
    public static let remoteLoopback = "a loopback url names this Mac, so the Mac presenting the session cannot load it"
    public static let remoteTooLarge = "page too large to show on another Mac"
    /// noHistory: the page has nowhere to go in that direction.
    public static func noHistory(_ navigation: HtmlNavigation) -> String { "no page to go \(navigation.rawValue) to" }
    /// notRealized: the page has not been shown yet, so there is no web view to drive.
    public static let notRealized = "html overlay not realized"
    public static let noBrowser = "no default web browser to open the page in"
    /// noResult and noRead: a page runs no program, so there is no exit status and no terminal text.
    public static let noResult = "no overlay result: the slot holds an html page"
    public static let noRead = "no overlay to read: the slot holds an html page"
    public static let submitValue = "session.overlay.submit requires a value"
    public static let invalidPageID = "invalid page id"
    /// unknownPage: no page with that id was opened, or its outcome aged out of the retained results.
    public static let unknownPage = "no such page"
}

/// Error strings for `session.overlay.hide|show|toggle` and for opening into a slot whose overlay is hidden.
public enum OverlayVisibilityError {
    /// hidden: the slot still holds its overlay, running; show or close it before opening another.
    public static let hidden = "overlay hidden"
    public static let noOverlay = "no overlay"
}

/// Error strings for the pane-scoped (`--pane`) arm of `session.overlay.*`. Shared because the rejections
/// are split across layers — `alreadyOpen`/`paneNotVisible` need the live session and fire in
/// `ControlServer`, the rest are host-free in `ControlDispatcher` — and the wording must not drift.
public enum PaneOverlayError {
    public static let alreadyOpen = "pane overlay already open"
    public static let paneNotVisible = "pane not visible"
    /// Names the canonical spellings only; `OverlayPane.init?(controlName:)` also takes role/axis aliases.
    public static let invalidPane = "session.overlay: --pane must be left or right"
    public static let sizePercentConflict = "session.overlay.open: --pane is mutually exclusive with --size-percent"
    public static let resizeUnsupported = "session.overlay.resize: --pane is not supported (pane overlays are always full)"
    public static let pointsConflict = "session.overlay.open: --pane is mutually exclusive with --width/--height"
}

/// OverlayPointError holds the `--width`/`--height` error strings of `session.overlay.open` and `.resize`,
/// split across the dispatcher and the store like `PaneOverlayError`.
public enum OverlayPointError {
    public static let needsPercent = "session.overlay.open: --width/--height need --size-percent"
    public static let notPositive = "session.overlay: --width/--height must be positive"
    public static let fullConflict = "session.overlay.resize: --full is mutually exclusive with --width/--height"
    /// notFloating: points alone change the axes of a panel that is already floating; a full overlay has no
    /// percent for the other axis to keep.
    public static let notFloating = "session.overlay.resize: --width/--height need a floating overlay; pass --size-percent too"
    public static let hud = "a hud measures its own height: --width/--height do not apply"
    public static let remote = "--width/--height are not supported for an overlay this Mac shows for another Mac; resize it on that Mac"
}

/// Advisory text `notify` returns in `result.text` when the banner toggle is off. The command still succeeds
/// (the unseen badge tracks either way) but hands macOS nothing, so a bare `ok` would look identical to a
/// broken notification path (issue #286). Shared so wording and matchers cannot drift.
public enum ControlNotify {
    public static let bannersOffNote = "badge updated, but \"Show notification banners\" is off, so no banner was posted"
}
