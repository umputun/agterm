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
    @Test func nativeReplyWritesPreservePartialAndTransientRemainders() throws {
        for errors in [[Int32(2), -EINTR, 3], [-EAGAIN], [-EINTR, -EINTR, -EINTR, -EINTR]] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("output")
            try Data("\u{1B}[c\u{1B}[>c".utf8).write(to: output)
            let fd = open(output.path, O_RDONLY)
            try #require(fd >= 0)
            let process = try PTYProcess.spawn(argv: ["/bin/sleep", "30"], env: [:], cwd: directory.path, rows: 24, cols: 80)
            defer { close(process.ptyFD) }
            var steps = errors
            var received: [UInt8] = []
            var calls = 0
            let child = NativeHostChild(.init(pid: process.pid, ptyFD: fd, execErrorFD: process.execErrorFD), writePTY: { target, bytes, count in
                #expect(target == fd)
                calls += 1
                let step = steps.isEmpty ? Int32(count) : steps.removeFirst()
                if step < 0 { errno = -step; return -1 }
                let accepted = min(Int(step), count)
                received += UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: accepted)
                return accepted
            })
            defer { try? child.terminate(grace: 0.5) }
            #expect(child.poll() == .running)
            #expect(calls <= 4)
            for _ in 0..<8 { #expect(child.poll() == .running) }
            #expect(received == Array("\u{1B}[?62;22c\u{1B}[>1;10;0c".utf8))
            try child.terminate(grace: 0.5)
            #expect(child.hasExited)
        }
    }

    @Test func nativeReplyBackpressureAndFailedWritesDoNotHoldTermination() throws {
        for error in [EAGAIN, EIO] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("output")
            try Data(String(repeating: "\u{1B}[>c", count: 30_000).utf8).write(to: output)
            let fd = open(output.path, O_RDONLY)
            try #require(fd >= 0)
            let process = try PTYProcess.spawn(argv: ["/bin/sleep", "30"], env: [:], cwd: directory.path, rows: 24, cols: 80)
            defer { close(process.ptyFD) }
            var calls = 0
            var maximum = 0
            var writable = false
            let child = NativeHostChild(.init(pid: process.pid, ptyFD: fd, execErrorFD: process.execErrorFD), writePTY: { _, _, count in
                calls += 1
                maximum = max(maximum, count)
                if writable { return count }
                errno = error
                return -1
            })
            defer { try? child.terminate(grace: 0.5) }
            for _ in 0..<20 { #expect(child.poll() == .running) }
            let stoppedOffset = lseek(fd, 0, SEEK_CUR)
            let callsBefore = calls
            for _ in 0..<20 { #expect(child.poll() == .running) }
            #expect(lseek(fd, 0, SEEK_CUR) == stoppedOffset)
            #expect(stoppedOffset < 120_000)
            #expect(maximum <= 64 * 1024)
            #expect(maximum >= 64 * 1024 - DeviceAttributeResponder.maximumReplyLength)
            #expect(calls - callsBefore == 20)
            writable = true
            _ = child.poll()
            _ = child.poll()
            #expect(lseek(fd, 0, SEEK_CUR) > stoppedOffset)
            writable = false
            let start = ProcessInfo.processInfo.systemUptime
            try child.terminate(grace: 0.5)
            #expect(ProcessInfo.processInfo.systemUptime - start < 1.5)
            #expect(child.hasExited)
            #expect(kill(getpid(), 0) == 0)
        }
    }

    @Test func nativeExitWithPendingRepliesDoesNotWriteReapedDescriptors() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        try Data("\u{1B}[c".utf8).write(to: output)
        let fd = open(output.path, O_RDONLY)
        try #require(fd >= 0)
        let process = try PTYProcess.spawn(argv: ["/bin/sleep", "30"], env: [:], cwd: directory.path, rows: 24, cols: 80)
        defer { close(process.ptyFD) }
        var calls = 0
        let child = NativeHostChild(.init(pid: process.pid, ptyFD: fd, execErrorFD: process.execErrorFD), writePTY: { _, _, _ in
            calls += 1
            errno = EAGAIN
            return -1
        })
        defer { try? child.terminate(grace: 0.5) }
        #expect(child.poll() == .running)
        #expect(calls == 1)
        #expect(kill(process.pid, SIGKILL) == 0)
        let deadline = Date().addingTimeInterval(2)
        while !child.hasExited && Date() < deadline { _ = child.poll(); Thread.sleep(forTimeInterval: 0.005) }
        try #require(child.hasExited)
        let callsAtExit = calls
        try child.terminate(grace: 0.5)
        #expect(calls == callsAtExit)
        #expect(kill(getpid(), 0) == 0)
    }

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
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while child.poll() == .running, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(child.poll() == .exited)
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

    @Test func clientlessProbeCanProceedAfterAnUnansweredStartupQuery() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = try AttributeProbe(directory: directory, phases: 2, offsetMilliseconds: 0)
        let process = try PTYProcess.spawn(argv: probe.argv, env: ["PATH": "/usr/bin:/bin"],
                                           cwd: directory.path, rows: 24, cols: 80)
        let child = NativeHostChild(process)
        defer { try? child.terminate(grace: 0.5) }
        try probe.wait(for: "written-1", timeout: 3)
        #expect(!probe.exists("reply-1"))
        try probe.signal(2)
        try probe.wait(for: "written-2", timeout: 3)
        #expect(probe.exists("abandoned-1"))
        #expect(!probe.exists("reply-1"))
        #expect(try probe.outcome(2, bound: 0.05) == "TIMEOUT")
    }

    @Test func teardownAnswersAQueryArrivingAfterItsFirstPass() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = try AttributeProbe(directory: directory, phases: 2, offsetMilliseconds: 0)
        let process = try PTYProcess.spawn(argv: probe.argv, env: ["PATH": "/usr/bin:/bin"],
                                           cwd: directory.path, rows: 24, cols: 80)
        var released = false
        let child = NativeHostChild(process, pause: { interval in
            if !released {
                released = true
                try? probe.signal(2)
                try? probe.wait(for: "written-2", timeout: 3)
            }
            Thread.sleep(forTimeInterval: interval)
        })
        defer { try? child.terminate(grace: 0.5) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !probe.exists("reply-1") {
            try #require(ProcessInfo.processInfo.systemUptime < deadline, "markers=\(probe.markers())")
            #expect(child.poll() == .running)
            Thread.sleep(forTimeInterval: 0.002)
        }
        try child.terminate(grace: 0.5)
        #expect(released)
        #expect(try probe.outcome(2, bound: 0.5) == AttributeProbe.secondary, "markers=\(probe.markers())")
    }

    @Test func teardownDoesNotSignalAChildThatExitedWhileSettling() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try PTYProcess.spawn(argv: ["/bin/sh", "-c", "printf '\\033[c'; exec /bin/sleep 30"], env: [:],
                                           cwd: directory.path, rows: 24, cols: 80)
        var writes = 0
        var signals: [Int32] = []
        var killed = false
        let child = NativeHostChild(process, writePTY: { _, _, count in writes += 1; return count },
                                    pause: { interval in
                                        if !killed {
                                            killed = true
                                            kill(process.pid, SIGKILL)
                                            var info = siginfo_t()
                                            waitid(P_PID, id_t(process.pid), &info, WEXITED | WNOWAIT)
                                        }
                                        Thread.sleep(forTimeInterval: interval)
                                    },
                                    signal: { pid, number in signals.append(number); return kill(pid, number) })
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while writes == 0 {
            try #require(ProcessInfo.processInfo.systemUptime < deadline)
            #expect(child.poll() == .running)
            Thread.sleep(forTimeInterval: 0.002)
        }
        try child.terminate(grace: 0.5)
        #expect(killed)
        #expect(child.hasExited)
        #expect(signals.isEmpty)
    }

    @Test func teardownWithoutAttributeTrafficSignalsWithoutPausing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try PTYProcess.spawn(argv: ["/bin/sleep", "30"], env: [:], cwd: directory.path, rows: 24, cols: 80)
        var pauses = 0
        var writes = 0
        let child = NativeHostChild(process, writePTY: { _, _, count in writes += 1; return count }, pause: { _ in pauses += 1 })
        #expect(child.poll() == .running)
        try child.terminate(grace: 0.5)
        #expect(child.hasExited)
        #expect(pauses == 0)
        #expect(writes == 0)
    }

    @Test func teardownSettlingStopsAtItsLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        try Data("\u{1B}[c".utf8).write(to: output)
        let fd = open(output.path, O_RDONLY)
        try #require(fd >= 0)
        let process = try PTYProcess.spawn(argv: ["/bin/sleep", "30"], env: [:], cwd: directory.path, rows: 24, cols: 80)
        defer { close(process.ptyFD) }
        let clock = Clock()
        var paused: TimeInterval = 0
        let child = NativeHostChild(.init(pid: process.pid, ptyFD: fd, execErrorFD: process.execErrorFD),
                                    writePTY: { _, _, _ in errno = EAGAIN; return -1 },
                                    now: { clock.time }, pause: { clock.time += $0; paused += $0 })
        #expect(child.poll() == .running)
        try child.terminate(grace: 0.5)
        #expect(child.hasExited)
        #expect(paused >= NativeHostChild.settleLimit)
        #expect(paused < NativeHostChild.settleLimit + 2 * NativeHostChild.settleStep)
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and staged zmx"))
    func attachedWindowRepliesBeforeReadiness() throws {
        try attachedProbe(transition: false)
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and staged zmx"))
    func readinessTransitionMeasuresWrittenQuerySeparatelyFromReceivedReply() throws {
        try attachedProbe(transition: true)
    }

    private func attachedProbe(transition: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let probe = try AttributeProbe(directory: fixture.directory, phases: transition ? 3 : 2)
        let backend = AttachedBackend(fixture: fixture, probe: probe, transition: transition)
        let root = try #require(Responsibility.system.responsibleProcess(of: getpid()))
        let identity = SessionHost.Hello(bundleID: fixture.identity.bundleID, bundlePath: fixture.bundle.path, pid: root)
        let host = try SessionHostRuntime.Host(configuration: .init(socketDirectory: fixture.environment["ZMX_DIR"]!,
                                                                  identity: identity, zmxPath: fixture.zmx.path,
                                                                  ensureTimeout: 12, pollInterval: 0.005), backend: backend)
        let response = host.handle(ensure: fixture.probeRequest(probe))
        try #require(backend.sawInitialization,
                     "stock zmx did not expose the init resize witness; response=\(response); child=\(backend.child?.stopReason ?? "running")")
        let primaryMatches = try probe.result(1) == AttributeProbe.primary
        let secondaryMatches = try probe.result(2) == AttributeProbe.secondary
        #expect(backend.attachedThroughout)
        #expect(primaryMatches)
        #expect(secondaryMatches)
        guard case .ok = response else { Issue.record("creation failed: \(response)"); return }
        if transition {
            #expect(probe.exists("written-3"))
            #expect(try probe.outcome(3, bound: 3) == AttributeProbe.primary, "markers=\(probe.markers())")
        }
        print("attached-window: init witness=\(backend.sawInitialization); DA1 exact=\(primaryMatches); DA2 exact=\(secondaryMatches); attach alive=\(backend.attachedThroughout)")
    }

    @Test(.enabled(if: sessionHostFixtureReady, "needs the responsibility SPI and staged zmx"))
    func realHostStartupReplyAndClientlessControl() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        let probe = try AttributeProbe(directory: fixture.directory, phases: 2, offsetMilliseconds: 0)
        let exchange = try fixture.beginExchange(.ensure(fixture.probeRequest(probe)))
        let startup = try probe.observe(1, bound: 3, exchange: exchange, fixture: fixture)
        let startupMatches = startup.outcome == AttributeProbe.primary
        #expect(startupMatches || startup.outcome == "TIMEOUT")
        guard case .ok = try exchange.finish().last else { Issue.record("real host ensure failed"); return }
        // each poll spawns a zmx list process, so this one is deliberately slow.
        while try fixture.list().first?.clients != 0 {
            guard ProcessInfo.processInfo.systemUptime < exchange.deadline else { throw POSIXError(.ETIMEDOUT) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try probe.signal(2)
        let controlOutcome = try probe.outcome(2, bound: 3)
        let controlMatches = controlOutcome == AttributeProbe.secondary
        #expect(controlMatches, "DA2 outcome=\(String(reflecting: controlOutcome)); markers=\(probe.markers())")
        print("real-host startup: phase at emission=\(startup.phase); DA1 exact=\(startupMatches); clientless DA2 exact=\(controlMatches)")
    }

    private static let sweepTrials = 5

    @Test(.enabled(if: sessionHostFixtureReady && ProcessInfo.processInfo.environment["AGTERM_DA_SWEEP"] != nil,
                  "needs AGTERM_DA_SWEEP and the responsibility SPI and staged zmx"),
          arguments: [0, 5, 20, 50, 100, 200])
    func realHostAttachedTimingSweep(offsetMilliseconds: Int) throws {
        var answered = 0
        var timedOut = 0
        var maximumLatency: TimeInterval = 0
        var maximumOffset: TimeInterval = 0
        var notCreated = 0
        var phases: [String: Int] = [:]
        for _ in 0..<Self.sweepTrials {
            let outcome = try realHostProbe(offsetMilliseconds: offsetMilliseconds)
            if outcome.answered {
                answered += 1
                maximumLatency = max(maximumLatency, outcome.latency)
            } else {
                timedOut += 1
            }
            maximumOffset = max(maximumOffset, outcome.achievedOffset)
            if !outcome.ensured { notCreated += 1 }
            phases[outcome.phase, default: 0] += 1
        }
        let observed = phases.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        print("""
              DA sweep offset_ms=\(offsetMilliseconds) trials=\(Self.sweepTrials) answered=\(answered) \
              timed_out=\(timedOut) max_answered_latency_ms=\(Int((maximumLatency * 1000).rounded())) \
              max_achieved_offset_ms=\(Int((maximumOffset * 1000).rounded())) ensure_not_ok=\(notCreated) \
              phases=\(observed)
              """)
    }

    private struct Trial {
        let answered: Bool
        let latency: TimeInterval
        let achievedOffset: TimeInterval
        let phase: String
        let ensured: Bool
    }

    private func realHostProbe(offsetMilliseconds: Int) throws -> Trial {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.start()
        let probe = try AttributeProbe(directory: fixture.directory, phases: 1, offsetMilliseconds: offsetMilliseconds)
        let exchange = try fixture.beginExchange(.ensure(fixture.probeRequest(probe)))
        let observation = try probe.observe(1, bound: 3, exchange: exchange, fixture: fixture)
        let answered = observation.outcome == AttributeProbe.primary
        #expect(answered || observation.outcome == "TIMEOUT")
        let responses = try exchange.finish()
        var ensured = false
        if case .ok = responses.last {
            ensured = true
        } else {
            Issue.record("real host ensure failed at offset \(offsetMilliseconds) ms: \(responses)")
        }
        let latency = answered ? try probe.interval(from: "written-1", to: "reply-1") : 3
        return Trial(answered: answered, latency: latency,
                     achievedOffset: try probe.interval(from: "started", to: "written-1"),
                     phase: observation.phase, ensured: ensured)
    }

    private final class AttachedBackend: HostBackend {
        let native: NativeHostBackend
        let fixture: Fixture
        let probe: AttributeProbe
        let transition: Bool
        var child: (any HostChild)?
        var sawInitialization = false
        var attachedThroughout = true
        var released = 0

        init(fixture: Fixture, probe: AttributeProbe, transition: Bool) {
            self.fixture = fixture
            self.probe = probe
            self.transition = transition
            native = NativeHostBackend(socketDirectory: fixture.environment["ZMX_DIR"]!, zmxPath: fixture.zmx.path,
                                       environment: fixture.environment)
        }

        func list(deadline: TimeInterval) throws -> [ZmxSessionRecord] {
            let records = try native.list(deadline: deadline)
            guard let child else { return records }
            attachedThroughout = attachedThroughout && !child.hasExited && kill(child.pid, 0) == 0
            if !sawInitialization { sawInitialization = fixture.hasInitializationLog() }
            guard sawInitialization else { return [] }
            if released == 0 {
                try probe.signal(1)
                released = 1
            }
            if released == 1 && probe.exists("reply-1") {
                try probe.signal(2)
                released = 2
            }
            guard probe.exists("reply-2") else { return [] }
            if transition && released == 2 {
                try probe.signal(3)
                released = 3
                // only the readiness transition waits for emission; regular listing never blocks the drain loop.
                try probe.wait(for: "written-3", timeout: 1)
            }
            return records
        }

        func spawn(_ request: SessionHost.Ensure) throws -> any HostChild {
            let child = try native.spawn(request)
            self.child = child
            return child
        }

        func responsibleProcess(of pid: Int32) -> Int32? { native.responsibleProcess(of: pid) }
        func daemonPID(for leader: Int32) -> Int32? { native.daemonPID(for: leader) }
        func isAlive(_ pid: Int32) -> Bool { native.isAlive(pid) }
    }

    private final class AttributeProbe {
        static let primary = "\u{1B}[?62;22c"
        static let secondary = "\u{1B}[>1;10;0c"
        let directory: URL
        let script: URL
        let phases: Int
        let offset: String

        init(directory: URL, phases: Int, offsetMilliseconds: Int = -1) throws {
            self.directory = directory.appendingPathComponent("probe-\(UUID().uuidString)")
            self.phases = phases
            // a negative offset gates phase one on its go marker too.
            offset = offsetMilliseconds < 0 ? "-1" : String(format: "%.3f", Double(offsetMilliseconds) / 1000)
            script = self.directory.appendingPathComponent("probe.bash")
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let source = #"""
            marker_dir=$1
            phases=$2
            offset=$3
            printf started > "$marker_dir/started"
            saved=$(stty -g)
            reader=
            trap '[ -z "$reader" ] || { kill -KILL "$reader" 2>/dev/null; wait "$reader" 2>/dev/null; }; stty "$saved"' EXIT
            phase=1
            while [ "$phase" -le "$phases" ]; do
                stty raw -echo
                if [ "$phase" -eq 1 ] && [ "$offset" != "-1" ]; then
                    [ "$offset" = "0.000" ] || sleep "$offset"
                else
                    deadline=$((SECONDS + 12))
                    while [ ! -f "$marker_dir/go-$phase" ]; do
                        [ "$SECONDS" -lt "$deadline" ] || exit 2
                        sleep 0.005
                    done
                fi
                if [ "$phase" -eq 2 ]; then printf '\033[>c'; else printf '\033[c'; fi
                printf written > "$marker_dir/written-$phase"
                # a separate reader lets the next go marker cancel an unanswered phase.
                (
                    reply=
                    if IFS= read -r -d c reply; then
                        printf '%sc' "$reply" > "$marker_dir/reply-$phase.tmp"
                        mv "$marker_dir/reply-$phase.tmp" "$marker_dir/reply-$phase"
                    fi
                ) < /dev/tty &
                reader=$!
                next=$((phase + 1))
                while [ ! -f "$marker_dir/reply-$phase" ] && [ ! -f "$marker_dir/go-$next" ]; do
                    kill -0 "$reader" 2>/dev/null || exit 3
                    sleep 0.005
                done
                if [ ! -f "$marker_dir/reply-$phase" ]; then
                    kill -KILL "$reader" 2>/dev/null
                    printf abandoned > "$marker_dir/abandoned-$phase"
                fi
                wait "$reader" 2>/dev/null
                reader=
                stty "$saved"
                phase=$((phase + 1))
            done
            sleep 30
            """#
            try source.write(to: script, atomically: true, encoding: .utf8)
        }

        var argv: [String] { ["/bin/bash", script.path, directory.path, String(phases), offset] }
        func markers() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()) ?? [] }
        func exists(_ marker: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) }
        func signal(_ phase: Int) throws { try Data().write(to: directory.appendingPathComponent("go-\(phase)")) }
        func result(_ phase: Int) throws -> String { try String(contentsOf: directory.appendingPathComponent("reply-\(phase)"), encoding: .utf8) }

        /// The phase is zmx's client count sampled once the query is written: the attach is no child of the host.
        func observe(_ phase: Int, bound: TimeInterval, exchange: PendingExchange,
                     fixture: Fixture) throws -> (phase: String, outcome: String) {
            var label = "unknown"
            var limit: TimeInterval?
            var outcome: String?
            while outcome == nil {
                if limit == nil, exists("written-\(phase)") {
                    limit = ProcessInfo.processInfo.systemUptime + bound
                    label = fixture.clientPhase()
                }
                if exists("reply-\(phase)") {
                    outcome = try result(phase)
                } else if let limit, ProcessInfo.processInfo.systemUptime >= limit {
                    outcome = "TIMEOUT"
                } else {
                    guard ProcessInfo.processInfo.systemUptime < exchange.deadline else { throw POSIXError(.ETIMEDOUT) }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            return (label, outcome!)
        }

        func outcome(_ phase: Int, bound: TimeInterval) throws -> String {
            let limit = ProcessInfo.processInfo.systemUptime + bound
            while !exists("reply-\(phase)") {
                guard ProcessInfo.processInfo.systemUptime < limit else { return "TIMEOUT" }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return try result(phase)
        }

        /// Marker mtimes are the clock: bash 3.2 has no sub-second time source.
        func interval(from start: String, to end: String) throws -> TimeInterval {
            try modified(end).timeIntervalSince(modified(start))
        }

        private func modified(_ marker: String) throws -> Date {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(marker).path)
            guard let date = attributes[.modificationDate] as? Date else { throw POSIXError(.EIO) }
            return date
        }
        func wait(for marker: String, timeout: TimeInterval) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !exists(marker) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    print("probe wait timed out: marker=\(marker); markers=\(markers())")
                    throw POSIXError(.ETIMEDOUT)
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    private final class Child: HostChild {
        let pid: Int32 = 500
        var state: HostChildState = .running
        var hasExited = false
        var stopReason: String?
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
            endpoint = try HostEndpoint(socketDirectory: socketDirectory)
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
            paths = try SessionHost.paths(socketDirectory: socketDirectory)
            identity = .init(bundleID: "com.umputun.hosttest.\(UUID().uuidString)", bundlePath: bundle.path)
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

        func hostLog() -> String {
            (try? String(contentsOfFile: paths.log, encoding: .utf8)) ?? "none"
        }

        func probeRequest(_ probe: AttributeProbe) -> SessionHost.Ensure {
            let name = ZmxSupport.daemonName(for: UUID())
            names.append(name)
            return .init(name: name, argv: [zmx.path, "attach", name] + probe.argv, cwd: directory.path,
                         env: environment, rows: 24, cols: 80)
        }

        func hasInitializationLog() -> Bool {
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return false }
            for case let file as URL in files where file.pathExtension == "log" {
                if let text = try? String(contentsOf: file, encoding: .utf8), text.contains("init resize rows=24 cols=80") { return true }
            }
            return false
        }

        func clientPhase() -> String {
            guard let clients = (try? list())?.first?.clients else { return "unknown" }
            return clients > 0 ? "client-connected" : "clientless"
        }

        func beginExchange(_ request: SessionHost.Request) throws -> PendingExchange {
            var data = try SessionHost.encodeFrame(SessionHost.Request.hello(identity))
            data.append(try SessionHost.encodeFrame(request))
            return try PendingExchange(fixture: self, data: data)
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
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw FixtureCommandError(command: command.path, status: process.terminationStatus,
                                          reason: process.terminationReason, stderr: stderr)
            }
            return output.fileHandleForReading.readDataToEndOfFile()
        }
    }

    private final class PendingExchange {
        let process = Process()
        let output: URL
        let inputHandle: FileHandle
        let outputHandle: FileHandle
        let deadline = ProcessInfo.processInfo.systemUptime + 25

        init(fixture: Fixture, data: Data) throws {
            let input = fixture.directory.appendingPathComponent("request-\(UUID().uuidString)")
            output = fixture.directory.appendingPathComponent("response-\(UUID().uuidString)")
            try data.write(to: input)
            try Data().write(to: output)
            inputHandle = try FileHandle(forReadingFrom: input)
            outputHandle = try FileHandle(forWritingTo: output)
            process.executableURL = fixture.client
            process.arguments = ["-U", fixture.paths.socket]
            process.environment = fixture.environment
            process.standardInput = inputHandle
            process.standardOutput = outputHandle
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        deinit {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? inputHandle.close()
            try? outputHandle.close()
        }

        func finish() throws -> [SessionHost.Response] {
            while process.isRunning {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    kill(process.processIdentifier, SIGKILL)
                    throw POSIXError(.ETIMEDOUT)
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return try Data(contentsOf: output).split(separator: 0x0A).map { line in
                var frame = Data(line)
                frame.append(0x0A)
                return try SessionHost.decodeFrame(SessionHost.Response.self, from: frame)
            }
        }
    }
}
