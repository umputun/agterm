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

@Suite(.serialized) struct SessionHostServerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGTERM_REQUIRE_ZMX"] != nil))
    func requiredFixturePrerequisitesArePresent() {
        #expect(Responsibility.system.isAvailable, "AGTERM_REQUIRE_ZMX is set but the responsibility SPI is unavailable")
        #expect(FileManager.default.isExecutableFile(atPath: stagedZmxPath), "AGTERM_REQUIRE_ZMX is set but zmx is not staged at \(stagedZmxPath)")
    }

    @Test func existingDaemonDoesNotSpawnOrReplay() throws {
        let context = try Context()
        context.backend.records = [[context.record]]
        #expect(context.host.handle(ensure: context.request) == .ok(.init(state: .existing, leaderPid: 600)))
        #expect(context.backend.spawns == 0)
        #expect(context.backend.child.terminations == 0)
    }

    @Test func creationIsAHeldDetachedCreateOfThePayload() throws {
        let context = try Context()
        context.backend.child.exit(0)
        context.backend.records = [[], [context.record]]
        let request = SessionHost.Ensure(name: context.name, argv: context.request.argv + ["/bin/sh", "-c", "codex"],
                                         cwd: "/tmp", env: context.request.env.merging(["TERM": "xterm-256color"]) { $1 }, rows: 30, cols: 100)
        #expect(context.host.handle(ensure: request) == .ok(.init(state: .created, leaderPid: 600)))
        let spawned = try #require(context.backend.spawned.first)
        #expect(spawned.argv == [request.argv[0], "attach", "--detached", context.name, "/bin/sh", "-c", "codex"])
        #expect(spawned.env == request.env.merging(["ZMX_HOLD_UNTIL_ATTACH": "7"]) { $1 })
        #expect([spawned.cwd, "\(spawned.rows)x\(spawned.cols)"] == ["/tmp", "30x100"])
    }

    @Test func aPlainShellIsCreatedDetachedWithNoHoldEvenWhenItInheritedOne() throws {
        let context = try Context()
        context.backend.child.exit(0)
        context.backend.records = [[], [context.record]]
        let request = SessionHost.Ensure(name: context.name, argv: context.request.argv, cwd: "/tmp",
                                         env: context.request.env.merging(["ZMX_HOLD_UNTIL_ATTACH": "9"]) { $1 }, rows: 24, cols: 80)
        #expect(context.host.handle(ensure: request) == .ok(.init(state: .created, leaderPid: 600)))
        let spawned = try #require(context.backend.spawned.first)
        #expect(spawned.argv == [request.argv[0], "attach", "--detached", context.name])
        #expect(spawned.env["ZMX_HOLD_UNTIL_ATTACH"] == nil)
    }

    @Test func leaderAfterTheCreatorExitedCreatesOnceAndReleasesOnlyTheCreator() throws {
        let context = try Context()
        context.backend.child.exit(0)
        context.backend.records = [[], [.init(name: context.name, clients: nil, leaderPID: nil)], [context.record]]
        #expect(context.host.handle(ensure: context.request) == .ok(.init(state: .created, leaderPid: 600)))
        #expect(context.backend.spawns == 1)
        #expect(context.backend.listCalls == 3)
        #expect(context.backend.child.terminatedPIDs == [500])
    }

    // regression: a ~30 ms creator was rechecked only after a full listing interval, which delayed every new pane
    @Test func aCreatorIsAnsweredSoonAfterItExits() throws {
        let context = try Context()
        let clock = context.clock
        context.backend.child.onPoll = { child in if clock.time >= 0.03, child.state == .running { child.exit(0) } }
        context.backend.records = [[], [context.record]]
        #expect(context.host.handle(ensure: context.request) == .ok(.init(state: .created, leaderPid: 600)))
        #expect(context.clock.time < 0.05)
        #expect(context.backend.listCalls == 2)
    }

    @Test func aRunningCreatorIsNotReadyEvenWithALeaderRow() throws {
        let context = try Context()
        context.backend.records = [[], [context.record]]
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected timeout"); return }
        #expect(error.stage == .started)
        #expect(context.backend.listCalls == 1)
        #expect(context.backend.child.terminatedPIDs == [500])
        #expect(context.clock.time >= 0.3)
    }

    @Test func aCreatorThatExitedWithAnUnreadyDaemonTimesOutAsStarted() throws {
        let context = try Context()
        context.backend.child.exit(0)
        context.backend.records = [[], [.init(name: context.name, clients: nil, leaderPID: nil)]]
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected timeout"); return }
        #expect(error.stage == .started)
        #expect(context.backend.spawns == 1)
        #expect(context.backend.listCalls > 2)
        #expect(context.clock.time >= 0.3)
    }

    // regression: a daemon killed after its creator exited held the host, and every pane queued behind it, to the deadline
    @Test func aDaemonGoneAfterItsCreatorExitedFailsAtOnce() throws {
        let context = try Context()
        context.backend.child.exit(0)
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected failure"); return }
        #expect(error.stage == .started)
        #expect(context.backend.listCalls == 2)
        #expect(context.clock.time < 0.1)
        #expect(context.backend.child.terminations == 1)
    }

    @Test(arguments: [Int32(1 << 8), SIGKILL])
    func aCreatorThatDidNotExitZeroIsStartedAndReaped(status: Int32) throws {
        let context = try Context()
        context.backend.child.exit(status)
        context.backend.records = [[], [context.record]]
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected failure"); return }
        #expect(error.stage == .started)
        #expect(context.backend.spawns == 1)
        #expect(context.backend.listCalls == 1)
        #expect(context.backend.child.terminations == 1)
    }

    @Test func aFailedCreatorIsStarted() throws {
        let context = try Context()
        context.backend.child.state = .failed
        guard case .error(let error) = context.host.handle(ensure: context.request) else { Issue.record("expected failure"); return }
        #expect(error.stage == .started)
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
        defer { try? child.terminate(grace: 0.5) }
        var ready = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ready.count < 5 {
            try hostWait(process.ptyFD, events: Int16(POLLIN), deadline: deadline)
            var byte: UInt8 = 0
            if read(process.ptyFD, &byte, 1) == 1 { ready.append(byte) }
        }
        #expect(String(decoding: ready, as: UTF8.self) == "ready")
        let start = ProcessInfo.processInfo.systemUptime
        try child.terminate(grace: 0.2)
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.2)
        #expect(child.hasExited)
    }

    @Test func clientSpawnedWhileTermIsBlockedStillDiesOnTerm() throws {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTERM)
        sigaddset(&blocked, SIGHUP)
        var previous = sigset_t()
        #expect(pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0)
        let spawned = Result(catching: { try PTYProcess.spawn(argv: ["/bin/sh", "-c", "printf ready; exec /bin/sleep 30"],
                                                              env: [:], cwd: "/tmp", rows: 24, cols: 80) })
        pthread_sigmask(SIG_SETMASK, &previous, nil)
        let process = try spawned.get()
        let child = NativeHostChild(process)
        defer { try? child.terminate(grace: 0.5) }
        var ready = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ready.count < 5 {
            try hostWait(process.ptyFD, events: Int16(POLLIN), deadline: deadline)
            var byte: UInt8 = 0
            if read(process.ptyFD, &byte, 1) == 1 { ready.append(byte) }
        }
        let start = ProcessInfo.processInfo.systemUptime
        try child.terminate(grace: 2)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
        #expect(child.stopReason?.contains("exited with wait status \(SIGTERM)") == true, "\(child.stopReason ?? "running")")
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
            #expect(argv == context.request.argv + ["/bin/sh", "-c", "printf '%s\\n' 'agterm: session is gone'; exit 1"])
            if argv.count > 3 {
                let duplicate = NativeHostChild(try PTYProcess.spawn(argv: Array(argv.dropFirst(3)), env: [:], cwd: directory.path, rows: 24, cols: 80))
                defer { try? duplicate.terminate(grace: 0.1) }
                while duplicate.poll() == .running { Thread.sleep(forTimeInterval: 0.01) }
            }
        })
        try client.run(request: request, endsPane: true)
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
        defer { try? child.terminate(grace: 0.5) }
        #expect(child.poll() == .failed)
        #expect(child.stopReason?.hasPrefix("descriptor preparation failed") == true)
        try child.terminate(grace: 0.5)
        #expect(child.hasExited)
    }

    @Test func exitedChildReportsItsWaitStatus() throws {
        let process = try PTYProcess.spawn(argv: ["/bin/sh", "-c", "printf 'cannot connect'; exit 7"],
                                           env: [:], cwd: "/tmp", rows: 24, cols: 80)
        let child = NativeHostChild(process)
        defer { try? child.terminate(grace: 0.5) }
        #expect(child.stopReason == nil)
        #expect(child.exitStatus == nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while child.poll() == .running, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(child.poll() == .exited)
        #expect(child.exitStatus == 7 << 8)
        #expect(child.stopReason == "exited with wait status \(7 << 8); output: cannot connect")
    }

    @Test func childThatCannotExecReportsThePreExecErrno() throws {
        let process = try PTYProcess.spawn(argv: ["/nonexistent/agterm-probe"], env: [:], cwd: "/tmp", rows: 24, cols: 80)
        let child = NativeHostChild(process)
        defer { try? child.terminate(grace: 0.5) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while child.poll() == .running, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(child.stopReason?.contains("pre-exec errno \(ENOENT)") == true)
    }

    @Test func upkeepRefreshesHostFilesAtOnceThenOncePerInterval() throws {
        let files = try UpkeepFiles()
        defer { files.cleanup() }
        let inode = try files.inode(files.paths.ownerLock)
        let tracked = [files.paths.ownerLock, files.paths.pidfile, files.log]

        try files.age(tracked)
        files.host.maintain(files.endpoint, log: files.logDescriptor)
        for path in tracked { #expect(try files.isFresh(path), "\(path)") }
        #expect(try files.inode(files.paths.ownerLock) == inode)
        #expect(try String(contentsOfFile: files.paths.pidfile, encoding: .utf8) == "\(getpid())\n")

        try files.age(tracked)
        files.clock.time += 3599
        files.host.maintain(files.endpoint, log: files.logDescriptor)
        for path in tracked { #expect(try !files.isFresh(path), "\(path)") }

        files.clock.time += 1
        files.host.maintain(files.endpoint, log: files.logDescriptor)
        for path in tracked { #expect(try files.isFresh(path), "\(path)") }
    }

    @Test func upkeepPublishesAMissingPidfileAndKeepsTheLockHeld() throws {
        let files = try UpkeepFiles()
        defer { files.cleanup() }
        let inode = try files.inode(files.paths.ownerLock)
        try FileManager.default.removeItem(atPath: files.paths.pidfile)

        files.host.maintain(files.endpoint, log: files.logDescriptor)

        #expect(try String(contentsOfFile: files.paths.pidfile, encoding: .utf8) == "\(getpid())\n")
        #expect(try files.inode(files.paths.ownerLock) == inode)
        let second = open(files.paths.ownerLock, O_RDWR | O_CLOEXEC)
        try #require(second >= 0)
        defer { close(second) }
        #expect(flock(second, LOCK_EX | LOCK_NB) == -1)
    }

    @Test(arguments: ["", "1\n"])
    func upkeepRewritesAPidfileThatDoesNotHoldTheHostPid(content: String) throws {
        let files = try UpkeepFiles()
        defer { files.cleanup() }
        try content.write(toFile: files.paths.pidfile, atomically: false, encoding: .utf8)

        files.host.maintain(files.endpoint, log: files.logDescriptor)

        #expect(try String(contentsOfFile: files.paths.pidfile, encoding: .utf8) == "\(getpid())\n")
    }

    @Test func upkeepLeavesASymlinkedPidfileAndABadLogDescriptorAlone() throws {
        let files = try UpkeepFiles()
        defer { files.cleanup() }
        let target = files.directory.appendingPathComponent("elsewhere").path
        try "keep\n".write(toFile: target, atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: files.paths.pidfile)
        try FileManager.default.createSymbolicLink(atPath: files.paths.pidfile, withDestinationPath: target)
        try files.age([target, files.paths.ownerLock])

        files.endpoint.keepFilesCurrent(log: -1)

        #expect(try !files.isFresh(target))
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep\n")
        #expect(try files.isFresh(files.paths.ownerLock))
    }

    @Test func closedEndpointIsNotRefreshed() throws {
        let files = try UpkeepFiles()
        defer { files.cleanup() }
        files.endpoint.close()

        files.endpoint.keepFilesCurrent(log: files.logDescriptor)

        #expect(!FileManager.default.fileExists(atPath: files.paths.pidfile))
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func idleHostRefreshesAReusedStaleLockWithoutReplacingIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let stale = open(fixture.paths.ownerLock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(stale >= 0)
        close(stale)
        let old = Date(timeIntervalSinceNow: -4 * 86400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: fixture.paths.ownerLock)
        let inode = try #require(FileManager.default.attributesOfItem(atPath: fixture.paths.ownerLock)[.systemFileNumber] as? NSNumber)

        try fixture.start()

        let deadline = Date().addingTimeInterval(5)
        var modified = old
        while Date() < deadline, modified.timeIntervalSinceNow < -60 {
            Thread.sleep(forTimeInterval: 0.01)
            modified = try #require(FileManager.default.attributesOfItem(atPath: fixture.paths.ownerLock)[.modificationDate] as? Date)
        }
        #expect(modified.timeIntervalSinceNow > -60)
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.paths.ownerLock)[.systemFileNumber] as? NSNumber == inode)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func disclaimedHostServesItsOwnKeyedEndpointOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let child = try fixture.start()
        #expect(fixture.paths.socket.contains("/session-host-"))
        #expect(!FileManager.default.fileExists(atPath: try SessionHost.paths(socketDirectory: fixture.socketDirectory).socket))
        #expect(try String(contentsOfFile: fixture.paths.pidfile, encoding: .utf8) == "\(child)\n")
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func jobHostWhoseJobIsAbsentStillStopsCleanly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let key = try Fixture.endpointKey(of: fixture.executable)
        let child = try fixture.start(job: [key, HostJob.labelPrefix(bundleID: fixture.identity.bundleID, key: key) + "deadbeef"])
        #expect(try String(contentsOfFile: fixture.paths.pidfile, encoding: .utf8) == "\(child)\n")
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socket))
    }

    enum JobMismatch: CaseIterable { case key, label }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"),
          arguments: JobMismatch.allCases)
    func jobHostRefusesAnotherEndpointBeforeTakingOne(_ mismatch: JobMismatch) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let own = try Fixture.endpointKey(of: fixture.executable)
        let key = mismatch == .key ? "000000000000-1" : own
        let bundleID = mismatch == .label ? "com.example.other" : fixture.identity.bundleID
        let error = #expect(throws: FixtureCommandError.self) {
            try fixture.run(fixture.executable, arguments: ["host", fixture.socketDirectory, key, HostJob.labelPrefix(bundleID: bundleID, key: key) + "deadbeef"])
        }
        #expect(error?.status == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socket))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.pidfile))
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func stopCommandSkipsTheCurrentEndpointAndReportsAbsentOnes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        let legacy = URL(fileURLWithPath: fixture.socketDirectory).appendingPathComponent(SessionHost.legacyEndpoint)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: fixture.socketDirectory).appendingPathComponent("unrelated"),
                                                withIntermediateDirectories: true)

        let report = try fixture.stopOthers()

        #expect(report == ["session-host absent"])
        #expect(kill(try #require(fixture.pid), 0) == 0)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func stopCommandRetiresAnotherEndpointOnlyOnceItRootsNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let host = try fixture.start()
        let legacy = URL(fileURLWithPath: fixture.socketDirectory).appendingPathComponent(SessionHost.legacyEndpoint)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: URL(fileURLWithPath: fixture.paths.socket).deletingLastPathComponent())
        let name = ZmxSupport.daemonName(for: UUID())
        fixture.names.append(name)
        let request = SessionHost.Ensure(name: name, argv: [fixture.zmx.path, "attach", name], cwd: fixture.directory.path,
                                        env: fixture.environment, rows: 24, cols: 80)
        guard case .ok(let ready) = try fixture.exchange(.ensure(request)).last else {
            Issue.record("daemon was not created; host log: \(fixture.hostLog())")
            return
        }

        #expect(try fixture.stopOthers() == ["session-host refused: live rooted daemons remain"])
        #expect(kill(host, 0) == 0)

        _ = try fixture.run(fixture.zmx, arguments: ["kill", name])
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, kill(ready.leaderPid, 0) == 0 { Thread.sleep(forTimeInterval: 0.05) }
        #expect(try fixture.stopOthers() == ["session-host stopped"])
        try fixture.waitForExit()
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
        let replies = try fixture.exchange(.ensure(request))
        guard case .ok(let ready) = replies.last else {
            Issue.record("daemon was not created: \(replies.map(String.init(describing:))); host log: \(fixture.hostLog())")
            return
        }
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

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and the staged zmx from scripts/setup.sh"))
    func oversizedRequestPeerClosureDoesNotKillTheClient() throws {
        // an oversized request could kill the client with sigpipe
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        #expect(try fixture.raw(Data(repeating: 0x61, count: SessionHost.maximumFrameBytes * 8)).isEmpty)
        #expect(try fixture.exchange(.stop).last == .stopped)
        try fixture.waitForExit()
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the staged fixture executables"),
          arguments: [("exit 23", Int32(23), Process.TerminationReason.exit),
                      ("kill -KILL $$", SIGKILL, Process.TerminationReason.uncaughtSignal)])
    func failedFixtureClientCannotPassAsAnEmptyReply(termination: String, status: Int32, reason: Process.TerminationReason) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let command = fixture.directory.appendingPathComponent("failed-client")
        try "#!/bin/sh\nprintf 'fixture failure' >&2\n\(termination)\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)

        let error = try #require(throws: FixtureCommandError.self) { try fixture.raw(Data(), command: command) }
        #expect(error.command == command.path)
        #expect(error.status == status)
        #expect(error.reason == reason)
        #expect(error.stderr == "fixture failure")
    }

    private struct FixtureCommandError: Error, CustomStringConvertible {
        let command: String
        let status: Int32
        let reason: Process.TerminationReason
        let stderr: String

        var description: String {
            let termination = reason == .exit ? "exit" : "signal"
            return "fixture command \(command) failed: \(termination) \(status): \(stderr)"
        }
    }

    private final class Clock {
        var time: TimeInterval = 0
    }

    // regression: a command that ended before the pane attached lost its output to the creation's own attach
    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and staged zmx"))
    func aFastCommandsOutputReachesThePaneAndNoShellStarts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        guard let pane = try createdPane(fixture, payload: ["/bin/sh", "-c", "printf FAST-OUTPUT"]) else { return }
        try #require(try fixture.list().contains(where: { $0.name == pane.name }), "the held command ended before the pane attached")

        let attach = try PTYProcess.spawn(argv: pane.argv, env: pane.request.env, cwd: pane.request.cwd, rows: 24, cols: 80)
        let attachChild = NativeHostChild(attach)
        defer { try? attachChild.terminate(grace: 1) }
        var status: Int32 = 0
        var ended = false
        var lastWait: pid_t = 0
        var lastErrno: Int32 = 0
        var screen = ""
        let clock = ContinuousClock()
        let windowStart = clock.now
        let attachDeadline = Date().addingTimeInterval(10)
        while !ended, Date() < attachDeadline {
            // zmx restores the terminal with TCSAFLUSH on exit, which blocks until the master reads its output
            screen += Self.available(attach.ptyFD)
            lastWait = waitpid(attach.pid, &status, WNOHANG)
            lastErrno = lastWait == -1 ? errno : 0
            ended = lastWait == attach.pid
            if !ended { Thread.sleep(forTimeInterval: 0.02) }
        }
        screen += Self.available(attach.ptyFD)
        let elapsed = clock.now - windowStart
        #expect(ended, "the pane's attach to a fast command kept running")
        if !ended {
            Issue.record("""
                stall report:
                \(StalledAttach(pane: attach, argv: pane.argv, daemon: pane.name, elapsed: elapsed, lastWait: lastWait,
                                lastErrno: lastErrno, screen: screen).report(fixture: fixture))
                """)
        }
        #expect(screen.contains("FAST-OUTPUT"), "screen: \(screen.debugDescription)")
        #expect(!screen.contains("session is gone"), "screen: \(screen.debugDescription)")
        let leftover = try fixture.list().filter { $0.name == pane.name }
        #expect(leftover.isEmpty, "a daemon started under the ended command's name: \(leftover)")
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and staged zmx"))
    func startupTerminalQueriesReachThePaneAndItsRepliesReachTheCommand() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        let probe = #"stty raw -echo; printf '\033[6n\033]11;?\033\\'; "#
            + #"IFS= read -r -t 5 -d R cpr && IFS= read -r -t 5 -d '\' osc && "#
            + #"[ "$cpr" = $'\e[5;7' ] && [ "$osc" = $'\e]11;rgb:3030/3030/3030\e' ] && result=OK || result=MISSING; "#
            + #"stty sane; printf 'REPLIES-%s.' "$result"; sleep 30"#
        guard let pane = try createdPane(fixture, payload: ["/bin/bash", "-c", probe]) else { return }

        let attach = try PTYProcess.spawn(argv: pane.argv, env: pane.request.env, cwd: pane.request.cwd, rows: 24, cols: 80)
        let attachChild = NativeHostChild(attach)
        defer { try? attachChild.terminate(grace: 1) }
        var screen = ""
        var answered = false
        let deadline = Date().addingTimeInterval(10)
        while !screen.contains("REPLIES-OK."), !screen.contains("REPLIES-MISSING."), Date() < deadline {
            screen += Self.available(attach.ptyFD)
            if !answered, screen.contains("\u{1B}[6n"), screen.contains("\u{1B}]11;?\u{1B}\\") {
                answered = true
                let replies = Array("\u{1B}[5;7R\u{1B}]11;rgb:3030/3030/3030\u{1B}\\".utf8)
                try #require(replies.withUnsafeBytes { write(attach.ptyFD, $0.baseAddress, $0.count) } == replies.count)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(answered, "the pane never saw the startup queries; screen: \(screen.debugDescription)")
        #expect(screen.contains("REPLIES-OK."), "screen: \(screen.debugDescription); log: \(fixture.hostLog())")
    }

    private struct CreatedPane {
        let name: String
        let request: SessionHost.Ensure
        let argv: [String]
    }

    private func createdPane(_ fixture: Fixture, payload: [String]) throws -> CreatedPane? {
        let name = ZmxSupport.daemonName(for: UUID())
        fixture.names.append(name)
        let request = SessionHost.Ensure(name: name, argv: [fixture.zmx.path, "attach", name] + payload,
                                         cwd: fixture.directory.path, env: fixture.environment, rows: 24, cols: 80)
        let reply = try #require(try fixture.exchange(.ensure(request)).last)
        guard case .ok(let ready) = reply, ready.state == .created else {
            Issue.record("creation was not confirmed: \(reply); log: \(fixture.hostLog())")
            return nil
        }
        var argv: [String] = []
        let client = Client(connect: { ForwardingPeer(reply: reply) }, diagnostic: { _ in }, execute: { attach, _ in argv = attach })
        try client.run(request: request, endsPane: true)
        try #require(!argv.isEmpty)
        return CreatedPane(name: name, request: request, argv: argv)
    }

    private struct StalledAttach {
        let pane: PTYProcess
        let argv: [String]
        let daemon: String
        let elapsed: Duration
        let lastWait: pid_t
        let lastErrno: Int32
        let screen: String

        func report(fixture: Fixture) -> String {
            let listing: String
            do {
                listing = try fixture.list().map { "\($0.name)" }.joined(separator: ", ")
            } catch {
                listing = "list failed: \(error)"
            }
            return """
                pid=\(pane.pid) elapsed=\(elapsed) waitpid=\(lastWait) errno=\(lastErrno) \
                p_stat=\(SessionHostServerTests.processState(pane.pid)) argv=\(argv) daemon=\(daemon)
                pty: \((screen + SessionHostServerTests.available(pane.ptyFD)).debugDescription)
                exec error: \(SessionHostServerTests.available(pane.execErrorFD).debugDescription)
                zmx list: \(listing)
                host log: \(fixture.hostLog())
                \(stacks())
                """
        }

        private func stacks() -> String {
            let rows = SessionHostServerTests.capture(["/bin/ps", "-axo", "pid,ppid,pgid,stat,etime,command"], timeout: 5)
                .split(separator: "\n").filter { row in
                    let fields = row.split(separator: " ")
                    return fields.count > 1 && (fields[0] == "\(pane.pid)" || fields[1] == "\(pane.pid)" || row.contains(daemon))
                }
            let pids = rows.compactMap { Int32($0.split(separator: " ").first ?? "") }
            let samples = pids.map { pid in
                let output = SessionHostServerTests.capture(["/usr/bin/sample", "\(pid)", "1"], timeout: 10)
                let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                let graph = lines.drop { !$0.hasPrefix("Call graph:") }.prefix { !$0.hasPrefix("Total number in stack") }.prefix(80)
                return "sample \(pid):\n" + (graph.isEmpty ? lines.prefix(5) : graph).joined(separator: "\n")
            }
            return (["processes:"] + rows.map(String.init) + samples).joined(separator: "\n")
        }
    }

    // output goes to a file: a full pipe would stall the command until the deadline killed it
    private static func capture(_ argv: [String], timeout: TimeInterval) -> String {
        let path = NSTemporaryDirectory() + "agterm-capture-\(UUID().uuidString)"
        defer { unlink(path) }
        guard FileManager.default.createFile(atPath: path, contents: nil), let output = FileHandle(forWritingAtPath: path) else {
            return "\(argv[0]): no output file"
        }
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return "\(argv[0]) failed: \(error)" }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = process.isRunning
        if timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return timedOut ? text + "\n\(argv[0]) timed out after \(Int(timeout)) s" : text
    }

    private static func available(_ fd: Int32) -> String {
        guard fd >= 0 else { return "<no fd>" }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count < 16384 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            bytes.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func processState(_ pid: pid_t) -> String {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return "sysctl errno \(errno)" }
        guard size > 0 else { return "absent" }
        let names: [Int32: String] = [1: "SIDL", 2: "SRUN", 3: "SSLEEP", 4: "SSTOP", 5: "SZOMB"]
        let stat = Int32(info.kp_proc.p_stat)
        return "\(names[stat] ?? "\(stat)") flags=0x\(String(info.kp_proc.p_flag, radix: 16))"
    }

    private final class ForwardingPeer: ClientPeer {
        let reply: SessionHost.Response
        init(reply: SessionHost.Response) { self.reply = reply }
        func send(_ frame: Data, deadline: TimeInterval) throws {}
        func receive(deadline: TimeInterval) throws -> SessionHost.Response { reply }
        func close() {}
    }

    private final class Child: HostChild {
        let pid: Int32 = 500
        var state: HostChildState = .running
        var hasExited = false
        var exitStatus: Int32?
        var stopReason: String?
        func exit(_ status: Int32) {
            state = .exited
            exitStatus = status
        }
        var terminations = 0
        var terminatedPIDs: [Int32] = []
        var onPoll: ((Child) -> Void)?
        func poll() -> HostChildState {
            onPoll?(self)
            return state
        }
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
        var spawned: [SessionHost.Ensure] = []
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
            spawned.append(request)
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
                                            zmxPath: request.argv[0], ensureTimeout: 0.3, pollInterval: 0.1, terminationGrace: 0.05,
                                            attachHold: 7)
            host = try SessionHostRuntime.Host(configuration: config, backend: backend,
                            now: realClock ? { ProcessInfo.processInfo.systemUptime } : { clock.time },
                            pause: realClock ? { Thread.sleep(forTimeInterval: $0) } : { clock.time += $0 })
        }
    }

    private final class UpkeepFiles {
        let directory: URL
        let paths: SessionHost.Paths
        let endpoint: HostEndpoint
        let log: String
        let logDescriptor: Int32
        let clock = Clock()
        let host: SessionHostRuntime.Host

        init() throws {
            directory = URL(fileURLWithPath: "/tmp/shs-\(UUID().uuidString)", isDirectory: true)
            let socketDirectory = directory.appendingPathComponent("zmx").path
            paths = try SessionHost.paths(socketDirectory: socketDirectory)
            endpoint = try HostEndpoint(socketDirectory: socketDirectory, paths: paths)
            log = paths.log
            logDescriptor = open(log, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            let clock = clock
            let config = SessionHostRuntime.Host.Configuration(socketDirectory: socketDirectory,
                                            identity: .init(bundleID: "com.umputun.agterm", bundlePath: "/Applications/agterm.app", pid: getpid()),
                                            zmxPath: "/Applications/agterm.app/Contents/MacOS/zmx")
            host = try SessionHostRuntime.Host(configuration: config, backend: Backend(), upkeepNow: { clock.time })
        }

        func age(_ paths: [String]) throws {
            for path in paths {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -4 * 86400)], ofItemAtPath: path)
            }
        }

        func isFresh(_ path: String) throws -> Bool {
            let modified = try #require(FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            return modified.timeIntervalSinceNow > -60
        }

        func inode(_ path: String) throws -> NSNumber {
            try #require(FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)
        }

        func cleanup() {
            endpoint.close()
            if logDescriptor >= 0 { close(logDescriptor) }
            try? FileManager.default.removeItem(at: directory)
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
            identity = .init(bundleID: "com.umputun.hosttest", bundlePath: bundle.path)
            environment = ["ZMX_DIR": socketDirectory, "ZMX_SESSION": "", "ZMX_SESSION_PREFIX": "", "ZMX_NO_DETACH_KEY": "1",
                           "SHELL": "/bin/sh", "HOME": directory.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.copyItem(at: package.appendingPathComponent(".build/debug/agterm-session-host"), to: executable)
            try FileManager.default.copyItem(atPath: stagedZmxPath, toPath: zmx.path)
            try FileManager.default.copyItem(at: package.appendingPathComponent(".build/debug/session-host-test-client"), to: client)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
            let info = ["CFBundleIdentifier": identity.bundleID, "CFBundleExecutable": "agterm-session-host", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            paths = try SessionHost.paths(socketDirectory: socketDirectory, key: Self.endpointKey(of: executable))
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: paths.spawnLock).deletingLastPathComponent(), withIntermediateDirectories: true)
            let lock = open(paths.spawnLock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            if lock >= 0 { close(lock) }
        }

        static func endpointKey(of executable: URL) throws -> String {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["key"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @discardableResult func start(job: [String] = []) throws -> Int32 {
            let child = try Responsibility.system.spawnDisclaimed(executable: executable.path,
                                                                  argv: [executable.path, "host", environment["ZMX_DIR"]!] + job, env: environment)
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

        var socketDirectory: String { environment["ZMX_DIR"]! }

        func stopOthers() throws -> [String] {
            let data = try run(executable, arguments: ["stop", socketDirectory])
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }

        func list() throws -> [ZmxSessionRecord] {
            let data = try run(zmx, arguments: ["list"])
            return try ZmxListParser.parse(String(decoding: data, as: UTF8.self))
        }

        func hostLog() -> String {
            (try? String(contentsOfFile: paths.log, encoding: .utf8)) ?? "none"
        }

        func exchange(_ request: SessionHost.Request) throws -> [SessionHost.Response] {
            var data = try SessionHost.encodeFrame(SessionHost.Request.hello(identity))
            data.append(try SessionHost.encodeFrame(request))
            let replies = try raw(data)
            if replies.count != 2 {
                print("host fixture replies: \(replies); log: \(hostLog())")
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

        func run(_ command: URL, arguments: [String], input: URL? = nil, stall: Bool = false) throws -> Data {
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
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw FixtureCommandError(command: command.path, status: process.terminationStatus,
                                          reason: process.terminationReason, stderr: stderr)
            }
            return output.fileHandleForReading.readDataToEndOfFile()
        }
    }
}
