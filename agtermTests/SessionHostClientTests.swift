import Darwin
import XCTest
import AgtermResponsibility
import agtermCore

final class SessionHostClientTests: XCTestCase {
    func testClientWithLoginArgvCreatesDisclaimedHostInPaneDirectory() throws {
        try XCTSkipUnless(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let baseline = try XCTUnwrap(Responsibility.system.responsibleProcess(of: getpid()))
        XCTAssertGreaterThan(baseline, 0)
        try fixture.startClient(name: fixture.names[0], loginArgv: true)
        let roots = try fixture.waitForLeaders(count: 1)
        let host = try fixture.hostPID()
        XCTAssertEqual(Responsibility.system.responsibleProcess(of: host), host)
        XCTAssertEqual(roots, [host])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.socket))
    }

    func testTwoRacingClientsUseOneRoot() throws {
        try XCTSkipUnless(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.startClient(name: fixture.names[0])
        try fixture.startClient(name: fixture.names[1])
        let roots = try fixture.waitForLeaders(count: 2)
        let host = try fixture.hostPID()
        XCTAssertEqual(roots, [host, host])
        XCTAssertEqual(Responsibility.system.responsibleProcess(of: host), host)
        let statBefore = try fixture.lockInode()
        try fixture.startClient(name: fixture.names[0])
        try fixture.waitForClients()
        XCTAssertEqual(try fixture.hostPID(), host)
        XCTAssertEqual(try fixture.lockInode(), statBefore)
    }

    func testLockedOwnerWithoutListenerIsLeftAlone() throws {
        try XCTSkipUnless(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let owner = open(fixture.paths.ownerLock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(owner, 0)
        guard owner >= 0 else { return }
        defer { close(owner) }
        XCTAssertEqual(flock(owner, LOCK_EX | LOCK_NB), 0)
        try "2147483647\n".write(toFile: fixture.paths.pidfile, atomically: false, encoding: .utf8)
        let start = ProcessInfo.processInfo.systemUptime
        try fixture.startClient(name: fixture.names[0])
        try fixture.waitForClients()
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 4.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.socket))
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.pidfile, encoding: .utf8), "2147483647\n")
        XCTAssertEqual(flock(owner, LOCK_EX | LOCK_NB), 0)
    }

    func testDeadPidfileDoesNotPreventFreshHost() throws {
        try XCTSkipUnless(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try "2147483647\n".write(toFile: fixture.paths.pidfile, atomically: false, encoding: .utf8)
        try fixture.startClient(name: fixture.names[0])
        let roots = try fixture.waitForLeaders(count: 1)
        let host = try fixture.hostPID()
        XCTAssertEqual(roots, [host])
        XCTAssertNotEqual(host, 2147483647)
    }

    func testClientQueuedBehindStalledPeersStillJoinsTheHost() throws {
        try XCTSkipUnless(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.startClient(name: fixture.names[0], terminal: true)
        _ = try fixture.waitForLeaders(count: 1)
        let host = try fixture.hostPID()
        let stalls = [try fixture.connectRaw(), try fixture.connectRaw()]
        defer { for fd in stalls { close(fd) } }
        let start = Date()
        try fixture.startClient(name: fixture.names[1], terminal: true)
        let roots = try fixture.waitForLeaders(count: 2)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(roots, [host, host])
        XCTAssertEqual(try fixture.hostPID(), host)
    }

    func testClientWaitingOnSpawnLockJoinsAHostPublishedMeanwhile() throws {
        try XCTSkipUnless(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let spawnLock = open(fixture.paths.spawnLock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(spawnLock, 0)
        guard spawnLock >= 0 else { return }
        defer { close(spawnLock) }
        XCTAssertEqual(flock(spawnLock, LOCK_EX | LOCK_NB), 0)
        try fixture.startClient(name: fixture.names[0], terminal: true)
        Thread.sleep(forTimeInterval: 0.5)
        let host = try Responsibility.system.spawnDisclaimed(
            executable: fixture.executable.path,
            argv: [fixture.executable.path, "host", try XCTUnwrap(fixture.environment["ZMX_DIR"])], env: fixture.environment)
        defer {
            kill(host, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(host, &status, 0)
        }
        let roots = try fixture.waitForLeaders(count: 1)
        XCTAssertEqual(roots, [host])
        XCTAssertEqual(try fixture.hostPID(), host)
        XCTAssertEqual(flock(spawnLock, LOCK_UN), 0)
    }

    func testClientCapturesPaneEnvironmentDirectoryAndTerminalSize() throws {
        try XCTSkipUnless(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let command = ["/bin/sh", "-c", "printf '%s\\n' \"$PWD\" \"$CLIENT_MARKER\" > \"$HOME/capture\"; stty size >> \"$HOME/capture\"; exec /bin/sh"]
        try fixture.startClient(name: fixture.names[0], command: command, terminal: true)
        _ = try fixture.waitForLeaders(count: 1)
        let marker = fixture.directory.appendingPathComponent("capture")
        let physicalPath = try XCTUnwrap(realpath(fixture.directory.path, nil))
        defer { free(physicalPath) }
        let expected = "\(String(cString: physicalPath))\nunique pane value\n43 132\n"
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (try? String(contentsOf: marker, encoding: .utf8)) == expected { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), expected)
    }

    final class Fixture {
        let directory = URL(fileURLWithPath: "/tmp/shc-\(UUID().uuidString)")
        let names = ["agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "agterm-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]
        let executable: URL
        let zmx: URL
        let paths: SessionHost.Paths
        let environment: [String: String]
        var clients: [Int32] = []
        var terminals: [Int32] = []

        init() throws {
            let bundle = directory.appendingPathComponent("Client.app")
            executable = bundle.appendingPathComponent("Contents/MacOS/agterm-session-host")
            zmx = bundle.appendingPathComponent("Contents/MacOS/zmx")
            let socketDir = directory.appendingPathComponent("pane").path
            paths = try SessionHost.paths(socketDirectory: socketDir)
            environment = ["ZMX_DIR": socketDir, "ZMX_SESSION": "", "ZMX_SESSION_PREFIX": "", "ZMX_NO_DETACH_KEY": "1",
                           "SHELL": "/bin/sh", "HOME": directory.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "CLIENT_MARKER": "unique pane value"]
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agterm-session-host"), to: executable)
            try FileManager.default.copyItem(at: repo.appendingPathComponent("agterm/Resources/zmx/zmx"), to: zmx)
            let info = ["CFBundleIdentifier": "com.umputun.clienttest.\(UUID().uuidString)", "CFBundleExecutable": "agterm-session-host"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: paths.ownerLock).deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        func startClient(name: String, loginArgv: Bool = false, command: [String] = [], terminal: Bool = false, mediated: Bool = true) throws {
            let program = mediated ? executable.path : zmx.path
            let prefix = mediated ? [loginArgv ? "-agterm-session-host" : executable.path, "client", name, "--"] : []
            let arguments = prefix + [zmx.path, "attach", name] + command
            let argv = arguments.map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { for value in argv + envp { free(value) } }
            var actions: posix_spawn_file_actions_t?
            XCTAssertEqual(posix_spawn_file_actions_init(&actions), 0)
            defer { posix_spawn_file_actions_destroy(&actions) }
            var terminalFD: Int32 = -1
            defer { if terminalFD >= 0 { close(terminalFD) } }
            if terminal {
                var pty: Int32 = -1
                var size = winsize(ws_row: 43, ws_col: 132, ws_xpixel: 0, ws_ypixel: 0)
                guard openpty(&pty, &terminalFD, nil, nil, &size) == 0 else { throw POSIXError(.EIO) }
                terminals.append(pty)
                XCTAssertEqual(fcntl(pty, F_SETFD, FD_CLOEXEC), 0)
                XCTAssertEqual(fcntl(terminalFD, F_SETFD, FD_CLOEXEC), 0)
            }
            for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
                if terminal {
                    XCTAssertEqual(posix_spawn_file_actions_adddup2(&actions, terminalFD, fd), 0)
                } else {
                    XCTAssertEqual(posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0), 0)
                }
            }
            XCTAssertEqual(posix_spawn_file_actions_addchdir_np(&actions, directory.path), 0)
            var pid: Int32 = 0
            let result = argv.withUnsafeBufferPointer { arguments in
                envp.withUnsafeBufferPointer { environment in
                    posix_spawn(&pid, program, &actions, nil, arguments.baseAddress, environment.baseAddress)
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
            clients.append(pid)
        }

        func hostPID() throws -> Int32 {
            let value = try String(contentsOfFile: paths.pidfile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            return try XCTUnwrap(Int32(value))
        }

        func connectRaw() throws -> Int32 {
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

        func lockInode() throws -> ino_t {
            var info = stat()
            guard stat(paths.ownerLock, &info) == 0 else { throw POSIXError(.ENOENT) }
            return info.st_ino
        }

        func waitForLeaders(count: Int) throws -> [Int32] {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let records = try ZmxListParser.parse(runZmx(["list"]))
                if records.count == count {
                    let roots = records.compactMap { $0.leaderPID }.compactMap { Responsibility.system.responsibleProcess(of: $0) }
                    if roots.count == count { return roots }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw POSIXError(.ETIMEDOUT)
        }

        func waitForClients() throws {
            let deadline = Date().addingTimeInterval(10)
            while !clients.isEmpty && Date() < deadline {
                clients.removeAll { pid in
                    var status: Int32 = 0
                    return waitpid(pid, &status, WNOHANG) == pid
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertTrue(clients.isEmpty)
        }

        func cleanup() {
            for pid in clients { kill(pid, SIGKILL); var status: Int32 = 0; _ = waitpid(pid, &status, 0) }
            for name in names { _ = try? runZmx(["kill", name, "--force"]) }
            for fd in terminals { close(fd) }
            if let value = try? String(contentsOfFile: paths.pidfile, encoding: .utf8),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
               let actualPath = try? executablePath(pid), let physicalPath = realpath(executable.path, nil) {
                defer { free(physicalPath) }
                XCTAssertEqual(actualPath, String(cString: physicalPath))
                guard actualPath == String(cString: physicalPath) else { return }
                kill(pid, SIGKILL)
                let deadline = Date().addingTimeInterval(3)
                while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                XCTAssertEqual(kill(pid, 0), -1)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        private func executablePath(_ pid: Int32) throws -> String {
            var bytes = [UInt8](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { throw POSIXError(.ESRCH) }
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }

        private func runZmx(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = zmx
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw POSIXError(.ETIMEDOUT) }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
    }
}
