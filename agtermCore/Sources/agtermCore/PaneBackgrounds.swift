import Foundation

/// PaneBackgrounds holds per-pane overrides of a session's `backgroundWatermark`; a nil pane inherits it.
public struct PaneBackgrounds: Codable, Sendable, Equatable {
    public var left: BackgroundWatermark?
    public var right: BackgroundWatermark?
    public var scratch: BackgroundWatermark?

    public init(left: BackgroundWatermark? = nil, right: BackgroundWatermark? = nil,
                scratch: BackgroundWatermark? = nil) {
        self.left = left
        self.right = right
        self.scratch = scratch
    }

    public var isEmpty: Bool { left == nil && right == nil && scratch == nil }

    public subscript(pane: StatusPane) -> BackgroundWatermark? {
        get {
            switch pane {
            case .left: left
            case .right: right
            case .scratch: scratch
            }
        }
        set {
            switch pane {
            case .left: left = newValue
            case .right: right = newValue
            case .scratch: scratch = newValue
            }
        }
    }

    /// persisted is the snapshot form: left/right only, nil when neither is set.
    var persisted: PaneBackgrounds? {
        let kept = PaneBackgrounds(left: left, right: right)
        return kept.isEmpty ? nil : kept
    }

    enum CodingKeys: String, CodingKey {
        case left, right, scratch
    }

    // lossy per pane, like `SessionSnapshot`: an undecodable override drops to inherit without costing the
    // other panes or the session.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = (try? c.decodeIfPresent(BackgroundWatermark.self, forKey: .left)) ?? nil
        right = (try? c.decodeIfPresent(BackgroundWatermark.self, forKey: .right)) ?? nil
        scratch = (try? c.decodeIfPresent(BackgroundWatermark.self, forKey: .scratch)) ?? nil
    }
}

/// BackdropWashRegion is one layer of a floating overlay's backdrop wash: `frame` nil covers the whole
/// detail frame, and `colorHex` nil means the theme background.
public struct BackdropWashRegion: Equatable, Sendable {
    public let frame: HudPaneFrame?
    public let colorHex: String?

    public init(frame: HudPaneFrame?, colorHex: String?) {
        self.frame = frame
        self.colorHex = colorHex
    }
}

public extension Session {
    /// effectiveBackground is what a pane renders: its own override, else the session default.
    func effectiveBackground(for pane: StatusPane) -> BackgroundWatermark? {
        paneBackgrounds[pane] ?? backgroundWatermark
    }

    /// washColorHex is the solid color a pane renders, which its text-fading wash must blend toward; nil
    /// for the theme background, including under an image or text watermark.
    func washColorHex(for pane: StatusPane) -> String? {
        guard let watermark = effectiveBackground(for: pane), watermark.kind == .color else { return nil }
        return watermark.colorHex
    }

    /// backdropWashRegions lists a floating overlay's backdrop wash layers back to front. The caller paints
    /// them opaque and applies the mute once to the flattened group; a pane layer stacked on a translucent
    /// default wash would dim that pane twice. The scratch covers both panes, so it alone decides the color
    /// while shown, and a pane overlay washes against its own background, not the pane's.
    func backdropWashRegions(paneFrames: HudPaneFrames) -> [BackdropWashRegion] {
        if scratchActive { return [BackdropWashRegion(frame: nil, colorHex: washColorHex(for: .scratch))] }
        let sessionHex = backgroundWatermark?.kind == .color ? backgroundWatermark?.colorHex : nil
        var regions = [BackdropWashRegion(frame: nil, colorHex: sessionHex)]
        for pane in OverlayPane.allCases {
            guard let frame = paneFrames[pane] else { continue }
            // the overlay's hex through the renderer's own predicate, so the wash matches what it painted
            let overlayHex = paneOverlay(pane).map { $0.backgroundColor.flatMap { WatermarkConfig.isValidColorHex($0) ? $0 : nil } }
            let hex = overlayHex ?? washColorHex(for: pane == .left ? .left : .right)
            regions.append(BackdropWashRegion(frame: frame, colorHex: hex))
        }
        return regions
    }

    /// backgroundFileKey names a pane override's rendered text file: the pane identity, which follows the
    /// terminal across swap and promotion, or `scratch`. Nil for a right pane that does not exist.
    func backgroundFileKey(for pane: StatusPane) -> String? {
        switch pane {
        case .left: paneIdentity.uuidString
        case .right: splitPaneIdentity?.uuidString
        case .scratch: "scratch"
        }
    }
}
