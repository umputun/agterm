import Foundation

/// OverlayPointSize overrides a floating overlay's `--size-percent` per axis, in points of the area its program
/// or page gets; a page's strip comes on top. A nil axis keeps the percent.
public struct OverlayPointSize: Equatable, Sendable {
    public var width: Int?
    public var height: Int?

    public init(width: Int? = nil, height: Int? = nil) {
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width == nil && height == nil }

    /// merging returns these sizes with every axis `other` sets replaced.
    public func merging(_ other: OverlayPointSize) -> OverlayPointSize {
        OverlayPointSize(width: other.width ?? width, height: other.height ?? height)
    }

    /// maxShare is the most of the session a point axis may take, the HUD's cap, so a panel sized in points
    /// always leaves some of the session in view. A percent axis keeps its 1...100.
    public static let maxShare = Double(HudLayout.maxSizePercent) / 100

    /// panelSize is the floating panel's outer size inside `bounds`, `chrome` being the strip a page draws
    /// above its content. A point axis is capped AFTER the chrome is added, so the strip cannot push the
    /// panel past `maxShare`.
    public static func panelSize(in bounds: (width: Double, height: Double), sizePercent: Int,
                                 points: OverlayPointSize, chrome: Double) -> (width: Double, height: Double) {
        let share = Double(sizePercent) / 100
        let width = points.width.map { min(Double($0), bounds.width * maxShare) } ?? bounds.width * share
        let height = points.height.map { min(Double($0) + chrome, bounds.height * maxShare) } ?? bounds.height * share
        return (width: width, height: height)
    }

    /// contentSize is what `panelSize` leaves the program or page once the chrome is taken.
    public static func contentSize(in bounds: (width: Double, height: Double), sizePercent: Int,
                                   points: OverlayPointSize, chrome: Double) -> (width: Double, height: Double) {
        let panel = panelSize(in: bounds, sizePercent: sizePercent, points: points, chrome: chrome)
        return (width: panel.width, height: max(0, panel.height - chrome))
    }
}

extension HtmlOverlay {
    /// chrome is what the panel draws above the page: the strip and its rule, none for a chromeless page.
    public var chrome: Double { chromeless ? 0 : Self.chromeHeight }
}

extension Session {
    /// overlayContentSize is a floating program or page's content size in points in the cached detail bounds:
    /// the read-back of `--width`/`--height` and of `--size-percent` alike. Nil for a full overlay, a HUD, an
    /// empty slot, and before the deck has laid the session out.
    public var overlayContentSize: (width: Double, height: Double)? {
        guard coverOverlayActive, let percent = overlaySizePercent, let detail = hudPaneFrames.detail,
              detail.width > 0, detail.height > 0 else { return nil }
        return OverlayPointSize.contentSize(in: (detail.width, detail.height), sizePercent: percent,
                                            points: overlayPoints, chrome: htmlOverlay?.chrome ?? 0)
    }
}

/// OverlayPointResizeFailure is why `AppStore.resizeOverlayInPoints` refused point sizes.
public enum OverlayPointResizeFailure: Equatable, Sendable {
    case noOverlay
    /// remote: the slot is shown on another Mac, or this one shows another Mac's overlay.
    case remote
    /// hud: a HUD measures its own height.
    case hud
    /// notFloating: points alone need a floating panel whose percent the other axis keeps.
    case notFloating

    public var message: String {
        switch self {
        case .noOverlay: "no overlay"
        case .remote: OverlayPointError.remote
        case .hud: OverlayPointError.hud
        case .notFloating: OverlayPointError.notFloating
        }
    }
}

extension AppStore {
    /// resizeOverlayInPoints replaces the overrides with a percent, or merges only the supplied axes without one.
    public func resizeOverlayInPoints(_ sessionID: UUID, sizePercent: Int?,
                                      points: OverlayPointSize) -> OverlayPointResizeFailure? {
        guard let session = session(withID: sessionID) else { return .noOverlay }
        if session.remoteOverlays.slot(nil) != nil || session.overlayReplica != nil
            || session.htmlOverlay?.replicaOf != nil { return .remote }
        if session.hudActive { return .hud }
        guard session.coverOverlayActive else { return .noOverlay }
        if let sizePercent {
            resizeOverlay(sessionID, sizePercent: sizePercent, points: points)
            return nil
        }
        guard session.overlaySizePercent != nil else { return .notFloating }
        session.overlayPoints = session.overlayPoints.merging(points)
        return nil
    }
}
