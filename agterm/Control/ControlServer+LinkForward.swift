import Foundation
import agtermCore

/// LinkForwards holds the port forwards that loopback links clicked in programs on other hosts open through: one per
/// remote loopback port, shared by every click on it, each click opening its own address once the forward answers.
@MainActor
final class LinkForwards {
    /// Key is one loopback port on one host. A remote window's forward lives on that window's pool, so `window` keeps it
    /// apart from an attached row's forward to the same host.
    struct Key: Hashable {
        let window: UUID?
        let sshHost: String
        let host: String
        let port: Int
    }

    private struct Waiter {
        let row: UUID
        let page: ForwardedPage
        let done: @MainActor (URL?) -> Void
    }

    private final class Record {
        let forward: PageForward
        let localPort: Int
        let generation: Int
        var ready = false
        var rows: Set<UUID> = []
        var waiters: [Waiter] = []

        init(forward: PageForward, localPort: Int, generation: Int) {
            self.forward = forward
            self.localPort = localPort
            self.generation = generation
        }
    }

    private var records: [Key: Record] = [:]
    private var generation = 0

    /// open answers `done` with `page`'s address at the local end of `key`'s forward once it answers, starting one with
    /// `make` when none runs. `make` gets the local port and the event sink and answers nil when no forward can start.
    func open(_ page: ForwardedPage, row: UUID, key: Key, done: @escaping @MainActor (URL?) -> Void,
              make: (_ localPort: Int, _ onEvent: @escaping @MainActor (PortForwardEvent) -> Void) -> PageForward?) {
        if let record = records[key] {
            record.rows.insert(row)
            if record.ready { return done(page.url(localPort: record.localPort)) }
            record.waiters.append(Waiter(row: row, page: page, done: done))
            return
        }
        generation += 1
        let generation = generation
        guard let port = RemotePortForward.freePort(host: page.host),
              let forward = make(port, { [weak self] in self?.event($0, key: key, generation: generation) }) else { return done(nil) }
        let record = Record(forward: forward, localPort: port, generation: generation)
        record.rows = [row]
        record.waiters = [Waiter(row: row, page: page, done: done)]
        records[key] = record
        forward.start()
    }

    /// release drops `row`'s clicks still waiting, so none opens for a row that went away, and ends an attached row's
    /// forward once no row uses it; a remote window's forward stays until the window's pool ends.
    func release(row: UUID) {
        for (key, record) in records {
            record.waiters.removeAll { $0.row == row }
            guard key.window == nil else { continue }
            record.rows.remove(row)
            if record.rows.isEmpty { stop(key) }
        }
    }

    /// stop(window:) ends the forwards on remote window `window`'s pool, which is closing.
    func stop(window: UUID) {
        for key in records.keys where key.window == window { stop(key) }
    }

    func stopAll() {
        for key in Array(records.keys) { stop(key) }
    }

    private func stop(_ key: Key) {
        records.removeValue(forKey: key)?.forward.stop()
    }

    private func event(_ event: PortForwardEvent, key: Key, generation: Int) {
        guard let record = records[key], record.generation == generation else { return }
        let waiters = record.waiters
        record.waiters = []
        switch event {
        case .ready:
            record.ready = true
            for waiter in waiters { waiter.done(waiter.page.url(localPort: record.localPort)) }
        case .failed:
            stop(key)
            for waiter in waiters { waiter.done(nil) }
        }
    }
}

extension ControlServer {
    /// forwardLoopback opens `page`, a loopback address on row `row`'s host, through a forward from this Mac: on a remote
    /// window's pool for one of its rows, in an ssh of its own for a row attached from another host.
    func forwardLoopback(_ page: ForwardedPage, row: UUID, done: @escaping @MainActor (URL?) -> Void) {
        guard let store = library.store(forSession: row), let host = store.session(withID: row)?.remoteHost else { return done(nil) }
        let pool = catalogPool(forSession: row)
        let key = LinkForwards.Key(window: pool == nil ? nil : library.windowID(for: store), sshHost: host, host: page.host,
                                   port: page.port)
        let runner = remoteRunner
        let launcher = forwardLauncher
        linkForwards.open(page, row: row, key: key, done: done) { port, onEvent in
            let spec = page.spec(localPort: port)
            if let pool {
                return PooledForward(pool: pool, user: "link:\(page.host):\(page.port)", spec: spec,
                                     runner: { await runner.run($0, deadline: 15) }, onEvent: onEvent)
            }
            guard let argv = try? RemoteSession.forwardCommand(host: host, spec: spec) else { return nil }
            return RemotePortForward(argv: argv, host: page.host, port: port, launcher: launcher, onEvent: onEvent)
        }
    }
}
