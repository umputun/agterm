import Foundation

// Nested `ControlResult` payloads, kept out of `ControlProtocol.swift` so that file stays inside the
// 1000-line limit.

/// The restore-mode policy, read by `restore.mode` and repeated as `zmx list`'s header.
///
/// Modes travel as raw strings even though the producer holds a typed `RestoreMode`. `RestoreMode`'s own
/// decoder is deliberately lossy — an unknown raw value becomes `.none` so a settings file written by a
/// newer build is not discarded — and reusing it here would make a stale CLI print a future mode as
/// `none`, the mode that reaps every daemon. Every other evolvable enum on a control node is projected
/// the same way.
public struct ControlRestoreStatus: Codable, Sendable, Equatable {
    /// What settings.json holds, and so what the NEXT launch will request.
    public let configured: String
    /// What THIS process requested at launch. Differs from `configured` once Settings changes mid-run.
    public let requestedAtLaunch: String
    /// What the launch actually got: `none` when live was requested but ineligible.
    public let active: String
    public let restartRequired: Bool
    /// Why live fell back, present ONLY when live was actually requested and refused. The launch decision
    /// carries a probed reason even under `none`/`rerun`, and reporting that would tell a rerun user their
    /// shell is unsupported for a mode they never asked for.
    public let unavailableReason: String?

    public init(configured: RestoreMode, requestedAtLaunch: RestoreMode, active: RestoreMode,
                unavailableReason: String?) {
        self.configured = configured.rawValue
        self.requestedAtLaunch = requestedAtLaunch.rawValue
        self.active = active.rawValue
        restartRequired = configured != requestedAtLaunch
        self.unavailableReason = requestedAtLaunch == .live && active != .live ? unavailableReason : nil
    }
}

/// The refusal a `ControlActions` conformer gives for a command this platform does not implement, so the
/// default implementations and any host wording it the same way cannot drift.
public enum ControlActionsUnsupported {
    public static func message(_ command: String) -> String {
        "\(command) is not supported on this platform"
    }
}

/// One row of `zmx list`: a daemon, a pane that claims one, or both.
///
/// State and observation travel as raw strings for the same reason the restore modes do — a strict enum
/// on the wire would make a future state fail the WHOLE response rather than one field.
public struct ControlZmxEntry: Codable, Sendable, Equatable {
    public let daemon: String
    public let state: String
    public let observation: String
    /// Present only when the daemon was observed running; absent for an unreadable or missing one.
    public let clients: Int?
    public let leaderPID: Int32?
    public let windowID: String?
    /// Absent for an unindexed window, whose name lives only in the `windows.json` entry it is missing from.
    public let windowName: String?
    public let windowState: String?
    public let workspaceID: String?
    public let workspaceName: String?
    public let sessionID: String?
    public let sessionName: String?
    public let pane: String?

    public init(row: ZmxInventoryRow) {
        daemon = row.daemon
        state = row.state.rawValue
        observation = row.observation.rawValue
        clients = row.clients
        leaderPID = row.leaderPID
        windowID = row.claim?.windowID.uuidString
        windowName = row.claim?.windowName
        windowState = row.claim?.windowState.rawValue
        workspaceID = row.claim?.workspaceID?.uuidString
        workspaceName = row.claim?.workspaceName
        sessionID = row.claim?.sessionID.uuidString
        sessionName = row.claim?.sessionName
        pane = row.claim?.pane.rawValue
    }
}

/// What a caller on another machine needs to reach these daemons over ssh. Neither is guessable from the
/// far side, so a remote attach cannot be built without asking.
public struct ControlZmxEndpoint: Codable, Sendable, Equatable {
    /// Absolute path to the zmx this instance invokes: inside the app bundle, or a debug override.
    public let executable: String
    /// The `ZMX_DIR` its daemons live under, hashed from this instance's state directory.
    public let socketDirectory: String

    public init(executable: String, socketDirectory: String) {
        self.executable = executable
        self.socketDirectory = socketDirectory
    }
}

/// One pane of a remote session and the daemon behind it.
public struct ControlRemotePane: Codable, Sendable, Equatable {
    /// `left` or `right`, matching the local pane vocabulary.
    public let pane: String
    public let daemon: String
    /// Argv of what the far side reports running in this pane, so a caller can say what it is about to
    /// attach to. Omitted when the remote reports none, which a plain idle shell does.
    public let foreground: [String]?

    public init(pane: String, daemon: String, foreground: [String]? = nil) {
        self.pane = pane
        self.daemon = daemon
        self.foreground = foreground
    }
}

/// A session on another machine, with every pane resolved to a live daemon. A session whose panes did not
/// all resolve is absent rather than partial — see `RemoteTreeMerger`.
public struct ControlRemoteSession: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// Where this session lives on the far side: show the names, group by the ids. Neither rename path
    /// nor `addWorkspace` enforces uniqueness, so grouping by name merges two windows called `main`, and
    /// the window id alone still merges two `dev` workspaces inside one of them.
    public let windowID: String
    public let windowName: String
    public let workspaceID: String
    public let workspaceName: String
    /// The far side's own note of what the session is FOR, when its owner set one.
    public let context: String?
    public let cwd: String
    /// Divider direction, present only for a session that has a split.
    public let splitAxis: String?
    public let panes: [ControlRemotePane]

    public init(id: String, name: String, windowID: String, windowName: String, workspaceID: String,
                workspaceName: String, context: String? = nil, cwd: String, splitAxis: String?,
                panes: [ControlRemotePane]) {
        self.id = id
        self.name = name
        self.windowID = windowID
        self.windowName = windowName
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.context = context
        self.cwd = cwd
        self.splitAxis = splitAxis
        self.panes = panes
    }
}

/// `zmx tree [HOST]`'s payload: every open window's attachable sessions, and the one endpoint they all
/// attach through.
public struct ControlRemoteTree: Codable, Sendable, Equatable {
    /// The ssh destination the REQUESTING app was given, stamped on by it after decoding; never the far
    /// side's own idea of its hostname. Absent from the bare local projection, which nothing sshed to.
    public let host: String?
    public let endpoint: ControlZmxEndpoint
    public let sessions: [ControlRemoteSession]

    public init(host: String?, endpoint: ControlZmxEndpoint, sessions: [ControlRemoteSession]) {
        self.host = host
        self.endpoint = endpoint
        self.sessions = sessions
    }
}

/// `zmx list`'s payload. Carries the restore status as a header so a reader can tell whether the rows
/// describe a live-mode instance without a second call, and `inventoryComplete` because a false one is
/// what makes every unmatched row `unknown` rather than an orphan.
public struct ControlZmxInventory: Codable, Sendable, Equatable {
    public let restore: ControlRestoreStatus
    public let inventoryComplete: Bool
    /// Header rather than per row: one instance has one zmx and one socket directory. Optional so a
    /// remote reader can tell an older server apart from one that reports nothing to attach to.
    public let endpoint: ControlZmxEndpoint?
    public let entries: [ControlZmxEntry]

    public init(restore: ControlRestoreStatus, result: ZmxInventoryResult,
                endpoint: ControlZmxEndpoint? = nil) {
        self.restore = restore
        inventoryComplete = result.inventoryComplete
        self.endpoint = endpoint
        entries = result.rows.map(ControlZmxEntry.init(row:))
    }
}

/// `surface.cursor`'s payload, nested so a `row` could join it additively rather than by a rename.
///
/// There is no row: `tl_px_y` is the text BASELINE against an IME point at the cell bottom, leaving a term
/// no probe separates from the row, and `adjust-font-baseline = 30` was measured reporting row 5 for a caret
/// on row 4. `GhosttySurfaceView.readCursorColumn` owns why the horizontal twin is exact.
///
/// A column is a signal, not an assertion about content: past the prompt it proves the line is not empty,
/// AT the prompt it proves nothing, the caret having possibly moved back over text.
public struct ControlCursor: Codable, Sendable, Equatable {
    /// Zero-based, counted from the left edge of the grid.
    public let column: Int

    public init(column: Int) {
        self.column = column
    }
}
