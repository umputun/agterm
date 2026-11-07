import Foundation

/// SshConnectionPool spreads one remote window's ssh session channels over ControlMaster connections, at most
/// `channelsPerConnection` per master, under stock sshd's `MaxSessions 10`. Every channel holds a lease for its
/// lifetime, and a slot's master is started once, before its users launch, so a reconnect costs one handshake
/// per master rather than one per channel.
@MainActor
public final class SshConnectionPool {
    /// Runner runs one local command and returns its exit status.
    public typealias Runner = @MainActor ([String]) async -> Int32

    public static let channelsPerConnection = 8
    public let host: String
    private let prefix: String
    private let runner: Runner
    private var slots: [Slot] = []
    private var closed = false

    private final class Slot {
        let path: String
        var users: Set<String> = []
        var preparing: Task<Bool, Never>?
        init(path: String) { self.path = path }
    }

    /// `key` names the pool's owner, so two windows or two state directories never share a master.
    public init(host: String, root: String, key: String, runner: @escaping Runner) {
        self.host = host
        prefix = root + "/" + Self.hash(key)
        self.runner = runner
    }

    /// lease returns the control path `user` rides: the slot it already holds, else the first with room, else a
    /// new one. Every lease also makes sure that master is up, since a user libghostty launches cannot await it,
    /// and a reattach re-leases the slot whose master may have died.
    @discardableResult
    public func lease(_ user: String) -> String {
        let slot = slots.first { $0.users.contains(user) }
            ?? slots.first { $0.users.count < Self.channelsPerConnection } ?? addSlot()
        slot.users.insert(user)
        if !closed { Task { [weak self] in await self?.ready(slot.path) } }
        return slot.path
    }

    /// leaseOnce leases a channel for one command; the caller releases the returned user when it exits.
    public func leaseOnce() -> (user: String, path: String) {
        let user = "once:" + UUID().uuidString
        return (user, lease(user))
    }

    public func release(_ user: String) {
        for slot in slots { slot.users.remove(user) }
    }

    /// retain keeps the users starting with `prefix` that are in `users` and releases the rest of that kind.
    public func retain(_ users: Set<String>, prefix kind: String) {
        for slot in slots { slot.users = slot.users.filter { !$0.hasPrefix(kind) || users.contains($0) } }
    }

    /// ready waits until `path`'s master answers, starting it when it does not; callers arriving meanwhile share
    /// that one start. False when there is no master, and the caller then fails its attempt rather than connect.
    @discardableResult
    public func ready(_ path: String) async -> Bool {
        guard !closed, RemoteSession.isHost(host), let slot = slots.first(where: { $0.path == path }) else { return false }
        if let preparing = slot.preparing { return await preparing.value }
        let task = Task { @MainActor [weak self, runner, host] in
            if await runner(Self.checkCommand(host: host, path: path)) == 0 { return self?.closed == false }
            guard self?.closed == false else { return false }
            let started = await runner(Self.startCommand(host: host, path: path)) == 0
            guard self?.closed == false else {
                // the pool closed while this master was starting; its exit command already ran and missed it
                if started { _ = await runner(Self.exitCommand(host: host, path: path)) }
                return false
            }
            return started
        }
        slot.preparing = task
        let started = await task.value
        if slot.preparing == task { slot.preparing = nil }
        return started
    }

    /// close drops every lease and returns the commands that end the pool's masters.
    public func close() -> [[String]] {
        closed = true
        let commands = slots.map { Self.exitCommand(host: host, path: $0.path) }
        slots.removeAll()
        return commands
    }

    /// load is each slot's lease count, in slot order.
    public var load: [Int] { slots.map(\.users.count) }

    static func checkCommand(host: String, path: String) -> [String] {
        ["ssh", "-O", "check", "-o", "ControlPath=" + path, host]
    }

    static func exitCommand(host: String, path: String) -> [String] {
        ["ssh", "-O", "exit", "-o", "ControlPath=" + path, host]
    }

    /// startCommand starts a background master; its stdio goes nowhere, or the master would keep the runner's
    /// pipes open for as long as it lives. It runs only after a failed check, so a socket at `path` is a dead
    /// master's: left there, ssh -M finds the path taken and connects without multiplexing.
    static func startCommand(host: String, path: String) -> [String] {
        let ssh = CommandRestore.shellQuotedLine([
            "ssh", "-f", "-N", "-M", "-E", path + ".log", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "ControlPersist=60", "-o", "ControlPath=" + path, host,
        ])
        return ["/bin/sh", "-c", "rm -f " + CommandRestore.shellQuotedLine([path]) + "; exec " + ssh + " </dev/null >/dev/null 2>&1"]
    }

    private func addSlot() -> Slot {
        let slot = Slot(path: "\(prefix)-\(slots.count)")
        slots.append(slot)
        return slot
    }

    /// hash is FNV-1a: stable across runs and platforms, which `Hasher` is not, and short enough for a socket path.
    static func hash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

/// PooledTransport opens each link once its master answers, so a stream that reconnects on its own schedule never
/// races its pool for the master. A master that cannot be started closes the link unopened, and the stream's own
/// retry asks again.
@MainActor
public final class PooledTransport: RemotePresentationTransport {
    private let pool: SshConnectionPool
    private let path: String
    private let inner: any RemotePresentationTransport

    public init(pool: SshConnectionPool, path: String, inner: any RemotePresentationTransport) {
        self.pool = pool
        self.path = path
        self.inner = inner
    }

    public func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                     onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
        let link = DeferredLink()
        Task { @MainActor [pool, path, inner] in
            guard await pool.ready(path) else {
                link.fail { onClose("no connection to \(pool.host)") }
                return
            }
            link.attach { inner.open(argv, onLine: onLine, onClose: onClose) }
        }
        return link
    }
}

/// DeferredLink stands in for a link until it opens, keeping what was sent meanwhile; one stopped first never opens.
@MainActor
final class DeferredLink {
    private var inner: RemotePresentationLink?
    private var pending: [Data] = []
    private var stopped = false

    func attach(_ open: () -> RemotePresentationLink) {
        guard !stopped else { return }
        let link = open()
        inner = link
        for line in pending { link.send(line) }
        pending.removeAll()
    }

    func fail(_ close: () -> Void) {
        guard !stopped else { return }
        stopped = true
        pending.removeAll()
        close()
    }
}

extension DeferredLink: @MainActor RemotePresentationLink {
    func send(_ line: Data) {
        guard let inner else { return pending.append(line) }
        inner.send(line)
    }

    func stop() {
        stopped = true
        pending.removeAll()
        inner?.stop()
    }
}
