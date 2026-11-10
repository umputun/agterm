import Foundation

/// PortForwardEvent is what a page's port forward reports: its listener answers, or it ended and the page cannot
/// load through it.
public enum PortForwardEvent: Equatable, Sendable {
    case ready
    case failed(String)
}

/// PooledForward is one page's port forward on a remote window's pooled master. The master owns the listener, so
/// the forward is added and cancelled through its control socket, and the master's pid tells whether the master
/// holding it is still the one running: a replacement another pool user started has no such listener.
@MainActor
public final class PooledForward {
    public typealias Runner = @MainActor ([String]) async -> RemoteCommandResult

    private let pool: SshConnectionPool
    private let user: String
    private let spec: String
    private let runner: Runner
    private let interval: Duration
    private let onEvent: @MainActor (PortForwardEvent) -> Void
    private var path: String?
    private var connectionPID: Int32?
    private var added = false
    private var stopped = false
    // every add, re-add and cancel runs after the one before it, so a cancel always follows an add still in flight
    private var chain: Task<Void, Never>?
    private var monitor: Task<Void, Never>?

    /// `user` is the pool lease the forward holds until its cancel has run; `interval` paces the master check.
    public init(pool: SshConnectionPool, user: String, spec: String, interval: Duration = .seconds(5),
                runner: @escaping Runner, onEvent: @escaping @MainActor (PortForwardEvent) -> Void) {
        self.pool = pool
        self.user = user
        self.spec = spec
        self.interval = interval
        self.runner = runner
        self.onEvent = onEvent
    }

    public func start() {
        let path = pool.lease(user)
        self.path = path
        enqueue { [weak self] in
            guard let self, !stopped else { return }
            guard await install(path) else { return fail("the port forward through \(pool.host) failed") }
            guard !stopped else { return }
            onEvent(.ready)
            watch()
        }
    }

    /// stop cancels the forward once any add in flight has finished, then releases the lease. The cleanup holds the
    /// forward itself, so it runs after the page that owned the forward is gone.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        monitor?.cancel()
        enqueue { [self] in
            if added, let path, let cancel = try? RemoteSession.forwardControlCommand("cancel", host: pool.host,
                                                                                         controlPath: path, spec: spec) {
                _ = await runner(cancel)
            }
            added = false
            pool.release(user)
        }
    }

    private func watch() {
        monitor = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !stopped, !Task.isCancelled else { return }
                await enqueue { [weak self] in await self?.verify() }.value
            }
        }
    }

    private func verify() async {
        guard !stopped, let path else { return }
        if let current = await checkedPID(path), current == connectionPID { return }
        added = false
        guard await install(path) else {
            // a check that failed once while the master lived makes the add refuse the forward it already holds
            if let current = await checkedPID(path), current == connectionPID {
                added = true
                return
            }
            return fail("the connection to \(pool.host) carrying the port forward was lost")
        }
    }

    private func install(_ path: String) async -> Bool {
        guard await pool.ready(path), !stopped,
              let add = try? RemoteSession.forwardControlCommand("forward", host: pool.host, controlPath: path, spec: spec)
        else { return false }
        guard await runner(add).status == 0 else { return false }
        added = true
        guard !stopped else { return true }
        connectionPID = await checkedPID(path)
        return connectionPID != nil
    }

    private func checkedPID(_ path: String) async -> Int32? {
        guard let check = try? RemoteSession.forwardControlCommand("check", host: pool.host, controlPath: path) else { return nil }
        let result = await runner(check)
        guard result.status == 0 else { return nil }
        return RemoteSession.connectionPID(result.stdout + result.stderr)
    }

    /// fail reports `reason` and cleans up as a stop does, so a forward that ended keeps no listener or lease.
    private func fail(_ reason: String) {
        guard !stopped else { return }
        onEvent(.failed(reason))
        stop()
    }

    @discardableResult
    private func enqueue(_ step: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await step()
        }
        chain = task
        return task
    }
}
