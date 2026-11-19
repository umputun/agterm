import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

struct ServerScratch {
    let root: String
    var state: String { root + "/state" }
    var runtime: String { root + "/run" }
    var bin: String { root + "/bin" }
    var zmx: String { bin + "/zmx" }

    init() throws {
        root = "/tmp/agts-\(UUID().uuidString.prefix(8))"
        for directory in [root, runtime, bin] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        // a link, not a script: writeExecutable's subprocess would block the main actor in every @MainActor suite's setup
        try FileManager.default.createSymbolicLink(atPath: zmx, withDestinationPath: "/usr/bin/true")
    }

    var environment: [String: String] { ["XDG_RUNTIME_DIR": runtime, "HOME": root] }

    func configuration() throws -> ServerConfiguration {
        try ServerConfiguration.resolve(stateDirectory: state, catalogName: "testbox", loginShell: "/bin/zsh",
                                        environment: environment, executableDirectory: bin)
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

// a blocking socket read on the shared pool starves the server's own handler tasks, and Linux sizes that pool by CPUs
func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in Thread { continuation.resume(returning: body()) }.start() }
}

// a socket the server already closed raises SIGPIPE on a plain write, which ends the whole test process
func sendNoSignal(_ fd: Int32, _ data: Data) throws {
    let sent = data.withUnsafeBytes { buffer in
        #if canImport(Darwin)
        var on: Int32 = 1
        // the option cannot be set once the peer has shut down (EINVAL), and a send then raises SIGPIPE
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return -1 }
        return send(fd, buffer.baseAddress, data.count, 0)
        #else
        return send(fd, buffer.baseAddress, data.count, Int32(MSG_NOSIGNAL))
        #endif
    }
    guard sent == data.count else { throw UnixSocket.Failure.system("send: \(String(cString: strerror(errno)))") }
}

func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in Thread { continuation.resume(with: Result { try body() }) }.start() }
}

// written from a child: a write descriptor held here leaks into another test's spawn, and Linux refuses the exec (ETXTBSY)
func writeExecutable(_ path: String, _ script: String) throws {
    let output = try ServerProcess.run(["/bin/sh", "-c", "cat >\"$0\" && chmod 755 \"$0\"", path], environment: [:],
                                       input: Data(script.utf8), timeout: 10)
    guard output.status == 0 else { throw ServerProcess.Failure.launch("write \(path): \(output.stderr)") }
}

func send(_ request: ControlRequest, to path: String) throws -> ControlResponse {
    guard let fd = UnixSocket.connected(path: path) else { throw UnixSocket.Failure.system("connect \(path)") }
    defer { close(fd) }
    var line = try JSONEncoder().encode(request)
    line.append(UInt8(ascii: "\n"))
    try sendNoSignal(fd, line)
    var reply = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n") { reply.append(byte) }
    return try JSONDecoder().decode(ControlResponse.self, from: reply)
}

final class FakeZmxRunner: ZmxRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLaunches: [PaneLaunch] = []
    private var storedKills: [String] = []
    private var storedTyped: [(name: String, bytes: [UInt8])] = []
    private var storedFailure: String?
    private var storedScreens: [String: String] = [:]
    private var storedHistories: [String: String] = [:]
    private var storedCursorColumns: [String: Int] = [:]
    private var storedRecords: [ZmxSessionRecord]? = []
    private var storedKillFails = false
    private var storedConfirmedKills: [(name: String, force: Bool)] = []
    private var storedKillOutcome = ZmxKillOutcome.killed
    private var storedOnCreate: (@Sendable (PaneLaunch) -> Void)?
    private var storedOnKill: (@Sendable (String) -> Void)?

    var launches: [PaneLaunch] { lock.withLock { storedLaunches } }
    var kills: [String] { lock.withLock { storedKills } }
    var typed: [(name: String, bytes: [UInt8])] { lock.withLock { storedTyped } }
    var failure: String? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }
    var screens: [String: String] {
        get { lock.withLock { storedScreens } }
        set { lock.withLock { storedScreens = newValue } }
    }
    var histories: [String: String] {
        get { lock.withLock { storedHistories } }
        set { lock.withLock { storedHistories = newValue } }
    }
    var cursorColumns: [String: Int] {
        get { lock.withLock { storedCursorColumns } }
        set { lock.withLock { storedCursorColumns = newValue } }
    }
    var killFails: Bool {
        get { lock.withLock { storedKillFails } }
        set { lock.withLock { storedKillFails = newValue } }
    }
    var records: [ZmxSessionRecord]? {
        get { lock.withLock { storedRecords } }
        set { lock.withLock { storedRecords = newValue } }
    }
    var confirmedKills: [(name: String, force: Bool)] { lock.withLock { storedConfirmedKills } }
    var killOutcome: ZmxKillOutcome {
        get { lock.withLock { storedKillOutcome } }
        set { lock.withLock { storedKillOutcome = newValue } }
    }
    var onCreate: (@Sendable (PaneLaunch) -> Void)? {
        get { lock.withLock { storedOnCreate } }
        set { lock.withLock { storedOnCreate = newValue } }
    }
    var onKill: (@Sendable (String) -> Void)? {
        get { lock.withLock { storedOnKill } }
        set { lock.withLock { storedOnKill = newValue } }
    }

    func create(_ launch: PaneLaunch) throws {
        if let failure { throw ZmxRunnerError.failed(failure) }
        lock.withLock { storedLaunches.append(launch) }
        onCreate?(launch)
    }

    func killConfirmed(_ name: String, force: Bool) -> ZmxKillOutcome {
        let outcome = lock.withLock {
            storedConfirmedKills.append((name, force))
            if storedKillOutcome == .killed { storedRecords = storedRecords?.filter { $0.name != name } }
            return storedKillOutcome
        }
        if outcome == .killed { onKill?(name) }
        return outcome
    }

    func kill(_ name: String) -> Bool {
        // as slow as a zmx kill, so a caller that does not wait for it reads no kill yet
        Thread.sleep(forTimeInterval: 0.05)
        return lock.withLock {
            storedKills.append(name)
            if !storedKillFails { storedRecords = storedRecords?.filter { $0.name != name } }
            return !storedKillFails
        }
    }

    func list() throws -> [ZmxSessionRecord] {
        guard let records else { throw ZmxRunnerError.failed("list failed") }
        return records
    }

    func screen(_ name: String, all: Bool) -> ZmxScreen? {
        screens[name].flatMap {
            ZmxScreen(output: "1 80 24 \(cursorColumns[name] ?? 0) 0 0\n" + (all ? histories[name] ?? "" : "") + $0)
        }
    }

    func type(_ name: String, bytes: [UInt8]) -> Bool {
        lock.withLock { storedTyped.append((name, bytes)) }
        return true
    }
}

final class FakeProcessTable: ProcessTable, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTable: [ProcessRecord]? = []
    private var storedSignals: [(signal: Int32, pids: [Int32])] = []
    private var storedEnds: Set<Int32> = [SIGHUP, SIGKILL]

    var table: [ProcessRecord]? {
        get { lock.withLock { storedTable } }
        set { lock.withLock { storedTable = newValue } }
    }
    var signals: [(signal: Int32, pids: [Int32])] { lock.withLock { storedSignals } }
    var ends: Set<Int32> {
        get { lock.withLock { storedEnds } }
        set { lock.withLock { storedEnds = newValue } }
    }

    func shell(_ shell: Int32, job: Int32? = nil) {
        var records = [ProcessRecord(pid: shell, started: 1, group: shell, foreground: job ?? shell)]
        if let job { records.append(ProcessRecord(pid: job, started: 2, group: job, foreground: job)) }
        table = (table ?? []) + records
    }

    func snapshot() -> [ProcessRecord]? { table }

    func signal(_ signal: Int32, pids: [Int32]) {
        lock.withLock {
            storedSignals.append((signal, pids))
            if storedEnds.contains(signal) { storedTable = storedTable?.filter { !pids.contains($0.pid) } }
        }
    }
}

@MainActor
final class ServerHarness {
    let scratch: ServerScratch
    let runner = FakeZmxRunner()
    let store: AppStore
    let catalog = CatalogRoot(id: UUID(), name: "testbox")
    let panes: ServerPanes
    let actions: ServerActions
    let events: ServerEvents
    let jobClock: Date
    let processes = FakeProcessTable()
    let observer: PaneObserver

    init(shell: String = "/bin/zsh", history: Bool = false) throws {
        scratch = try ServerScratch()
        var configuration = try scratch.configuration()
        configuration.loginShell = shell
        let panes = ServerPanes(configuration: configuration, runner: runner, shellPath: shell, catalogID: catalog.id,
                                programVersion: "1.2.3", environment: ["HOME": scratch.root, "PATH": "/usr/bin:/bin"])
        self.panes = panes
        let events = ServerEvents(window: catalog.id)
        self.events = events
        let recentClosed = history ? RecentClosedStore(directory: URL(fileURLWithPath: scratch.state)) : nil
        store = AppStore(persistence: PersistenceStore(directory: URL(fileURLWithPath: scratch.state)), recentClosedStore: recentClosed,
                         controlEventSink: { events.receive($0) }, paneFinalizer: { ids in
            MainActor.assumeIsolated { panes.end(ids) }
        }, headless: true, askRegistry: AskRegistry())
        CatalogRoot.seedWorkspace(in: store)
        // a launch window or page claim window on the real clock expires under a loaded run before the test claims it
        let jobClock = Date()
        self.jobClock = jobClock
        actions = ServerActions(store: store, catalog: catalog, identity: AppIdentity(version: "1.2.3"), panes: panes,
                                events: events, overlayJobs: OverlayJobs(now: { jobClock }))
        actions.streams.now = { jobClock }
        actions.streams.presentationHelloDeadline = 60
        actions.recentClosed = recentClosed
        actions.processes = processes
        actions.restartWaits = (program: .milliseconds(200), shell: .seconds(5), follow: .seconds(10), poll: .milliseconds(10))
        let runner = runner
        actions.daemonLeader = { target in runner.records?.last { $0.name == target.name }?.leaderPID }
        let observer = PaneObserver(store: store, panes: panes, cwd: { _ in nil })
        self.observer = observer
        actions.paneExited = { session, identity in observer.settleExited(session, identity: identity) }
    }

    deinit {
        scratch.remove()
    }

    func session(_ reply: ControlResponse) throws -> Session {
        let id = try #require(reply.result?.id.flatMap(UUID.init(uuidString:)))
        return try #require(store.session(withID: id))
    }
}
