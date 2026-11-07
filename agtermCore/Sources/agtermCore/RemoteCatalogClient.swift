import Foundation

/// RemoteCatalogClient connects one remote window to its server: it asks `version` first, so an origin that
/// cannot serve a catalog is refused with a message rather than retried, then carries the catalog stream into
/// the mirror, subscribing again on a gap and backing off after a lost link.
@MainActor
public final class RemoteCatalogClient {
    /// Runner runs one short ssh command and returns its exit status and output.
    public typealias Runner = @MainActor ([String]) async -> (status: Int32, stdout: String)
    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    static let retryDelays: [TimeInterval] = [1, 2, 5, 10, 30]
    /// silenceLimit is how long a link may stay quiet; the server pings every 10 seconds, so this much silence
    /// means it is gone without ssh noticing.
    static let silenceLimit: TimeInterval = 35

    public let mirror: RemoteCatalogMirror
    private let host: String
    private let transport: any RemotePresentationTransport
    private let runner: Runner
    private let sleep: Sleep
    private let now: () -> Date
    private let pool: SshConnectionPool?
    private var link: RemotePresentationLink?
    private var generation = 0
    private var attempt = 0
    private var stopped = false
    private var pending: Task<Void, Never>?
    private var probing = false
    private var watchdog: Task<Void, Never>?
    private var lastFrame = Date.distantPast

    public init(mirror: RemoteCatalogMirror, transport: any RemotePresentationTransport, runner: @escaping Runner,
                pool: SshConnectionPool? = nil,
                sleep: @escaping Sleep = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                now: @escaping () -> Date = Date.init) {
        self.pool = pool
        self.mirror = mirror
        host = mirror.host
        self.transport = transport
        self.runner = runner
        self.sleep = sleep
        self.now = now
    }

    public func start() {
        guard !stopped, !probing, pending == nil, link == nil else { return }
        pending = Task { @MainActor [weak self] in await self?.connect() }
    }

    /// stop ends the stream and every retry; the window keeps what it shows.
    public func stop() {
        stopped = true
        pending?.cancel()
        pending = nil
        watchdog?.cancel()
        watchdog = nil
        drop()
    }

    func connect() async {
        // the task running this is no longer waiting, so a retry it schedules below owns `pending`
        pending = nil
        guard !stopped, !probing else { return }
        probing = true
        defer { probing = false }
        // the stream's master comes up first, so the probe and everything the snapshot attaches share it; without
        // one the attempt fails here rather than connect on its own
        let probe = pool?.leaseOnce()
        defer { probe.map { pool?.release($0.user) } }
        if let pool, let probe {
            var ready = await pool.ready(pool.lease("catalog"))
            if ready { ready = await pool.ready(probe.path) }
            guard !stopped else { return }
            guard ready else {
                lost("\(host) did not answer")
                return
            }
        }
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["version"], controlPath: probe?.path) else {
            mirror.checkVersions(nil, app: nil)
            return
        }
        let result = await runner(argv)
        guard !stopped else { return }
        guard result.status == 0, let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)),
              response.ok else {
            lost("\(host) did not answer")
            return
        }
        guard mirror.checkVersions(response.result?.versions, app: response.result?.app) else { return }
        open()
    }

    private func open() {
        guard !stopped, let argv = try? RemoteSession.catalogCommand(host: host, controlPath: pool?.lease("catalog")) else { return }
        mirror.subscribing()
        generation += 1
        let current = generation
        lastFrame = now()
        link = transport.open(argv, onLine: { [weak self] line in self?.receive(line, generation: current) },
                              onClose: { [weak self] reason in self?.closed(reason, generation: current) })
        send(.hello(CatalogHello(version: CatalogCodec.version)))
        startWatchdog()
    }

    private func receive(_ line: Data, generation current: Int) {
        guard current == generation, !stopped else { return }
        lastFrame = now()
        guard let frame = try? CatalogCodec.decode(line) else {
            resubscribe()
            return
        }
        if let reply = mirror.receive(frame) { send(reply) }
        switch mirror.state {
        case .connected: attempt = 0
        case .refused:
            drop()
            return
        default: break
        }
        if mirror.needsSnapshot { resubscribe() }
    }

    /// closed settles the link it names; one this client already replaced is ignored.
    private func closed(_ reason: String, generation current: Int) {
        guard current == generation, !stopped else { return }
        link = nil
        lost("the catalog stream from \(host) ended: \(reason)")
    }

    private func lost(_ reason: String) {
        if case .refused = mirror.state { return }
        mirror.connectionLost(reason)
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        attempt += 1
        pending = Task { @MainActor [weak self] in
            await self?.sleep(delay)
            guard let self, !Task.isCancelled, !self.stopped else { return }
            await self.connect()
        }
    }

    private func resubscribe() {
        drop()
        open()
    }

    private func drop() {
        generation += 1
        let old = link
        link = nil
        old?.stop()
    }

    private func send(_ frame: CatalogFrame) {
        guard let line = try? CatalogCodec.encode(frame) else { return }
        link?.send(line)
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.silenceLimit / 3 * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.stopped else { return }
                guard self.link != nil, self.now().timeIntervalSince(self.lastFrame) > Self.silenceLimit else { continue }
                self.drop()
                self.lost("no word from \(self.host) for \(Int(Self.silenceLimit)) seconds")
            }
        }
    }
}
