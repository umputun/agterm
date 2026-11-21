import Foundation

/// A user-named group of sessions (e.g. "work", "personal"). A value type with
/// a stable UUID identity; its `sessions` array holds `Session` references.
@MainActor
public struct Workspace: Identifiable {
    public let id: UUID
    public var name: String
    public var sessions: [Session]
    /// Whether the sidebar row is expanded (its session rows shown). Defaults true so a freshly created
    /// workspace opens; persisted per workspace so the collapse state survives a relaunch.
    public var isExpanded: Bool
    /// The workspace row's own tint (`workspace.tint`); it never colors the sessions inside.
    public var tint: SidebarTint?
    /// Whether this is the window's implicit root container, whose sessions are shown at the top level of
    /// the sidebar outside any named workspace (`AppStore.rootWorkspace`).
    public let isRoot: Bool

    public init(name: String, sessions: [Session] = [], isExpanded: Bool = true, tint: SidebarTint? = nil,
                isRoot: Bool = false) {
        id = UUID()
        self.name = name
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.tint = tint
        self.isRoot = isRoot
    }

    public init(id: UUID, name: String, sessions: [Session] = [], isExpanded: Bool = true, tint: SidebarTint? = nil,
                isRoot: Bool = false) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.tint = tint
        self.isRoot = isRoot
    }

    /// Total unseen-notification count across this workspace's sessions, for the badge on a
    /// collapsed workspace row (when its session rows are hidden).
    public var unseenCount: Int { sessions.reduce(0) { $0 + $1.unseenCount } }
}
