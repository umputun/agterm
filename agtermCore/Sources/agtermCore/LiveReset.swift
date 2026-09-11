import Foundation

/// Selection, next-launch narrowing and reporting for Help ▸ Reset Live Sessions… and `zmx.reset`.
/// Host-free: the app joins claims to daemons and kills; this decides which and reports what happened.
public enum LiveReset {
    /// One pane confirmed for reset, with the leader observed at confirmation so the next launch can
    /// tell the same daemon from a replacement.
    public struct Target: Codable, Hashable, Sendable {
        public let paneIdentity: UUID
        public let sessionID: UUID
        public let daemon: String
        public let leaderPID: Int32

        public init(paneIdentity: UUID, sessionID: UUID, daemon: String, leaderPID: Int32) {
            self.paneIdentity = paneIdentity
            self.sessionID = sessionID
            self.daemon = daemon
            self.leaderPID = leaderPID
        }
    }

    /// The confirmed set written at quit and consumed once at the next launch.
    public struct Marker: Codable, Equatable, Sendable {
        public static let currentVersion = 1
        public let version: Int
        public let createdAt: Date
        public let targets: [Target]

        public init(targets: [Target], createdAt: Date = Date()) {
            self.version = Self.currentVersion
            self.createdAt = createdAt
            self.targets = targets
        }
    }

    /// What the dialog offers: the panes whose process is not supervised, and whether the walk that
    /// found them was complete. An incomplete walk forbids the action.
    public struct Selection: Equatable, Sendable {
        public let targets: [Target]
        public let inventoryComplete: Bool

        public var sessionCount: Int { Set(targets.map(\.sessionID)).count }
    }

    public static func select(claims: ZmxClaimWalk, records: [ZmxSessionRecord],
                              classify: (String, Int32) -> SessionHost.Attribution) -> Selection {
        let leaders = ZmxLeaderMap.leaders(in: records)
        let targets = claims.claims.compactMap { claim -> Target? in
            let name = ZmxSupport.daemonName(for: claim.paneIdentity)
            guard let leader = leaders[name] else { return nil }
            switch classify(name, leader) {
            case .orphaned, .app:
                return Target(paneIdentity: claim.paneIdentity, sessionID: claim.sessionID, daemon: name, leaderPID: leader)
            case .supervisor, .unknown:
                return nil
            }
        }
        return Selection(targets: targets, inventoryComplete: claims.complete)
    }

    public enum Disposition: String, Codable, Equatable, Sendable {
        case kill, gone, skipped
    }

    /// The marker re-checked against the launch's own claims and listing. Only narrows: a target is
    /// killed when it is still claimed, still listed with the same leader, and still orphaned.
    public struct Narrowed: Equatable, Sendable {
        public let dispositions: [Target: Disposition]
        public let inventoryFailed: Bool

        public init(dispositions: [Target: Disposition], inventoryFailed: Bool) {
            self.dispositions = dispositions
            self.inventoryFailed = inventoryFailed
        }

        public var kill: [Target] {
            dispositions.filter { $0.value == .kill }.map(\.key).sorted { $0.daemon < $1.daemon }
        }
    }

    public static func narrow(marker: Marker, claimed: Set<UUID>?, records: [ZmxSessionRecord]?,
                              classify: (String, Int32) -> SessionHost.Attribution) -> Narrowed {
        guard let records, let claimed else {
            let skipped = Dictionary(uniqueKeysWithValues: marker.targets.map { ($0, Disposition.skipped) })
            return Narrowed(dispositions: skipped, inventoryFailed: records == nil)
        }
        let byName = Dictionary(records.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var dispositions: [Target: Disposition] = [:]
        for target in marker.targets {
            guard claimed.contains(target.paneIdentity) else { dispositions[target] = .skipped; continue }
            guard let record = byName[target.daemon] else { dispositions[target] = .gone; continue }
            guard record.leaderPID == target.leaderPID, classify(target.daemon, target.leaderPID) == .orphaned else {
                dispositions[target] = .skipped
                continue
            }
            dispositions[target] = .kill
        }
        return Narrowed(dispositions: dispositions, inventoryFailed: false)
    }

    public struct PaneCounts: Codable, Equatable, Sendable {
        public let confirmed: Int
        public let killed: Int
        public let gone: Int
        public let skipped: Int

        public init(confirmed: Int, killed: Int, gone: Int, skipped: Int) {
            self.confirmed = confirmed
            self.killed = killed
            self.gone = gone
            self.skipped = skipped
        }
    }

    /// Distinct sessions among the targets. A session is reset only when every one of its panes was
    /// killed and confirmed gone or had no daemon; any other pane makes it partial.
    public struct SessionCounts: Codable, Equatable, Sendable {
        public let affected: Int
        public let reset: Int
        public let partial: Int
        public let unconfirmed: Int

        public init(affected: Int, reset: Int, partial: Int, unconfirmed: Int) {
            self.affected = affected
            self.reset = reset
            self.partial = partial
            self.unconfirmed = unconfirmed
        }
    }

    public struct Outcome: Codable, Equatable, Sendable {
        public let panes: PaneCounts
        public let unconfirmed: [UUID]
        public let sessions: SessionCounts
        public let inventoryFailed: Bool

        public init(panes: PaneCounts, unconfirmed: [UUID], sessions: SessionCounts, inventoryFailed: Bool) {
            self.panes = panes
            self.unconfirmed = unconfirmed
            self.sessions = sessions
            self.inventoryFailed = inventoryFailed
        }
    }

    /// `survivors` are the leader pids still alive after the kill and the poll; their panes are the
    /// ones whose launch payloads must be suppressed.
    public static func outcome(narrowed: Narrowed, survivors: Set<Int32>, inventoryFailed: Bool) -> Outcome {
        var killed = 0, gone = 0, skipped = 0
        var unconfirmed: [UUID] = []
        var resetSessions: Set<UUID> = [], partialSessions: Set<UUID> = [], unconfirmedSessions: Set<UUID> = []
        for (target, disposition) in narrowed.dispositions.sorted(by: { $0.key.daemon < $1.key.daemon }) {
            switch disposition {
            case .gone:
                gone += 1
                resetSessions.insert(target.sessionID)
            case .skipped:
                skipped += 1
                partialSessions.insert(target.sessionID)
            case .kill where survivors.contains(target.leaderPID):
                unconfirmed.append(target.paneIdentity)
                partialSessions.insert(target.sessionID)
                unconfirmedSessions.insert(target.sessionID)
            case .kill:
                killed += 1
                resetSessions.insert(target.sessionID)
            }
        }
        resetSessions.subtract(partialSessions)
        return Outcome(
            panes: PaneCounts(confirmed: narrowed.dispositions.count, killed: killed, gone: gone, skipped: skipped),
            unconfirmed: unconfirmed,
            sessions: SessionCounts(affected: resetSessions.count + partialSessions.count, reset: resetSessions.count,
                                    partial: partialSessions.count, unconfirmed: unconfirmedSessions.count),
            inventoryFailed: inventoryFailed)
    }

    public static let markerFilename = "live-reset.json"
    public static let consumedFilename = "live-reset.consumed.json"

    public static func dialogText(sessionCount: Int) -> (title: String, body: String) {
        let noun = sessionCount == 1 ? "live session" : "live sessions"
        return (title: "Reset Live Sessions?",
                body: "\(sessionCount) \(noun) will be reset. Agterm quits and reopens itself right away with your "
                    + "sessions and layout. Commands that were running in those sessions are started again where "
                    + "possible; other work running in them stops, and agent conversations may need to be resumed by hand.")
    }

    public static func notificationText(outcome: Outcome) -> String? {
        if outcome.inventoryFailed { return "Live sessions were not reset: the session list could not be read." }
        guard outcome.sessions.partial > 0 else { return nil }
        var text = "The reset covered \(outcome.sessions.reset) of \(outcome.sessions.affected) live sessions. "
            + "Run Help ▸ Reset Live Sessions… again for the rest."
        if outcome.sessions.unconfirmed > 0 {
            let one = outcome.sessions.unconfirmed == 1
            text += " Previous processes in \(outcome.sessions.unconfirmed) \(one ? "session" : "sessions") may still be "
                + "running, and commands in \(one ? "that session" : "those sessions") were not restarted."
        }
        return text
    }

    public static func menuVisible(configured: RestoreMode, active: RestoreMode) -> Bool {
        configured == .live && active == .live
    }
}

/// The one-shot marker on disk. `consume` renames before decoding so a crash mid-reset never replays it.
public struct LiveResetMarkerStore {
    public enum Failure: Error, Equatable {
        case invalid
    }

    private let marker: URL
    private let consumed: URL

    public init(directory: URL) {
        marker = directory.appendingPathComponent(LiveReset.markerFilename)
        consumed = directory.appendingPathComponent(LiveReset.consumedFilename)
    }

    public func write(_ value: LiveReset.Marker) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(value).write(to: marker, options: .atomic)
    }

    /// Nil when no marker exists. Throws `.invalid`, after removing the file, for anything that does not
    /// decode as the current version; any other error is the rename failing, and the caller must then
    /// treat the reset as not authorized.
    public func consume() throws -> LiveReset.Marker? {
        let files = FileManager.default
        guard files.fileExists(atPath: marker.path) else { return nil }
        if files.fileExists(atPath: consumed.path) { try files.removeItem(at: consumed) }
        try files.moveItem(at: marker, to: consumed)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: consumed),
              let value = try? decoder.decode(LiveReset.Marker.self, from: data),
              value.version == LiveReset.Marker.currentVersion else {
            try? files.removeItem(at: consumed)
            throw Failure.invalid
        }
        return value
    }

    public func removeConsumed() {
        try? FileManager.default.removeItem(at: consumed)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: marker)
        removeConsumed()
    }
}
