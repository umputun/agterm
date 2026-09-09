import AgtermResponsibility
import Darwin
import Foundation
import Testing
import agtermCore
@testable import SessionHostRuntime

/// The repository's staged zmx, built by `scripts/setup.sh`. It is an ignored build artifact, so a
/// checkout that has not run setup has no daemon for the fixtures below to attach to.
private let stagedZmxPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("agterm/Resources/zmx/zmx").path

private let sessionHostFixtureReady = Responsibility.system.isAvailable
    && FileManager.default.isExecutableFile(atPath: stagedZmxPath)

struct SessionHostServerTests {
    @Test func existingDaemonDoesNotSpawnOrReplay() throws {
        let context = try Context()
        context.backend.records = [[context.record]]
        #expect(context.host.handle(ensure: context.request) == .ok(.init(state: .existing, leaderPid: 600)))
        #expect(context.backend.spawns == 0)
        #expect(context.backend.child.terminations == 0)
    }

    @Test func leaderOnSecondPollCreatesOnceAndReleasesOnlyTheClient() throws {
        let context = try Context()
        context.backend.records = [[], [], [context.record]]
        #expect(context.host.handle(ensure: context.request) == .ok(.init(state: .created, leaderPid: 600)))
        #expect(context.backend.spawns == 1)
        #expect(context.backend.listCalls == 3)
        #expect(context.backend.child.terminatedPIDs == [500])
    }

    @Test func readinessTimeoutIsStartedAndNeverRetries() throws {
        let context = try Context()
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected timeout"); return }
        #expect(error.stage == .started)
        #expect(context.backend.spawns == 1)
        #expect(context.backend.child.terminatedPIDs == [500])
        #expect(context.clock.time >= 0.3)
    }

    @Test func earlyClientExitIsStartedAndReaped() throws {
        let context = try Context()
        context.backend.child.state = .exited
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected early exit"); return }
        #expect(error.stage == .started)
        #expect(context.backend.spawns == 1)
        #expect(context.backend.child.terminations == 1)
    }

    @Test func unreadableInitialInventoryCannotCreateAnything() throws {
        let context = try Context()
        context.backend.failListing = true
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected inspection failure"); return }
        #expect(error.stage == .before)
        #expect(context.backend.spawns == 0)
    }

    @Test func exhaustedInspectionBudgetDoesNotStartAClient() throws {
        let context = try Context()
        let clock = context.clock
        context.backend.onList = { clock.time = 1 }
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected deadline"); return }
        #expect(error.stage == .before)
        #expect(context.backend.spawns == 0)
    }

    @Test func wrongExecutableOrNamespaceIsRejectedBeforeSpawn() throws {
        let context = try Context()
        let requests = [
            SessionHost.Ensure(name: context.name, argv: [], cwd: "/tmp", env: context.request.env, rows: 24, cols: 80),
            .init(name: context.name, argv: ["/bin/sh", "attach", context.name], cwd: "/tmp", env: context.request.env, rows: 24, cols: 80),
            .init(name: context.name, argv: context.request.argv, cwd: "", env: context.request.env, rows: 24, cols: 80),
            .init(name: context.name, argv: context.request.argv, cwd: "/tmp", env: ["ZMX_DIR": "/other"], rows: 24, cols: 80),
        ]
        for request in requests {
            guard case .error(let error) = context.host.handle(ensure: request) else { Issue.record("expected rejection"); continue }
            #expect(error.stage == .before)
        }
        #expect(context.backend.spawns == 0)
    }

    @Test func relativeExecutableCannotPassCanonicalPathValidation() throws {
        let context = try Context()
        context.backend.records = [[context.record]]
        let depth = FileManager.default.currentDirectoryPath.split(separator: "/").count
        let relative = String(repeating: "../", count: depth) + "Applications/agterm.app/Contents/MacOS/zmx"
        let request = SessionHost.Ensure(name: context.name, argv: [relative, "attach", context.name], cwd: "/tmp",
                                        env: context.request.env, rows: 24, cols: 80)
        guard case .error(let error) = context.host.handle(ensure: request) else { Issue.record("relative executable accepted"); return }
        #expect(error.stage == .before)
        #expect(context.backend.spawns == 0)
    }

    @Test func stopRefusesLiveRootedAndUnknownInventory() throws {
        let context = try Context()
        context.backend.records = [[context.record]]
        #expect(context.host.handleStop() != .stopped)
        #expect(!context.host.shouldStop)
        context.backend.failListing = true
        #expect(context.host.handleStop() != .stopped)
        #expect(!context.host.shouldStop)
        context.backend.failListing = false
        context.backend.root = nil
        #expect(context.host.handleStop() != .stopped)
        #expect(!context.host.shouldStop)
        context.backend.records = [[.init(name: context.name, clients: nil, leaderPID: nil)]]
        #expect(context.host.handleStop() != .stopped)
    }

    @Test func stopAllowsEmptyOrPositivelyUnrelatedInventory() throws {
        let empty = try Context()
        #expect(empty.host.handleStop() == .stopped)
        #expect(empty.host.shouldStop)
        let orphaned = try Context()
        orphaned.backend.records = [[orphaned.record]]
        orphaned.backend.root = 600
        #expect(orphaned.host.handleStop() == .stopped)
        #expect(orphaned.host.shouldStop)
    }

    @Test func stopChecksTheDaemonEvenWhenItsLeaderHasAnotherRoot() throws {
        let context = try Context()
        context.backend.records = [[context.record]]
        context.backend.root = 600
        context.backend.roots[700] = getpid()
        #expect(context.host.handleStop() != .stopped)
        #expect(!context.host.shouldStop)
    }

    @Test func clientIgnoringTermIsKilledAndReapedAfterTheGracePeriod() throws {
        let process = try PTYProcess.spawn(argv: ["/bin/sh", "-c", "trap '' TERM; printf ready; exec /bin/sleep 30"],
                                           env: [:], cwd: "/tmp", rows: 24, cols: 80)
        let child = NativeHostChild(process)
        defer { try? child.terminate(grace: 0.01) }
        var ready = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ready.count < 5 {
            try hostWait(process.ptyFD, events: Int16(POLLIN), deadline: deadline)
            var byte: UInt8 = 0
            if read(process.ptyFD, &byte, 1) == 1 { ready.append(byte) }
        }
        #expect(String(decoding: ready, as: UTF8.self) == "ready")
        let start = ProcessInfo.processInfo.systemUptime
        try child.terminate(grace: 0.02)
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.02)
        #expect(child.hasExited)
    }

    @Test func fastSideEffectingClientIsNotRunAgain() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("count")
        let context = try Context(realClock: true)
        context.backend.spawnOverride = { _ in
            let process = try PTYProcess.spawn(argv: ["/bin/sh", "-c", "printf x >> \"$1\"", "probe", marker.path],
                                              env: [:], cwd: directory.path, rows: 24, cols: 80)
            return NativeHostChild(process)
        }
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected exited client"); return }
        #expect(error.stage == .started)
        #expect(context.backend.spawns == 1)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
    }

    @Test func startupErrorAfterASideEffectDoesNotAuthorizeReplay() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let context = try Context()
        context.backend.spawnOverride = { _ in
            try Data("x".utf8).write(to: marker)
            throw POSIXError(.EIO)
        }
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected uncertain startup"); return }
        #expect(error.stage == .started)
        #expect(context.backend.spawns == 1)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
    }

    @Test func lostReplyAfterFastCommandDoesNotRunItsPayloadAgain() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("count")
        let context = try Context(realClock: true)
        let command = ["/bin/sh", "-c", "printf x >> \"$1\"", "probe", marker.path]
        context.backend.spawnOverride = { _ in
            NativeHostChild(try PTYProcess.spawn(argv: command, env: [:], cwd: directory.path, rows: 24, cols: 80))
        }
        let request = SessionHost.Ensure(name: context.name, argv: context.request.argv + command, cwd: context.request.cwd,
                                        env: context.request.env, rows: 24, cols: 80)
        let peer = LostReplyPeer(host: context.host)
        var events: [String] = []
        let client = Client(connect: { peer }, diagnostic: { events.append($0) }, execute: { argv, _ in
            events.append("attach")
            #expect(argv == context.request.argv)
            if argv.count > 3 {
                let duplicate = NativeHostChild(try PTYProcess.spawn(argv: Array(argv.dropFirst(3)), env: [:], cwd: directory.path, rows: 24, cols: 80))
                defer { try? duplicate.terminate(grace: 0.1) }
                while duplicate.poll() == .running { Thread.sleep(forTimeInterval: 0.01) }
            }
        })
        try client.run(request: request)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "x")
        #expect(context.backend.spawns == 1)
        #expect(events == [SessionHost.ClientOutcome.uncertain.diagnostic!, "attach"])
    }

    private final class LostReplyPeer: ClientPeer {
        let host: SessionHostRuntime.Host
        init(host: SessionHostRuntime.Host) { self.host = host }
        func send(_ frame: Data, deadline: TimeInterval) throws {
            guard case .ensure(let request) = try SessionHost.decodeFrame(SessionHost.Request.self, from: frame) else { throw HostFailure.invalidRequest }
            _ = host.handle(ensure: request)
        }
        func receive(deadline: TimeInterval) throws -> SessionHost.Response { throw HostFailure.disconnected }
        func close() {}
    }

    @Test func descriptorPreparationFailureRetainsTheChildForCleanup() throws {
        let process = try PTYProcess.spawn(argv: ["/bin/sleep", "30"], env: [:], cwd: "/tmp", rows: 24, cols: 80)
        defer { close(process.ptyFD) }
        let child = NativeHostChild(.init(pid: process.pid, ptyFD: -1, execErrorFD: process.execErrorFD))
        defer { try? child.terminate(grace: 0.01) }
        #expect(child.poll() == .failed)
        try child.terminate(grace: 0.01)
        #expect(child.hasExited)
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func hostSocketIsNotEnumeratedByStockZmx() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        #expect(try fixture.list().isEmpty)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func malformedOversizedAndPartialConnectionsDoNotStopTheHost() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        #expect(try fixture.raw(Data("not-json\n".utf8)).isEmpty)
        #expect(try fixture.raw(Data(repeating: 0x61, count: SessionHost.maximumFrameBytes + 1)).isEmpty)
        let connection = try fixture.connect()
        let partial = Array("{\"hello\":".utf8)
        _ = partial.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        close(connection)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func stalledPeerHitsItsDeadlineAndOnlyThatConnectionCloses() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        let start = ProcessInfo.processInfo.systemUptime
        #expect(try fixture.raw(Data(), stall: true).isEmpty)
        #expect(ProcessInfo.processInfo.systemUptime - start < 5)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func forgedHelloDoesNotOverrideTheActualPeerImage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        var data = try SessionHost.encodeFrame(SessionHost.Request.hello(fixture.identity))
        data.append(try SessionHost.encodeFrame(SessionHost.Request.stop))
        #expect(try fixture.raw(data, command: URL(fileURLWithPath: "/usr/bin/nc")).isEmpty)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func stopKeepsLockInodesForTheNextHost() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        let ownerFD = open(fixture.paths.ownerLock, O_RDWR | O_CLOEXEC)
        try #require(ownerFD >= 0)
        defer { close(ownerFD) }
        #expect(flock(ownerFD, LOCK_EX | LOCK_NB) == -1)
        let inode = try #require(FileManager.default.attributesOfItem(atPath: fixture.paths.ownerLock)[.systemFileNumber] as? NSNumber)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socket))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.pidfile))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.spawnLock))
        #expect(flock(ownerFD, LOCK_EX | LOCK_NB) == 0)
        _ = flock(ownerFD, LOCK_UN)
        try fixture.start()
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.paths.ownerLock)[.systemFileNumber] as? NSNumber == inode)
        #expect(flock(ownerFD, LOCK_EX | LOCK_NB) == -1)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func killedHostReleasesLockAndListenerWhileDaemonAndShellSurvive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.start()
        let name = ZmxSupport.daemonName(for: UUID())
        fixture.names.append(name)
        let request = SessionHost.Ensure(name: name, argv: [fixture.zmx.path, "attach", name], cwd: fixture.directory.path,
                                        env: fixture.environment, rows: 24, cols: 80)
        guard case .ok(let ready) = try fixture.exchange(.ensure(request)).last else { Issue.record("daemon was not created"); return }
        let shell = ready.leaderPid
        let daemon = try parentPID(shell)
        #expect(Responsibility.system.responsibleProcess(of: shell) == first)
        #expect(Responsibility.system.responsibleProcess(of: daemon) == first)
        #expect(try fixture.exchange(.stop).last != .stopped)
        fixture.killHost()
        #expect(kill(daemon, 0) == 0)
        #expect(kill(shell, 0) == 0)
        do {
            let leaked = try fixture.connect()
            close(leaked)
            Issue.record("listener survived host death")
        } catch let error as POSIXError {
            #expect(error.code == .ECONNREFUSED)
        }
        let second = try fixture.start()
        #expect(second != first)
        #expect(Responsibility.system.responsibleProcess(of: shell) == shell)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    private final class Clock {
        var time: TimeInterval = 0
    }

    private final class Child: HostChild {
        let pid: Int32 = 500
        var state: HostChildState = .running
        var hasExited = false
        var terminations = 0
        var terminatedPIDs: [Int32] = []
        func poll() -> HostChildState { state }
        func terminate(grace: TimeInterval) throws {
            terminations += 1
            terminatedPIDs.append(pid)
            hasExited = true
        }
    }

    private final class Backend: HostBackend {
        let child = Child()
        var records: [[ZmxSessionRecord]] = [[]]
        var failListing = false
        var listCalls = 0
        var spawns = 0
        var root: Int32? = getpid()
        var roots: [Int32: Int32] = [:]
        var onList: (() -> Void)?
        var spawnOverride: ((SessionHost.Ensure) throws -> any HostChild)?
        func list(deadline: TimeInterval) throws -> [ZmxSessionRecord] {
            listCalls += 1
            onList?()
            if failListing { throw POSIXError(.EIO) }
            return records.count > 1 ? records.removeFirst() : records[0]
        }
        func spawn(_ request: SessionHost.Ensure) throws -> any HostChild {
            spawns += 1
            return try spawnOverride?(request) ?? child
        }
        func responsibleProcess(of pid: Int32) -> Int32? { roots[pid] ?? root }
        func daemonPID(for leader: Int32) -> Int32? { 700 }
        func isAlive(_ pid: Int32) -> Bool { true }
    }

    private final class Context {
        let clock = Clock()
        let backend = Backend()
        let host: SessionHostRuntime.Host
        let name = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let request: SessionHost.Ensure
        var record: ZmxSessionRecord { .init(name: name, clients: 0, leaderPID: 600) }

        init(realClock: Bool = false) throws {
            request = .init(name: name, argv: ["/Applications/agterm.app/Contents/MacOS/zmx", "attach", name],
                            cwd: "/tmp", env: ["ZMX_DIR": "/tmp/host-unit"], rows: 24, cols: 80)
            let clock = clock
            let config = SessionHostRuntime.Host.Configuration(socketDirectory: "/tmp/host-unit",
                                            identity: .init(bundleID: "com.umputun.agterm", bundlePath: "/Applications/agterm.app", pid: getpid()),
                                            zmxPath: request.argv[0], ensureTimeout: 0.3, pollInterval: 0.1, terminationGrace: 0.05)
            host = try SessionHostRuntime.Host(configuration: config, backend: backend,
                            now: realClock ? { ProcessInfo.processInfo.systemUptime } : { clock.time },
                            pause: realClock ? { Thread.sleep(forTimeInterval: $0) } : { clock.time += $0 })
        }
    }

    private func parentPID(_ pid: Int32) throws -> Int32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try #require(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size)
        return Int32(info.pbi_ppid)
    }

    private func temporaryDirectory() throws -> URL {
        let path = URL(fileURLWithPath: "/tmp/shs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private final class Fixture {
        let directory: URL
        let bundle: URL
        let executable: URL
        let zmx: URL
        let client: URL
        let paths: SessionHost.Paths
        let environment: [String: String]
        let identity: SessionHost.Hello
        var pid: Int32?
        var names: [String] = []

        init() throws {
            directory = URL(fileURLWithPath: "/tmp/shs-\(UUID().uuidString)", isDirectory: true)
            bundle = directory.appendingPathComponent("Test.app")
            executable = bundle.appendingPathComponent("Contents/MacOS/agterm-session-host")
            zmx = bundle.appendingPathComponent("Contents/MacOS/zmx")
            client = bundle.appendingPathComponent("Contents/MacOS/test-client")
            let socketDirectory = directory.appendingPathComponent("zmx").path
            paths = try SessionHost.paths(socketDirectory: socketDirectory)
            identity = .init(bundleID: "com.umputun.hosttest.\(UUID().uuidString)", bundlePath: bundle.path)
            environment = ["ZMX_DIR": socketDirectory, "ZMX_SESSION": "", "ZMX_SESSION_PREFIX": "", "ZMX_NO_DETACH_KEY": "1",
                           "SHELL": "/bin/sh", "HOME": directory.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.copyItem(at: package.appendingPathComponent(".build/debug/agterm-session-host"), to: executable)
            try FileManager.default.copyItem(atPath: stagedZmxPath, toPath: zmx.path)
            try FileManager.default.copyItem(atPath: "/usr/bin/nc", toPath: client.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
            _ = try run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", client.path])
            let info = ["CFBundleIdentifier": identity.bundleID, "CFBundleExecutable": "agterm-session-host", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: paths.spawnLock).deletingLastPathComponent(), withIntermediateDirectories: true)
            let lock = open(paths.spawnLock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            if lock >= 0 { close(lock) }
        }

        @discardableResult func start() throws -> Int32 {
            let child = try Responsibility.system.spawnDisclaimed(executable: executable.path,
                                                                  argv: [executable.path, "host", environment["ZMX_DIR"]!], env: environment)
            pid = child
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if (try? String(contentsOfFile: paths.pidfile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == String(child) {
                    return child
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw POSIXError(.ETIMEDOUT)
        }

        func list() throws -> [ZmxSessionRecord] {
            let data = try run(zmx, arguments: ["list"])
            return try ZmxListParser.parse(String(decoding: data, as: UTF8.self))
        }

        func exchange(_ request: SessionHost.Request) throws -> [SessionHost.Response] {
            var data = try SessionHost.encodeFrame(SessionHost.Request.hello(identity))
            data.append(try SessionHost.encodeFrame(request))
            let replies = try raw(data)
            if replies.count != 2 {
                print("host fixture replies: \(replies); log: \((try? String(contentsOfFile: paths.log, encoding: .utf8)) ?? "none")")
            }
            return replies
        }

        func raw(_ data: Data, stall: Bool = false, command: URL? = nil) throws -> [SessionHost.Response] {
            let input = directory.appendingPathComponent("request")
            try data.write(to: input)
            let output = try run(command ?? client, arguments: ["-U", paths.socket], input: input, stall: stall)
            return try output.split(separator: 0x0A).map { line in
                var frame = Data(line)
                frame.append(0x0A)
                return try SessionHost.decodeFrame(SessionHost.Response.self, from: frame)
            }
        }

        func connect() throws -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = paths.socket.utf8CString
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in bytes.withUnsafeBytes { buffer.copyMemory(from: $0) } }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { let code = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            return fd
        }

        func waitForExit() throws {
            guard let pid else { return }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid { self.pid = nil; #expect(status == 0); return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw POSIXError(.ETIMEDOUT)
        }

        func killHost() {
            guard let pid else { return }
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            self.pid = nil
        }

        func cleanup() {
            for name in names { _ = try? run(zmx, arguments: ["kill", name, "--force"]) }
            killHost()
            try? FileManager.default.removeItem(at: directory)
        }

        private func run(_ command: URL, arguments: [String], input: URL? = nil, stall: Bool = false) throws -> Data {
            let process = Process()
            process.executableURL = command
            process.arguments = arguments
            process.environment = environment
            let output = Pipe()
            let errors = Pipe()
            let heldInput = Pipe()
            let inputFile = try input.map { try FileHandle(forReadingFrom: $0) }
            defer { try? inputFile?.close() }
            process.standardInput = stall ? heldInput : inputFile ?? FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw POSIXError(.ETIMEDOUT)
            }
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus != 0 {
                print("fixture command \(command.lastPathComponent) status \(process.terminationStatus), reason \(process.terminationReason): \(String(decoding: stderr, as: UTF8.self))")
            }
            return output.fileHandleForReading.readDataToEndOfFile()
        }
    }
}
