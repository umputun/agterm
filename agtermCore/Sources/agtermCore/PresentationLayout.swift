import Foundation

/// The origin's complete pane membership and arrangement, independent of surface realization.
public struct PresentationLayout: Codable, Equatable, Sendable {
    public var panes: [UUID]
    public var primary: UUID
    public var axis: String?
    public var shown: Bool

    public init(panes: [UUID], primary: UUID, axis: String? = nil, shown: Bool) {
        self.panes = panes
        self.primary = primary
        self.axis = axis
        self.shown = shown
    }

    public var isValid: Bool {
        (1...2).contains(panes.count) && Set(panes).count == panes.count && panes.contains(primary)
            && (panes.count == 1 ? !shown : axis.flatMap(SplitAxis.init(rawValue:)) != nil)
    }

    static let invalid = PresentationLayout(panes: [], primary: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), shown: false)

    private enum CodingKeys: String, CodingKey { case panes, primary, axis, shown }

    public init(from decoder: Decoder) throws {
        // a bad layout must not discard the rest of a snapshot or disconnect its stream
        do {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            panes = try fields.decode([UUID].self, forKey: .panes)
            primary = try fields.decode(UUID.self, forKey: .primary)
            axis = try fields.decodeIfPresent(String.self, forKey: .axis)
            shown = try fields.decode(Bool.self, forKey: .shown)
        } catch {
            self = .invalid
        }
    }
}
