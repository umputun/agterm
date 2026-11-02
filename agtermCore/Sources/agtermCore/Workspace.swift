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
    /// The last directory any local pane of this workspace reported over OSC 7, normalized; kept when the
    /// workspace empties. The `currentSession` new-session mode opens new sessions here.
    public var rememberedFolder: String?

    public init(name: String, sessions: [Session] = [], isExpanded: Bool = true, tint: SidebarTint? = nil,
                rememberedFolder: String? = nil) {
        id = UUID()
        self.name = name
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.tint = tint
        self.rememberedFolder = rememberedFolder
    }

    public init(id: UUID, name: String, sessions: [Session] = [], isExpanded: Bool = true, tint: SidebarTint? = nil,
                rememberedFolder: String? = nil) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.tint = tint
        self.rememberedFolder = rememberedFolder
    }

    /// `path` with `~` expanded and `.`/`..`/trailing slashes standardized, the one form a remembered folder
    /// is stored and compared in; nil when blank. No symlink resolution: OSC 7 reports the shell's logical
    /// path, and resolving would store a path the user never typed.
    public static func normalizedFolder(_ path: String) -> String? {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized.path
    }

    /// Total unseen-notification count across this workspace's sessions, for the badge on a
    /// collapsed workspace row (when its session rows are hidden).
    public var unseenCount: Int { sessions.reduce(0) { $0 + $1.unseenCount } }
}
