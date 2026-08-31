import Foundation

/// How a daemon relates to the panes agterm knows about.
public enum ZmxClaimState: String, Codable, Sendable {
    case claimed, orphan, unknown, conflicted, pendingClose, foreign
}

/// What the listing could see of the daemon itself. Separate from the client count because
/// `clients == nil` alone cannot distinguish a daemon that is gone from one zmx failed to read.
public enum ZmxDaemonObservation: String, Codable, Sendable {
    case running, unreadable, absent
}

/// The window a claim belongs to: loaded, persisted-but-closed, or present on disk yet missing from
/// `windows.json`.
public enum ZmxOwnerWindowState: String, Codable, Sendable {
    case open, closed, unindexed
}

/// Which pane of a session a claim belongs to. Deliberately two cases rather than `StatusPane`, whose
/// `scratch` can never be zmx-backed: an impossible state in a public model is one every reader has to
/// handle and no producer can create.
public enum ZmxPaneRole: String, Codable, Sendable {
    case left, right

    /// Accepts the same spellings the rest of the API takes for a pane, so `--pane primary` means here what
    /// it means everywhere else. Read-back stays `left`/`right`.
    public init?(controlName: String) {
        switch controlName.lowercased() {
        case "left", "top", "primary": self = .left
        case "right", "bottom", "split": self = .right
        default: return nil
        }
    }
}

/// One pane that expects a daemon, with the names and ids needed to explain and address it.
public struct ZmxPaneClaim: Equatable, Sendable {
    public let paneIdentity: UUID
    public let pane: ZmxPaneRole
    /// Soft-closed and inside its undo window: the pane is absent from `workspaces` but its daemon is
    /// still owned, so a runtime inventory that omitted it would label a live claim an orphan.
    public let pendingClose: Bool
    public let windowID: UUID
    /// Nil for an unindexed window: names live only in `windows.json`, which by definition lacks it.
    public let windowName: String?
    public let windowState: ZmxOwnerWindowState
    public let workspaceID: UUID?
    public let workspaceName: String?
    public let sessionID: UUID
    public let sessionName: String?

    public init(paneIdentity: UUID, pane: ZmxPaneRole, pendingClose: Bool, windowID: UUID, windowName: String?,
                windowState: ZmxOwnerWindowState, workspaceID: UUID?, workspaceName: String?,
                sessionID: UUID, sessionName: String?) {
        self.paneIdentity = paneIdentity
        self.pane = pane
        self.pendingClose = pendingClose
        self.windowID = windowID
        self.windowName = windowName
        self.windowState = windowState
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.sessionID = sessionID
        self.sessionName = sessionName
    }
}

/// The panes that expect a daemon, and whether the walk could account for everything it found.
/// Incomplete means some pane is unaccounted for, so nothing may be pruned against this answer.
public struct ZmxClaimWalk: Equatable, Sendable {
    public let claims: [ZmxPaneClaim]
    public let complete: Bool

    public init(claims: [ZmxPaneClaim], complete: Bool) {
        self.claims = claims
        self.complete = complete
    }
}

/// One row of the runtime inventory: a daemon, a pane, or both.
public struct ZmxInventoryRow: Equatable, Sendable {
    public let daemon: String
    public let state: ZmxClaimState
    public let observation: ZmxDaemonObservation
    public let clients: Int?
    public let leaderPID: Int32?
    /// Nil for a foreign daemon, an orphan, and a conflicted name — no single pane owns any of them.
    public let claim: ZmxPaneClaim?
}

/// The joined inventory. `inventoryComplete` is false when the claim walk could not account for
/// everything OR when two panes claim one daemon, since neither answer can be acted on.
public struct ZmxInventoryResult: Equatable, Sendable {
    public let rows: [ZmxInventoryRow]
    public let inventoryComplete: Bool
}

/// Joins what zmx reports against what agterm's panes claim.
public enum ZmxInventory {
    /// Builds the union of observed daemons and expected claims, sorted by daemon name. Rows are the
    /// union rather than an intersection so `list` can explain both a leaked daemon and a pane whose
    /// daemon has vanished, and so `prune` can be audited against what `list` showed.
    public static func join(observed: [ZmxSessionRecord], claims: [ZmxPaneClaim],
                            inventoryComplete: Bool) -> ZmxInventoryResult {
        var claimsByName: [String: [ZmxPaneClaim]] = [:]
        for claim in claims {
            claimsByName[ZmxSupport.daemonName(for: claim.paneIdentity), default: []].append(claim)
        }
        let conflicted = Set(claimsByName.filter { $0.value.count > 1 }.keys)

        var rows: [ZmxInventoryRow] = []
        var observedNames: Set<String> = []
        for record in observed {
            observedNames.insert(record.name)
            rows.append(DaemonFacts(record).row(claims: claimsByName[record.name] ?? [],
                                                isConflicted: conflicted.contains(record.name),
                                                inventoryComplete: inventoryComplete))
        }
        for (name, group) in claimsByName where !observedNames.contains(name) {
            rows.append(DaemonFacts(absent: name).row(claims: group,
                                                      isConflicted: conflicted.contains(name),
                                                      inventoryComplete: inventoryComplete))
        }

        return ZmxInventoryResult(rows: rows.sorted { $0.daemon < $1.daemon },
                                  inventoryComplete: inventoryComplete && conflicted.isEmpty)
    }

    /// What the listing saw of one daemon, before any claim is applied.
    private struct DaemonFacts {
        let daemon: String
        let observation: ZmxDaemonObservation
        let clients: Int?
        let leaderPID: Int32?

        init(_ record: ZmxSessionRecord) {
            daemon = record.name
            observation = record.clients == nil ? .unreadable : .running
            clients = record.clients
            leaderPID = record.leaderPID
        }

        init(absent daemon: String) {
            self.daemon = daemon
            observation = .absent
            clients = nil
            leaderPID = nil
        }

        func row(claims: [ZmxPaneClaim], isConflicted: Bool, inventoryComplete: Bool) -> ZmxInventoryRow {
            let state: ZmxClaimState
            var claim: ZmxPaneClaim?
            if isConflicted {
                state = .conflicted
            } else if let owner = claims.first {
                state = owner.pendingClose ? .pendingClose : .claimed
                claim = owner
            } else if ZmxSupport.isDaemonName(daemon) {
                // an unmatched name is only an orphan when the claim walk saw everything; otherwise the
                // pane that owns it may simply be one this inventory could not read.
                state = inventoryComplete ? .orphan : .unknown
            } else {
                state = .foreign
            }
            return ZmxInventoryRow(daemon: daemon, state: state, observation: observation,
                                   clients: clients, leaderPID: leaderPID, claim: claim)
        }
    }
}

/// Decides which daemons `prune` may take.
public enum ZmxPrunePolicy {
    /// Nil when no prune is safe at all. Every term is required: a complete, conflict-free inventory, an
    /// identity no pane claims, and a daemon observed running with no clients. A closed window's panes
    /// are claimed with zero clients, so the client count alone never implies an orphan.
    ///
    /// Observed, not guaranteed: pinned zmx has no kill-if-detached, so the caller must re-list
    /// immediately before it mutates and drop anything that gained a client.
    public static func namesToPrune(_ result: ZmxInventoryResult) -> [String]? {
        guard result.inventoryComplete else { return nil }
        return result.rows
            .filter { $0.state == .orphan && $0.observation == .running && $0.clients == 0 }
            .map(\.daemon)
    }
}
