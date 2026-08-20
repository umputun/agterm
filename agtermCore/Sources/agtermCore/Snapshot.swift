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

    /// Custom decode so EVERY optional is LOSSY: a present-but-invalid value (a malformed UUID, an unknown
    /// enum raw value from a newer build, a wrong JSON type from a hand edit) drops to nil. `Optional`
    /// alone tolerates only a MISSING key, so one bad value would fail the whole `Snapshot` and
    /// `PersistenceStore.load` would start fresh, wiping every workspace and session over a non-essential
    /// field. `WorkspaceSnapshot` and `SessionSnapshot` below guard their own optionals the same way, so
    /// the whole tree survives a bad optional at any depth.
    ///
    /// What still throws is identity and payload: `version`, `workspaces`, and each nested `id`/`name`/
    /// `cwd`/`sessions`. That gap is real and unclosed, not a safe floor: a hand-edited `"cwd": 5` on one
    /// session still wipes the entire tree, the same #360 path these guards exist to close. It stands
    /// because the alternatives each cost something this one does not, never because throwing is cheaper.
    /// It is the most destructive outcome available. Recovering the field keeps a session pointing
    /// somewhere the user never left it; dropping the element loses that session silently. Pick one
    /// deliberately before treating this line as settled.
    ///
    /// A parse-level failure is outside all of it: unterminated JSON never reaches these guards, and
    /// `save` writes atomically so the app itself cannot leave that behind.
    ///
    /// Also migrates the legacy `focusedWorkspaceID`: its presence implied the filter was on, so it becomes
    /// a one-member ENABLED set. Neither key present decodes to nil/nil — an empty, disabled filter.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        selectedSessionID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedSessionID)) ?? nil
        workspaces = try c.decode([WorkspaceSnapshot].self, forKey: .workspaces)
        sidebarWidth = (try? c.decodeIfPresent(Double.self, forKey: .sidebarWidth)) ?? nil
        sidebarVisible = (try? c.decodeIfPresent(Bool.self, forKey: .sidebarVisible)) ?? nil
        sidebarMode = (try? c.decodeIfPresent(SidebarMode.self, forKey: .sidebarMode)) ?? nil
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyFocus = (try? legacyContainer.decodeIfPresent(UUID.self, forKey: .focusedWorkspaceID)) ?? nil
        // `Result` separates a FAILED decode from an absent key. `try?` cannot: SE-0230 flattens it, so
        // both arrive as nil. The migration below must fire only on absence, because on a malformed set it
        // would take the legacy id and force `focusEnabled` true over an explicit `false` in the same file.
        let decodedIDs = Result { try c.decodeIfPresent([UUID].self, forKey: .focusedWorkspaceIDs) }
        let ids = (try? decodedIDs.get()) ?? nil
        if case .success(.none) = decodedIDs, let legacyID = legacyFocus {
            focusedWorkspaceIDs = [legacyID]
            focusEnabled = true
        } else {
            focusedWorkspaceIDs = ids
            focusEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .focusEnabled)) ?? nil
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

    enum CodingKeys: String, CodingKey {
        case id, name, sessions, collapsed
    }

    /// Custom decode so `collapsed` is LOSSY, matching the other two snapshot types: the synthesized
    /// decode would throw on a hand-edited `"collapsed": "yes"`, failing the whole workspace and making
    /// `PersistenceStore.load` wipe the tree over one row's expansion arrow.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sessions = try c.decode([SessionSnapshot].self, forKey: .sessions)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? nil
    }
}

/// One persisted session: its identity, optional custom name, and the working directory to re-spawn a
/// fresh shell in. `cwd` is the live `currentCwd`, or the `initialCwd` before any PWD report.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var customName: String?
    public var cwd: String
    /// Whether the session was shown as a split; nil = not split. On restore the split pane
    /// re-spawns a fresh shell, like the primary.
    public var isSplit: Bool?
    /// The shown split's divider direction; nil/missing restores the legacy left/right arrangement.
    public var splitAxis: SplitAxis?
    /// The terminal font size in points; nil = the ghostty config default.
    public var fontSize: Double?
    /// The split (right) pane's working directory, so each pane restores to its OWN cwd. The live
    /// `splitCwd`, or its restore seed before the split reports a PWD; nil when there is no split.
    public var splitCwd: String?
    /// The split divider's primary-pane fraction. Within `AppStore.splitRatioMin...splitRatioMax`
    /// (~0.05...0.95) — capture skips degenerate extremes, restore clamps; nil restores the even default.
    public var splitRatio: Double?
    /// Whether the session is in the flagged working-set; nil = not flagged.
    public var flagged: Bool?
    /// The main pane's foreground command (full argv) as of the last clean quit or the last
    /// `restore.capture`, re-run on restore when `AppSettings.restoreRunningCommand` is on. nil at a shell
    /// prompt, or with the feature off, which gates every capture site.
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

    public init(id: UUID, customName: String?, cwd: String, isSplit: Bool? = nil,
                splitAxis: SplitAxis? = nil, fontSize: Double? = nil,
                splitCwd: String? = nil, splitRatio: Double? = nil, flagged: Bool? = nil,
                foregroundCommand: [String]? = nil, splitForegroundCommand: [String]? = nil,
                initialCommand: String? = nil, commandWait: Bool? = nil,
                backgroundWatermark: BackgroundWatermark? = nil,
                restoreCommand: String? = nil, splitRestoreCommand: String? = nil) {
        self.id = id
        self.customName = customName
        self.cwd = cwd
        self.isSplit = isSplit
        self.splitAxis = splitAxis
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
        case id, customName, cwd, isSplit, splitAxis, fontSize, splitCwd, splitRatio, flagged
        case foregroundCommand, splitForegroundCommand, initialCommand, commandWait, backgroundWatermark
        case restoreCommand, splitRestoreCommand
    }

    /// Custom decode so every optional is LOSSY, matching `Snapshot.init(from:)`: an unknown
    /// `kind`/`fit`/`position` after a DOWNGRADE, or any hand-edit typo, drops that field to nil rather
    /// than throwing. A throw here fails the whole `SessionSnapshot`, which fails the `workspaces` array
    /// above it, and `PersistenceStore.load` starts fresh, wiping everything over one session's font size.
    /// `id` and `cwd` stay strict, and that is the unclosed half: a session that cannot say which it is
    /// or where to spawn is not restorable, but throwing here costs the WHOLE tree, not this one session.
    /// See `Snapshot.init(from:)` above for the trade-off and why it has not been picked yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        customName = (try? c.decodeIfPresent(String.self, forKey: .customName)) ?? nil
        cwd = try c.decode(String.self, forKey: .cwd)
        isSplit = (try? c.decodeIfPresent(Bool.self, forKey: .isSplit)) ?? nil
        splitAxis = (try? c.decodeIfPresent(SplitAxis.self, forKey: .splitAxis)) ?? nil
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? nil
        splitCwd = (try? c.decodeIfPresent(String.self, forKey: .splitCwd)) ?? nil
        splitRatio = (try? c.decodeIfPresent(Double.self, forKey: .splitRatio)) ?? nil
        flagged = (try? c.decodeIfPresent(Bool.self, forKey: .flagged)) ?? nil
        foregroundCommand = (try? c.decodeIfPresent([String].self, forKey: .foregroundCommand)) ?? nil
        splitForegroundCommand = (try? c.decodeIfPresent([String].self, forKey: .splitForegroundCommand)) ?? nil
        initialCommand = (try? c.decodeIfPresent(String.self, forKey: .initialCommand)) ?? nil
        commandWait = (try? c.decodeIfPresent(Bool.self, forKey: .commandWait)) ?? nil
        backgroundWatermark = (try? c.decodeIfPresent(BackgroundWatermark.self, forKey: .backgroundWatermark)) ?? nil
        restoreCommand = (try? c.decodeIfPresent(String.self, forKey: .restoreCommand)) ?? nil
        splitRestoreCommand = (try? c.decodeIfPresent(String.self, forKey: .splitRestoreCommand)) ?? nil
    }
}
