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

/// `zmx list`'s payload. Carries the restore status as a header so a reader can tell whether the rows
/// describe a live-mode instance without a second call, and `inventoryComplete` because a false one is
/// what makes every unmatched row `unknown` rather than an orphan.
public struct ControlZmxInventory: Codable, Sendable, Equatable {
    public let restore: ControlRestoreStatus
    public let inventoryComplete: Bool
    public let entries: [ControlZmxEntry]

    public init(restore: ControlRestoreStatus, result: ZmxInventoryResult) {
        self.restore = restore
        inventoryComplete = result.inventoryComplete
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
