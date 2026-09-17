/// Which view the sidebar renders: the normal workspace tree, or the flagged working-set
/// sessions across all workspaces, arranged by the app-wide `FlaggedViewLayout`. Per-window UI state, persisted
/// in `Snapshot` (decode → `.tree` when absent so legacy state is unaffected).
public enum SidebarMode: String, Codable, Sendable {
    case tree
    case flagged
}
