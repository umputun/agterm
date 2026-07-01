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
    /// Which view the sidebar renders (tree or flagged flat list), or nil for the default (`.tree`).
    /// Optional so a snapshot already on disk before this field was added still decodes instead of
    /// failing the load and wiping the saved tree, like the fields above.
    public var sidebarMode: SidebarMode?
    /// The workspace the sidebar tree is focused on, or nil for the full tree. Naturally Optional, so a
    /// snapshot already on disk before this field was added decodes (as nil → unfocused) instead of
    /// failing the load and wiping the saved tree.
    public var focusedWorkspaceID: UUID?

    public init(version: Int = Snapshot.currentVersion, selectedSessionID: UUID? = nil,
                workspaces: [WorkspaceSnapshot] = [], sidebarWidth: Double? = nil, sidebarVisible: Bool? = nil,
                sidebarMode: SidebarMode? = nil, focusedWorkspaceID: UUID? = nil) {
        self.version = version
        self.selectedSessionID = selectedSessionID
        self.workspaces = workspaces
        self.sidebarWidth = sidebarWidth
        self.sidebarVisible = sidebarVisible
        self.sidebarMode = sidebarMode
        self.focusedWorkspaceID = focusedWorkspaceID
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
    /// The split divider's left-pane fraction, so the side-by-side ratio restores. Within
    /// `AppStore.splitRatioMin...splitRatioMax` (~0.05...0.95): the live capture skips degenerate extremes
    /// and restore clamps to the same bounds. Optional for forward-compat; nil restores the even default.
    public var splitRatio: Double?
    /// Whether the session is in the flagged working-set. Optional so a snapshot already on disk before
    /// this field was added still decodes (as nil → not flagged) instead of failing the load and wiping
    /// the saved tree, like the fields above.
    public var flagged: Bool?
    /// The main pane's foreground command (full argv) at the last clean quit, re-run on restore when
    /// `AppSettings.restoreRunningCommand` is on. nil when the pane was at its shell prompt (nothing to
    /// restore) or the feature was off. Optional for forward-compat like the fields above.
    public var foregroundCommand: [String]?
    /// The split (right) pane's foreground command (full argv), the split analogue of `foregroundCommand`.
    public var splitForegroundCommand: [String]?
    /// The command the session was created with (`session.new --command`), which exec-replaces the login
    /// shell and so is invisible to libghostty's foreground pid — persisted here so a command session
    /// (e.g. an `ssh …` shortcut) re-runs its command on restore instead of coming back a plain shell. A
    /// live `foregroundCommand` takes precedence at restore. Optional for forward-compat like the fields above.
    public var initialCommand: String?
    /// The session's background watermark (image or rasterized text), or nil for none. Optional so a
    /// snapshot already on disk before this field was added still decodes (as nil → no watermark) instead
    /// of failing the load and wiping the saved tree, like the fields above. A `.text` watermark
    /// re-renders its PNG on restore.
    public var backgroundWatermark: BackgroundWatermark?

    public init(id: UUID, customName: String?, cwd: String, isSplit: Bool? = nil, fontSize: Double? = nil,
                splitCwd: String? = nil, splitRatio: Double? = nil, flagged: Bool? = nil,
                foregroundCommand: [String]? = nil, splitForegroundCommand: [String]? = nil,
                initialCommand: String? = nil, backgroundWatermark: BackgroundWatermark? = nil) {
        self.id = id
        self.customName = customName
        self.cwd = cwd
        self.isSplit = isSplit
        self.fontSize = fontSize
        self.splitCwd = splitCwd
        self.splitRatio = splitRatio
        self.flagged = flagged
        self.foregroundCommand = foregroundCommand
        self.splitForegroundCommand = splitForegroundCommand
        self.initialCommand = initialCommand
        self.backgroundWatermark = backgroundWatermark
    }

    enum CodingKeys: String, CodingKey {
        case id, customName, cwd, isSplit, fontSize, splitCwd, splitRatio, flagged
        case foregroundCommand, splitForegroundCommand, initialCommand, backgroundWatermark
    }

    /// Custom decode so `backgroundWatermark` is LOSSY: a present-but-invalid spec (an unknown
    /// `kind`/`fit`/`position` — e.g. a DOWNGRADE after a newer release added a value the older build
    /// can't decode, or a hand-edit typo) drops to nil instead of throwing `DataCorrupted`. Without this,
    /// `Optional` tolerates only a MISSING key, so one bad watermark would fail the entire `SessionSnapshot`
    /// and `PersistenceStore.load` would start fresh — wiping every workspace and session. Every other
    /// field keeps `decodeIfPresent` (missing-key tolerant, the forward-compat the field docs describe).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        cwd = try c.decode(String.self, forKey: .cwd)
        isSplit = try c.decodeIfPresent(Bool.self, forKey: .isSplit)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize)
        splitCwd = try c.decodeIfPresent(String.self, forKey: .splitCwd)
        splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio)
        flagged = try c.decodeIfPresent(Bool.self, forKey: .flagged)
        foregroundCommand = try c.decodeIfPresent([String].self, forKey: .foregroundCommand)
        splitForegroundCommand = try c.decodeIfPresent([String].self, forKey: .splitForegroundCommand)
        initialCommand = try c.decodeIfPresent(String.self, forKey: .initialCommand)
        backgroundWatermark = (try? c.decodeIfPresent(BackgroundWatermark.self, forKey: .backgroundWatermark)) ?? nil
    }
}
