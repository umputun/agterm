import Foundation

/// PendingOpenerClicks holds the clicks this Mac forwarded asking for a snapshot, each scoped to the presentation
/// connection, session and pane it was made in and carrying the `open` rules of click time, so a keymap reload
/// during the transfer cannot change which command runs. An entry stays, in flight, from an accepted snapshot until
/// the spawn or a failure retires it; one whose origin opened a page instead is never answered and expires.
@MainActor
public final class PendingOpenerClicks {
    /// window bounds how long a click waits for its snapshot, the origin's own claim window.
    public static let window = AppStore.pageClaimWindow
    /// readDeadline bounds an accepted snapshot's transfer, the largest page's file over a slow link included.
    public static let readDeadline: TimeInterval = 120

    public struct Entry: Equatable, Sendable {
        public let click: UUID
        public let connection: UUID
        public let session: UUID
        public let pane: UUID
        public let candidates: [String]
        public let rules: [FileOpener]
        let created: Date
        fileprivate var accepted: Date?
        public var inFlight: Bool { accepted != nil }
    }

    private var entries: [UUID: Entry] = [:]
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// contains says whether `click` is still booked, for state a caller keeps beside the book.
    public func contains(_ click: UUID) -> Bool { entries[click] != nil }

    /// record books a click on `raw` when one of `rules` takes a name it may resolve to, and returns its id; nil when
    /// none could, which sends the click as before.
    public func record(raw: String, connection: UUID, session: UUID, pane: UUID, rules: [FileOpener]) -> UUID? {
        expire()
        let candidates = LinkPolicy.candidateNames(for: raw)
        let eligible = rules.filter { rule in candidates.contains { rules.opener(forFile: $0) == rule } }
        guard !eligible.isEmpty else { return nil }
        let click = UUID()
        entries[click] = Entry(click: click, connection: connection, session: session, pane: pane, candidates: candidates,
                               rules: eligible, created: now())
        return click
    }

    /// selectors are the selector texts of a booked click's rules that take one of its candidate names.
    public func selectors(for click: UUID) -> [String] {
        guard let entry = entries[click] else { return [] }
        var texts: [String] = []
        for selector in entry.rules.flatMap(\.selectors) where entry.candidates.contains(where: selector.matches) {
            if !texts.contains(selector.text) { texts.append(selector.text) }
        }
        return texts
    }

    /// accept takes the one snapshot a booked click may get: from its own connection and session, within the window,
    /// for one of its candidate names within its page's cap, and only once. It returns the entry, now in flight, and
    /// the rule the name picks.
    public func accept(_ snapshot: PresentationLinkSnapshot, connection: UUID,
                       session: UUID) -> (entry: Entry, rule: FileOpener)? {
        expire()
        guard snapshot.isAcceptable, var entry = entries[snapshot.click], !entry.inFlight, entry.connection == connection,
              entry.session == session, entry.candidates.contains(snapshot.name),
              let rule = entry.rules.opener(forFile: snapshot.name) else { return nil }
        entry.accepted = now()
        entries[snapshot.click] = entry
        return (entry, rule)
    }

    /// isCurrent says whether `click` is still booked on `connection`, rechecked before the spawn.
    public func isCurrent(_ click: UUID, connection: UUID) -> Bool {
        entries[click]?.connection == connection
    }

    /// retire removes a click for its spawn, a failure or a refusal naming it.
    @discardableResult
    public func retire(_ click: UUID) -> Entry? {
        entries.removeValue(forKey: click)
    }

    /// teardown removes every click of a connection that ended; the caller cancels the in-flight ones' transfers.
    public func teardown(connection: UUID) -> [Entry] {
        let gone = entries.values.filter { $0.connection == connection }
        for entry in gone { entries[entry.click] = nil }
        return gone
    }

    /// expire drops the clicks no snapshot reached within the window.
    public func expire() {
        let cutoff = now().addingTimeInterval(-Self.window)
        entries = entries.filter { $0.value.inFlight || $0.value.created >= cutoff }
    }

    /// overdue lists the in-flight clicks whose transfer outlived `readDeadline`; the caller retires and fails them.
    public func overdue() -> [Entry] {
        let cutoff = now().addingTimeInterval(-Self.readDeadline)
        return entries.values.filter { $0.accepted.map { $0 < cutoff } ?? false }
    }
}
