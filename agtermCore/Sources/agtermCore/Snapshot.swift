import Foundation

/// The persisted form of the whole app state: a plain value tree that mirrors the
/// `@MainActor` model but carries no live `Session`/`Workspace` references.
///
/// `Codable` for JSON, `Equatable` so tests can assert round-trips, `Sendable` so
/// it can cross the actor boundary — the snapshot is built on `@MainActor` and
/// handed to the file writer as a value.
public struct Snapshot: Codable, Equatable, Sendable {
    /// Bumped when the on-disk shape changes; a mismatch makes the loader start fresh.
    public static let currentVersion = 1

    public var version: Int
    public var selectedSessionID: UUID?
    public var workspaces: [WorkspaceSnapshot]
    /// The window's sidebar width in points, or nil for the default. Optional so a snapshot already on
    /// disk before this field was added still decodes, like the SessionSnapshot fields below.
    public var sidebarWidth: Double?
    /// Whether the window's sidebar is shown, or nil for the default (shown). Optional for forward-compat.
    public var sidebarVisible: Bool?

    public init(version: Int = Snapshot.currentVersion, selectedSessionID: UUID? = nil,
                workspaces: [WorkspaceSnapshot] = [], sidebarWidth: Double? = nil, sidebarVisible: Bool? = nil) {
        self.version = version
        self.selectedSessionID = selectedSessionID
        self.workspaces = workspaces
        self.sidebarWidth = sidebarWidth
        self.sidebarVisible = sidebarVisible
    }
}

/// One persisted workspace: its identity, name, and ordered sessions.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sessions: [SessionSnapshot]

    public init(id: UUID, name: String, sessions: [SessionSnapshot]) {
        self.id = id
        self.name = name
        self.sessions = sessions
    }
}

/// One persisted session: its identity, optional custom name, and the working
/// directory to re-spawn a fresh shell in. `cwd` is the live `currentCwd`, or the
/// `initialCwd` when no PWD report has arrived yet.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var customName: String?
    public var cwd: String
    /// Whether the session was shown as a vertical split. Optional so a snapshot already
    /// on disk before this field was added still decodes (as nil → not split) instead of
    /// failing the load and wiping the saved tree. On restore the split pane re-spawns a
    /// fresh shell, like the primary.
    public var isSplit: Bool?
    /// The terminal font size in points, or nil to use the ghostty config default. Optional
    /// so a snapshot already on disk before this field was added still decodes (as nil →
    /// default) instead of failing the load and wiping the saved tree.
    public var fontSize: Double?
    /// The split (right) pane's working directory, so each pane restores to its OWN cwd rather than
    /// both re-spawning in the primary's. The live `splitCwd`, or its restore seed when the split
    /// hasn't reported a PWD yet; nil when there is no split. Optional for forward-compat like the
    /// fields above.
    public var splitCwd: String?
    /// The split divider's left-pane fraction (0...1), so the side-by-side ratio restores. Optional for
    /// forward-compat; nil restores the even default.
    public var splitRatio: Double?

    public init(id: UUID, customName: String?, cwd: String, isSplit: Bool? = nil, fontSize: Double? = nil,
                splitCwd: String? = nil, splitRatio: Double? = nil) {
        self.id = id
        self.customName = customName
        self.cwd = cwd
        self.isSplit = isSplit
        self.fontSize = fontSize
        self.splitCwd = splitCwd
        self.splitRatio = splitRatio
    }
}
