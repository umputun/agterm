import Foundation

/// RemoteRespawnBook joins what an origin reports about respawning a pane's shell with that pane's held exit
/// on this Mac, one entry per LOCAL pane: two rows attached to one origin pane each reattach on their own.
///
/// A held exit alone keeps today's exit prompt. One the origin has respawned since the pane's baseline is
/// attached again, attach-only. Every attach of a remote pane, a network reconnect or a takeover included,
/// starts an attempt carrying the latest mark known at that moment, and only that attempt's role report moves
/// the baseline, to that mark. An entry has no expiry while its row lives, however long the presentation stream
/// is down; `prune` drops the entries of rows that are gone.
@MainActor
public final class RemoteRespawnBook {
    public static let shared = RemoteRespawnBook()
    /// Attaches tried for one generation before the pane stays on its exit prompt.
    public static let maxAttempts = 3

    public struct Mark: Equatable, Sendable {
        public let epoch: String
        public let generation: Int

        public init(epoch: String, generation: Int) {
            self.epoch = epoch
            self.generation = generation
        }
    }

    public struct Attempt: Equatable, Sendable {
        /// mark is what the attach started against, nil before the first snapshot.
        public let mark: Mark?
    }

    public struct Entry: Equatable, Sendable {
        public let session: UUID
        public fileprivate(set) var baseline: Mark?
        public fileprivate(set) var latest: Mark?
        public fileprivate(set) var held = false
        public fileprivate(set) var attempt: Attempt?
        /// failures counts attaches for `latest` that ended before reporting a role.
        public fileprivate(set) var failures = 0
    }

    public private(set) var entries: [UUID: Entry] = [:]

    init() {}

    /// observe records what the origin reports for `pane` of `session`; a snapshot (`seed`) becomes the baseline only
    /// when there is none, so a reconnect compares against it and recovers a respawn whose frame was missed. True
    /// when the pane should be attached again now.
    public func observe(_ mark: Mark, pane: UUID, session: UUID, seed: Bool) -> Bool {
        var entry = entries[pane] ?? Entry(session: session)
        if seed, entry.baseline == nil { entry.baseline = mark }
        if entry.latest != mark { entry.failures = 0 }
        entry.latest = mark
        entries[pane] = entry
        return Self.due(entry)
    }

    /// held records that the pane's attach exited cleanly. An attempt that ends before reporting a role counts as
    /// a failure only when it was for the generation still latest. True when the pane should be attached again now.
    public func held(pane: UUID, session: UUID) -> Bool {
        var entry = entries[pane] ?? Entry(session: session)
        if let attempt = entry.attempt {
            entry.attempt = nil
            if attempt.mark == entry.latest { entry.failures += 1 }
        }
        entry.held = true
        entries[pane] = entry
        return Self.due(entry)
    }

    /// attachStarted records any new attach of the pane, against the latest mark known now.
    public func attachStarted(pane: UUID, session: UUID) {
        var entry = entries[pane] ?? Entry(session: session)
        entry.attempt = Attempt(mark: entry.latest)
        entry.held = false
        entries[pane] = entry
    }

    /// acknowledged moves the baseline to the mark the reporting attachment started against, never past it.
    public func acknowledged(pane: UUID) {
        guard var entry = entries[pane], let attempt = entry.attempt else { return }
        entry.attempt = nil
        if let mark = attempt.mark { entry.baseline = mark }
        if entry.baseline == entry.latest { entry.failures = 0 }
        entries[pane] = entry
    }

    /// prune drops the entries whose pane `keep` no longer vouches for.
    public func prune(keep: (_ pane: UUID, _ session: UUID) -> Bool) {
        entries = entries.filter { keep($0.key, $0.value.session) }
    }

    private static func due(_ entry: Entry) -> Bool {
        guard entry.held, entry.attempt == nil, entry.failures < maxAttempts, let latest = entry.latest else { return false }
        guard let baseline = entry.baseline else { return latest.generation > 0 }
        return latest.epoch == baseline.epoch ? latest.generation > baseline.generation : latest.generation > 0
    }
}
