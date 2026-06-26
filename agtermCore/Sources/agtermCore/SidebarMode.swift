import Foundation

/// Which view the sidebar renders: the normal workspace tree, or a flat list of the
/// flagged working-set sessions across all workspaces. Per-window UI state, persisted
/// in `Snapshot` (decode → `.tree` when absent so legacy state is unaffected).
public enum SidebarMode: String, Codable, Sendable {
    case tree
    case flagged
}
