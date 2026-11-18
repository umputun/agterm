import Foundation
import agtermCore

/// RemoteOpeners is this Mac's side of the `open` rules that run on files another host offers: the clicks waiting
/// for a snapshot, the pane each was clicked in, and the transfer of each accepted one. A timeout, a refusal and the
/// spawn can race for one click, so each goes through `finish` and only the caller that retired it acts.
@MainActor
final class RemoteOpeners {
    private final class WeakSurface {
        weak var surface: GhosttySurfaceView?
        init(_ surface: GhosttySurfaceView) { self.surface = surface }
    }

    private struct Transfer {
        let channel: RemotePageChannel
        let release: () -> Void
    }

    var now: () -> Date = Date.init
    private(set) lazy var book = PendingOpenerClicks(now: { [unowned self] in now() })
    /// rules are the keymap's `open` rules, read at click time.
    var rules: () -> [FileOpener] = { [] }
    var staging = OpenerStaging()
    /// launch runs a rule on a staged copy with the clicked pane's context, naming the host the file came from, and
    /// returns why it did not start, nil once it has.
    var launch: (FileOpener, URL, GhosttySurfaceView, String) -> String? = { _, _, _, _ in "no runner" }
    private var surfaces: [UUID: WeakSurface] = [:]
    private var transfers: [UUID: Transfer] = [:]

    /// record books a click in `surface` when a rule takes a name it may resolve to; nil sends it without a snapshot.
    func record(raw: String, connection: UUID, session: UUID, surface: GhosttySurfaceView) -> UUID? {
        defer { prune() }
        guard let click = book.record(raw: raw, connection: connection, session: session, rules: rules()) else {
            return nil
        }
        surfaces[click] = WeakSurface(surface)
        return click
    }

    func accept(_ snapshot: PresentationLinkSnapshot, connection: UUID,
                session: UUID) -> (entry: PendingOpenerClicks.Entry, rule: FileOpener)? {
        defer { prune() }
        return book.accept(snapshot, connection: connection, session: session)
    }

    func surface(for click: UUID) -> GhosttySurfaceView? { surfaces[click]?.surface }

    func begin(_ click: UUID, channel: RemotePageChannel, release: @escaping () -> Void) {
        transfers[click] = Transfer(channel: channel, release: release)
    }

    /// transfers says whether `channel` still carries `click`'s file, false once anything ended either.
    func transfers(_ click: UUID, on channel: RemotePageChannel) -> Bool { transfers[click]?.channel === channel }

    /// endTransfer closes a click's channel and releases its connection, leaving the click booked for its spawn.
    func endTransfer(_ click: UUID) {
        guard let transfer = transfers.removeValue(forKey: click) else { return }
        transfer.channel.close("snapshot read")
        transfer.release()
    }

    /// finish retires `click` and ends its transfer; true only for the caller that retired it.
    @discardableResult
    func finish(_ click: UUID) -> Bool {
        guard book.retire(click) != nil else { return false }
        endTransfer(click)
        prune()
        return true
    }

    /// teardown ends every click of a connection that went away and returns the ones whose snapshot was in flight.
    @discardableResult
    func teardown(connection: UUID) -> [PendingOpenerClicks.Entry] {
        let gone = book.teardown(connection: connection)
        for entry in gone { endTransfer(entry.click) }
        prune()
        return gone.filter(\.inFlight)
    }

    /// overdue retires the transfers still reading past the read deadline and returns them, for the caller to report;
    /// a click whose bytes all arrived is being staged and is left to its spawn.
    func overdue() -> [PendingOpenerClicks.Entry] {
        book.expire()
        let late = book.overdue().filter { transfers[$0.click] != nil && finish($0.click) }
        prune()
        return late
    }

    var isIdle: Bool { book.isEmpty && surfaces.isEmpty && transfers.isEmpty }

    // the book also expires clicks inside record and accept without naming them, so the side tables follow it
    private func prune() {
        surfaces = surfaces.filter { book.contains($0.key) }
        for click in transfers.keys where !book.contains(click) { endTransfer(click) }
    }
}
