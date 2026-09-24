import Foundation

/// Selection, next-launch narrowing and reporting for Agterm ▸ Reset Live Sessions… and `zmx.reset`.
/// Host-free: the app joins claims to daemons and kills; this decides which and reports what happened.
public enum LiveReset {
    /// One pane confirmed for reset, with the leader observed at confirmation so the next launch can
    /// tell the same daemon from a replacement.
    public struct Target: Codable, Hashable, Sendable {
        public let paneIdentity: UUID
        public let sessionID: UUID
        public let daemon: String
        public let leaderPID: Int32
        public let reason: Reason

        public init(paneIdentity: UUID, sessionID: UUID, daemon: String, leaderPID: Int32,
                    reason: Reason = .unsupervised) {
            self.paneIdentity = paneIdentity
            self.sessionID = sessionID
            self.daemon = daemon
            self.leaderPID = leaderPID
            self.reason = reason
        }

        /// init(from:) reads a version-1 target, which has no reason, as unsupervised.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneIdentity = try container.decode(UUID.self, forKey: .paneIdentity)
            sessionID = try container.decode(UUID.self, forKey: .sessionID)
            daemon = try container.decode(String.self, forKey: .daemon)
            leaderPID = try container.decode(Int32.self, forKey: .leaderPID)
            reason = try container.decodeIfPresent(Reason.self, forKey: .reason) ?? .unsupervised
        }
    }

    /// Reason is why a pane was selected. `unsupervised`: its leader is orphaned or attributed to the app.
    /// `outdated`: its daemon was created before this state directory's recorded zmx build change.
    public enum Reason: String, Codable, Sendable {
        case unsupervised, outdated
    }

    /// The confirmed set written at quit and consumed once at the next launch.
    public struct Marker: Codable, Equatable, Sendable {
        public static let currentVersion = 2
        /// supportedVersions lists what `LiveResetMarkerStore.consume` accepts: a reset confirmed under the
        /// previous version still runs after an update.
        public static let supportedVersions: Set<Int> = [1, 2]
        public let version: Int
        public let createdAt: Date
        public let targets: [Target]

        public init(targets: [Target], createdAt: Date = Date()) {
            self.version = Self.currentVersion
            self.createdAt = createdAt
            self.targets = targets
        }
    }

    /// Selection is what the dialog offers. An incomplete walk, or one pane claimed twice, forbids the action.
    public struct Selection: Equatable, Sendable {
        public let targets: [Target]
        public let inventoryComplete: Bool

        public init(targets: [Target], inventoryComplete: Bool) {
            self.targets = targets
            self.inventoryComplete = inventoryComplete
        }

        public var sessionCount: Int { Set(targets.map(\.sessionID)).count }
        public var outdatedSessionCount: Int { Set(targets.filter { $0.reason == .outdated }.map(\.sessionID)).count }
    }

    /// select picks a pane created before `outdatedBefore` as outdated whatever its attribution, and
    /// otherwise an orphaned or app-attributed one as unsupervised. A nil cutoff selects no outdated pane.
    public static func select(claims: ZmxClaimWalk, records: [ZmxSessionRecord], outdatedBefore: Date? = nil,
                              classify: (String, Int32) -> SessionHost.Attribution) -> Selection {
        let leaders = ZmxLeaderMap.leaders(in: records)
        let created = createdTimes(in: records)
        var seen: Set<UUID> = []
        var conflicted = false
        let targets = claims.claims.compactMap { claim -> Target? in
            guard seen.insert(claim.paneIdentity).inserted else { conflicted = true; return nil }
            let name = ZmxSupport.daemonName(for: claim.paneIdentity)
            guard let leader = leaders[name] else { return nil }
            func target(_ reason: Reason) -> Target {
                Target(paneIdentity: claim.paneIdentity, sessionID: claim.sessionID, daemon: name, leaderPID: leader,
                       reason: reason)
            }
            if isOutdated(created: created[name], cutoff: outdatedBefore) { return target(.outdated) }
            switch classify(name, leader) {
            case .orphaned, .app: return target(.unsupervised)
            case .supervisor, .unknown: return nil
            }
        }
        return Selection(targets: targets, inventoryComplete: claims.complete && !conflicted)
    }

    public static func isOutdated(created: Date?, cutoff: Date?) -> Bool {
        guard let created, let cutoff else { return false }
        return created < cutoff
    }

    private static func createdTimes(in records: [ZmxSessionRecord]) -> [String: Date] {
        Dictionary(records.compactMap { record in record.createdAt.map { (record.name, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    public enum Disposition: String, Codable, Equatable, Sendable {
        case kill, gone, skipped
    }

    /// Narrowed is the marker re-checked against this launch's claims and listing; it only narrows.
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

    /// narrow kills an outdated target that is still created before `outdatedBefore`, and an unsupervised one
    /// that is still orphaned; both must still be claimed and listed with the same leader.
    public static func narrow(marker: Marker, claimed: Set<UUID>?, records: [ZmxSessionRecord]?,
                              outdatedBefore: Date? = nil,
                              classify: (String, Int32) -> SessionHost.Attribution) -> Narrowed {
        guard let records, let claimed else {
            let skipped = Dictionary(marker.targets.map { ($0, Disposition.skipped) }, uniquingKeysWith: { first, _ in first })
            return Narrowed(dispositions: skipped, inventoryFailed: records == nil)
        }
        let byName = Dictionary(records.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var dispositions: [Target: Disposition] = [:]
        for target in marker.targets {
            guard claimed.contains(target.paneIdentity) else { dispositions[target] = .skipped; continue }
            guard let record = byName[target.daemon] else { dispositions[target] = .gone; continue }
            guard record.leaderPID == target.leaderPID else { dispositions[target] = .skipped; continue }
            let qualifies = switch target.reason {
            case .outdated: isOutdated(created: record.createdAt, cutoff: outdatedBefore)
            case .unsupervised: classify(target.daemon, target.leaderPID) == .orphaned
            }
            dispositions[target] = qualifies ? .kill : .skipped
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

    public static func dialogText(sessionCount: Int, outdatedSessions: Int = 0) -> (title: String, body: String) {
        let noun = sessionCount == 1 ? "live session" : "live sessions"
        return (title: "Reset Live Sessions?",
                body: "\(sessionCount) \(noun) will be reset. " + outdatedSentence(outdatedSessions, of: sessionCount)
                    + "Agterm quits and reopens itself right away with your "
                    + "sessions and layout. Commands that were running in those sessions are started again where "
                    + "possible; other work running in them stops, and agent conversations may need to be resumed by hand.")
    }

    private static func outdatedSentence(_ outdated: Int, of total: Int) -> String {
        guard outdated > 0 else { return "" }
        let tail = "the last Live sessions update and will be recreated on the current one. "
        if outdated == total { return (total == 1 ? "It predates " : "They all predate ") + tail }
        return outdated == 1 ? "1 of them predates " + tail : "\(outdated) of them predate " + tail
    }

    public static func notificationText(outcome: Outcome) -> String? {
        if outcome.inventoryFailed { return "Live sessions were not reset: the session list could not be read." }
        guard outcome.sessions.partial > 0 else { return nil }
        var text = "The reset covered \(outcome.sessions.reset) of \(outcome.sessions.affected) live sessions. "
            + "Run Agterm ▸ Reset Live Sessions… again for the rest."
        if outcome.sessions.unconfirmed > 0 {
            let noun = outcome.sessions.unconfirmed == 1 ? "session" : "sessions"
            text += " Some previous processes in \(outcome.sessions.unconfirmed) \(noun) may still be running; "
                + "those commands were not restarted."
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
    /// decode as a supported version; any other error is the rename failing, and the caller must then
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
              LiveReset.Marker.supportedVersions.contains(value.version) else {
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
