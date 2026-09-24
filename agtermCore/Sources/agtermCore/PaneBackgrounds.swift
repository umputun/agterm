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

public extension Session {
    /// effectiveBackground is what a pane renders: its own override, else the session default.
    func effectiveBackground(for pane: StatusPane) -> BackgroundWatermark? {
        paneBackgrounds[pane] ?? backgroundWatermark
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
