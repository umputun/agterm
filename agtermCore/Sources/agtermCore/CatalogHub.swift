import Foundation

/// CatalogSink is where the hub hands a subscriber's frames; the bounded queue and the socket live behind it.
@MainActor
public protocol CatalogSink: AnyObject {
    /// offer returns false when the consumer's queue is full, which the hub treats as a stalled subscriber.
    func offer(_ frame: CatalogFrame) -> Bool
    func close(_ reason: CatalogHub.CloseReason)
}

/// CatalogHub numbers a headless store's catalog within one epoch and streams it to its viewers: each one gets the
/// snapshot, then every change as a delta with its own revision.
@MainActor
public final class CatalogHub {
    public enum CloseReason: Equatable, Sendable {
        case stalled
        case stale
        case unsendable
    }

    public enum SubscribeError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    public struct SubscriberID: Hashable, Sendable {
        let value: Int
    }

    private final class Subscriber {
        let sink: CatalogSink
        /// pageRows is whether the viewer shows page rows; an older one is sent the catalog without them.
        let pageRows: Bool
        // the first ping still unanswered; a late heartbeat sends a ping before it can call the subscriber stale
        var pingedAt: Date?

        init(sink: CatalogSink, pageRows: Bool) {
            self.sink = sink
            self.pageRows = pageRows
        }
    }

    public let epoch: String
    public private(set) var rev = 0
    private let source: @MainActor () -> CatalogSnapshot
    private let staleTimeout: TimeInterval
    private let now: () -> Date
    private var current: CatalogSnapshot?
    private var subscribers: [SubscriberID: Subscriber] = [:]
    private var lastID = 0

    /// `source` projects the store; its epoch and revision are ignored and replaced with the hub's.
    public init(epoch: String, staleTimeout: TimeInterval, now: @escaping () -> Date = Date.init,
                source: @escaping @MainActor () -> CatalogSnapshot) {
        self.epoch = epoch
        self.staleTimeout = staleTimeout
        self.now = now
        self.source = source
    }

    /// snapshot is the catalog as of the current revision, after any change not yet published.
    public func snapshot() -> CatalogSnapshot {
        refresh()
        return current ?? stamped(source())
    }

    /// refresh projects the store again and publishes what changed, one revision per change. Nothing changed
    /// publishes nothing, so callers run it after anything that may have changed the catalog. A viewer without page
    /// rows gets the same revisions: the changes of its filtered catalog first, then a skip for each one left.
    public func refresh() {
        let next = stamped(source())
        guard let previous = current else {
            current = next
            return
        }
        guard previous.workspaces != next.workspaces else { return }
        let first = rev + 1
        var state = previous
        var frames: [CatalogFrame] = []
        for change in previous.changes(to: next) {
            rev += 1
            state.apply(change)
            frames.append(.delta(epoch: epoch, rev: rev, change: change))
        }
        state.rev = rev
        current = state
        let older = subscribers.values.contains { !$0.pageRows } ? withoutPageRowFrames(from: previous, to: state, first: first) : []
        for (id, subscriber) in subscribers {
            for frame in subscriber.pageRows ? frames : older {
                guard send(frame, to: id) else { break }
            }
        }
    }

    /// withoutPageRowFrames are revisions `first...rev` for a viewer without page rows. A filtered diff longer than
    /// the full one cannot fit those revisions, so that viewer takes the filtered snapshot at `rev` instead.
    private func withoutPageRowFrames(from previous: CatalogSnapshot, to next: CatalogSnapshot, first: Int) -> [CatalogFrame] {
        let filtered = Self.withoutPageRows(next)
        let changes = Self.withoutPageRows(previous).changes(to: filtered)
        guard changes.count <= rev - first + 1 else { return (try? CatalogCodec.snapshotFrames(filtered)) ?? [] }
        let deltas = changes.enumerated().map { CatalogFrame.delta(epoch: epoch, rev: first + $0.offset, change: $0.element) }
        let skips = (first + changes.count..<rev + 1).map { CatalogFrame.unknown(kind: CatalogFrame.skipKind, epoch: epoch, rev: $0) }
        return deltas + skips
    }

    /// withoutPageRows is `snapshot` as a viewer without page rows sees it: a companion of a page row shows top-level.
    static func withoutPageRows(_ snapshot: CatalogSnapshot) -> CatalogSnapshot {
        let pages = Set(snapshot.workspaces.flatMap(\.sessions).filter { $0.fields.page != nil }.map(\.id))
        guard !pages.isEmpty else { return snapshot }
        var filtered = snapshot
        for index in filtered.workspaces.indices {
            filtered.workspaces[index].sessions = filtered.workspaces[index].sessions.compactMap { session in
                guard !pages.contains(session.id) else { return nil }
                var session = session
                if let parent = session.fields.parent, pages.contains(parent) { session.fields.parent = nil }
                return session
            }
        }
        return filtered
    }

    /// subscribe registers a viewer and sends it hello, then the snapshot. Pending changes are published to
    /// everyone else first, so the snapshot and the deltas that follow it meet at the same revision.
    @discardableResult
    public func subscribe(hello: CatalogHello, sink: CatalogSink, versions: CatalogVersions) throws -> SubscriberID {
        guard hello.version >= 1 else { throw SubscribeError.unsupportedVersion(hello.version) }
        let pageRows = hello.pageRows == true
        let state = pageRows ? snapshot() : Self.withoutPageRows(snapshot())
        lastID += 1
        let id = SubscriberID(value: lastID)
        subscribers[id] = Subscriber(sink: sink, pageRows: pageRows)
        let answer = CatalogHello(version: min(hello.version, CatalogCodec.version), epoch: epoch, versions: versions)
        let frames: [CatalogFrame]
        do {
            frames = [.hello(answer)] + (try CatalogCodec.snapshotFrames(state))
        } catch {
            drop(id, reason: .unsendable)
            return id
        }
        for frame in frames {
            guard send(frame, to: id) else { break }
        }
        return id
    }

    public func unsubscribe(_ id: SubscriberID) {
        subscribers[id] = nil
    }

    public func receive(_ frame: CatalogFrame, from id: SubscriberID) {
        guard let subscriber = subscribers[id] else { return }
        switch frame {
        case .ack: subscriber.pingedAt = nil
        case .ping: send(.ack, to: id)
        default: break
        }
    }

    /// heartbeat closes every subscriber that left a ping unanswered past the stale timeout and pings the rest.
    public func heartbeat() {
        let current = now()
        for (id, subscriber) in subscribers {
            if let pingedAt = subscriber.pingedAt, current.timeIntervalSince(pingedAt) > staleTimeout {
                drop(id, reason: .stale)
                continue
            }
            if subscriber.pingedAt == nil { subscriber.pingedAt = current }
            send(.ping, to: id)
        }
    }

    public var subscriberCount: Int { subscribers.count }

    private func stamped(_ snapshot: CatalogSnapshot) -> CatalogSnapshot {
        var snapshot = snapshot
        snapshot.epoch = epoch
        snapshot.rev = rev
        return snapshot
    }

    @discardableResult
    private func send(_ frame: CatalogFrame, to id: SubscriberID) -> Bool {
        guard let subscriber = subscribers[id] else { return false }
        guard subscriber.sink.offer(frame) else {
            drop(id, reason: .stalled)
            return false
        }
        return true
    }

    private func drop(_ id: SubscriberID, reason: CloseReason) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        subscriber.sink.close(reason)
    }
}
