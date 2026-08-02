import Foundation

/// The persisted form of the whole app state: a plain value tree mirroring the `@MainActor` model with no
/// live `Session`/`Workspace` references. `Equatable` for round-trip tests, `Sendable` because it is built
/// on `@MainActor` and handed to the file writer as a value.
///
/// Every field after `workspaces` is Optional for forward-compat: a snapshot written before the field
/// existed decodes with the default each doc names, instead of failing the load and wiping the saved tree.
/// Same for the `WorkspaceSnapshot`/`SessionSnapshot` fields below.
public struct Snapshot: Codable, Equatable, Sendable {
    /// Bumped when the on-disk shape changes; a mismatch makes the loader start fresh.
    public static let currentVersion = 1

    public var version: Int
    public var selectedSessionID: UUID?
    public var workspaces: [WorkspaceSnapshot]
    /// The window's sidebar width in points; nil = the default.
    public var sidebarWidth: Double?
    /// Whether the window's sidebar is shown; nil = the default (shown).
    public var sidebarVisible: Bool?
    /// Which view the sidebar renders (tree or flagged flat list); nil = `.tree`.
    public var sidebarMode: SidebarMode?
    /// The workspaces marked in the sidebar focus set, in tree order; nil = nothing marked.
    public var focusedWorkspaceIDs: [UUID]?
    /// Whether the focus filter applies to the marked set; nil = off. Persisted apart so it keeps members.
    public var focusEnabled: Bool?
    /// Most-recently-selected session ids, front = current, so the Ctrl-Tab switcher's order survives a
    /// relaunch. Restore drops ids no longer in the tree; nil = selection only.
    public var sessionRecency: [UUID]?

    public init(version: Int = Snapshot.currentVersion, selectedSessionID: UUID? = nil,
                workspaces: [WorkspaceSnapshot] = [], sidebarWidth: Double? = nil, sidebarVisible: Bool? = nil,
                sidebarMode: SidebarMode? = nil, focusedWorkspaceIDs: [UUID]? = nil, focusEnabled: Bool? = nil,
                sessionRecency: [UUID]? = nil) {
        self.version = version
        self.selectedSessionID = selectedSessionID
        self.workspaces = workspaces
        self.sidebarWidth = sidebarWidth
        self.sidebarVisible = sidebarVisible
        self.sidebarMode = sidebarMode
        self.focusedWorkspaceIDs = focusedWorkspaceIDs
        self.focusEnabled = focusEnabled
        self.sessionRecency = sessionRecency
    }

    enum CodingKeys: String, CodingKey {
        case version, selectedSessionID, workspaces, sidebarWidth, sidebarVisible, sidebarMode
        case focusedWorkspaceIDs, focusEnabled, sessionRecency
    }

    /// The legacy single-workspace focus key from before the focus SET existed. Its own key type with no
    /// stored property, so re-encoding a migrated snapshot drops it instead of writing the legacy key back
    /// on every load-mutate-save path, and no extra `CodingKeys` case blocks the synthesized `encode(to:)`.
    private enum LegacyCodingKeys: String, CodingKey {
        case focusedWorkspaceID
    }

    /// Custom decode so `sessionRecency` is LOSSY: a present-but-invalid list (a malformed UUID, a wrong
    /// JSON type after a hand edit) drops to nil. `Optional` alone tolerates only a MISSING key, so one bad
    /// MRU entry would fail the whole `Snapshot` and `PersistenceStore.load` would start fresh, wiping every
    /// workspace and session over a non-essential field. Mirrors `backgroundWatermark` below; others strict.
    ///
    /// Also migrates the legacy `focusedWorkspaceID`: its presence implied the filter was on, so it becomes
    /// a one-member ENABLED set. Neither key present decodes to nil/nil — an empty, disabled filter.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        selectedSessionID = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        workspaces = try c.decode([WorkspaceSnapshot].self, forKey: .workspaces)
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth)
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible)
        sidebarMode = try c.decodeIfPresent(SidebarMode.self, forKey: .sidebarMode)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyFocus = try legacyContainer.decodeIfPresent(UUID.self, forKey: .focusedWorkspaceID)
        let ids = try c.decodeIfPresent([UUID].self, forKey: .focusedWorkspaceIDs)
        if ids == nil, let legacyID = legacyFocus {
            focusedWorkspaceIDs = [legacyID]
            focusEnabled = true
        } else {
            focusedWorkspaceIDs = ids
            focusEnabled = try c.decodeIfPresent(Bool.self, forKey: .focusEnabled)
        }
        sessionRecency = (try? c.decodeIfPresent([UUID].self, forKey: .sessionRecency)) ?? nil
    }
}

/// One persisted workspace: its identity, name, and ordered sessions.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sessions: [SessionSnapshot]
    /// The INVERSE of `isExpanded`, so missing → expanded (the default) and only a collapsed workspace
    /// writes it — an all-expanded tree serializes byte-identically to a legacy snapshot.
    public var collapsed: Bool?

    public init(id: UUID, name: String, sessions: [SessionSnapshot], collapsed: Bool? = nil) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.collapsed = collapsed
    }
}

/// One persisted session: its identity, optional custom name, and the working directory to re-spawn a
/// fresh shell in. `cwd` is the live `currentCwd`, or the `initialCwd` before any PWD report.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var customName: String?
    public var cwd: String
    /// Whether the session was shown as a vertical split; nil = not split. On restore the split pane
    /// re-spawns a fresh shell, like the primary.
    public var isSplit: Bool?
    /// The terminal font size in points; nil = the ghostty config default.
    public var fontSize: Double?
    /// The split (right) pane's working directory, so each pane restores to its OWN cwd. The live
    /// `splitCwd`, or its restore seed before the split reports a PWD; nil when there is no split.
    public var splitCwd: String?
    /// The split divider's left-pane fraction. Within `AppStore.splitRatioMin...splitRatioMax`
    /// (~0.05...0.95) — capture skips degenerate extremes, restore clamps; nil restores the even default.
    public var splitRatio: Double?
    /// Whether the session is in the flagged working-set; nil = not flagged.
    public var flagged: Bool?
    /// The main pane's foreground command (full argv) at the last clean quit, re-run on restore when
    /// `AppSettings.restoreRunningCommand` is on. nil at a shell prompt, or with the feature off.
    public var foregroundCommand: [String]?
    /// The split (right) pane's foreground command (full argv), the split analogue of `foregroundCommand`.
    public var splitForegroundCommand: [String]?
    /// The command the session was created with (`session.new --command`); the quit-time capture cannot see
    /// it — the pane's foreground process GROUP is led by setuid-root `login`, whose argv is unreadable, and
    /// the capture deliberately does not descend — hence persisted separately so a command session re-runs
    /// it on restore instead of coming back a plain shell. A live `foregroundCommand` wins.
    public var initialCommand: String?
    /// Whether a `--command` session holds its surface after the command exits (`--wait`), so a restored
    /// command session holds again instead of vanishing. nil (missing key) decodes as false.
    public var commandWait: Bool?
    /// The session's background watermark (image or rasterized text); nil = none. `.text` re-renders its PNG.
    public var backgroundWatermark: BackgroundWatermark?
    /// The main pane's restore-command override (`session.restore`), winning over `foregroundCommand` and
    /// `initialCommand` on the next launch. Tri-state: nil = no override, `""` = a plain shell, a command =
    /// that shell line. Sticky — unlike `foregroundCommand` it is not consumed, so it fires every restart.
    public var restoreCommand: String?
    /// The split (right) pane's restore-command override, the split analogue of `restoreCommand`.
    public var splitRestoreCommand: String?

    public init(id: UUID, customName: String?, cwd: String, isSplit: Bool? = nil, fontSize: Double? = nil,
                splitCwd: String? = nil, splitRatio: Double? = nil, flagged: Bool? = nil,
                foregroundCommand: [String]? = nil, splitForegroundCommand: [String]? = nil,
                initialCommand: String? = nil, commandWait: Bool? = nil,
                backgroundWatermark: BackgroundWatermark? = nil,
                restoreCommand: String? = nil, splitRestoreCommand: String? = nil) {
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
        self.commandWait = commandWait
        self.backgroundWatermark = backgroundWatermark
        self.restoreCommand = restoreCommand
        self.splitRestoreCommand = splitRestoreCommand
    }

    enum CodingKeys: String, CodingKey {
        case id, customName, cwd, isSplit, fontSize, splitCwd, splitRatio, flagged
        case foregroundCommand, splitForegroundCommand, initialCommand, commandWait, backgroundWatermark
        case restoreCommand, splitRestoreCommand
    }

    /// Custom decode so `backgroundWatermark` is LOSSY: an unknown `kind`/`fit`/`position` — a DOWNGRADE
    /// after a newer release added a value this build can't decode, or a hand-edit typo — drops to nil
    /// instead of throwing `DataCorrupted`, which would fail the whole `SessionSnapshot` and make
    /// `PersistenceStore.load` start fresh, wiping everything. Others keep missing-key `decodeIfPresent`.
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
        commandWait = try c.decodeIfPresent(Bool.self, forKey: .commandWait)
        backgroundWatermark = (try? c.decodeIfPresent(BackgroundWatermark.self, forKey: .backgroundWatermark)) ?? nil
        restoreCommand = try c.decodeIfPresent(String.self, forKey: .restoreCommand)
        splitRestoreCommand = try c.decodeIfPresent(String.self, forKey: .splitRestoreCommand)
    }
}
