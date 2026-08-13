/// The physical arrangement of a session's two panes. Raw values use the user-facing divider direction:
/// a vertical divider produces left/right panes, while a horizontal divider produces top/bottom panes.
public enum SplitAxis: String, Codable, CaseIterable, Equatable, Sendable {
    case leftRight = "vertical"
    case topBottom = "horizontal"
}
