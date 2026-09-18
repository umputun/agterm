import Darwin
import Foundation
import Testing
@testable import SessionHostRuntime

struct SessionHostTrampolineTests {
    private static let probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/session-host-pty-probe").path

    @Test func outputReachesTheParentThroughThePTY() throws {
        let child = try PTYProcess.spawn(argv: [Self.probe, "args", "two words", "last"], env: [:], cwd: "/tmp", rows: 24, cols: 80)
        let result = try collect(child)
        #expect(result.output == "/private/tmp\n2\ntwo words\nlast\n")
        #expect(result.status == 0)
        #expect(result.execError == nil)
    }

    @Test func argumentsAndWorkingDirectoryReachTheChild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-host-\(UUID().uuidString)/with space")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let child = try PTYProcess.spawn(argv: [Self.probe, "args", "one argument with spaces"],
                                        env: [:], cwd: directory.path, rows: 24, cols: 80)
        let result = try collect(child)
        let lines = result.output.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        let actualCwd = try #require(lines.first)
        #expect(URL(fileURLWithPath: actualCwd).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
        #expect(Array(lines.dropFirst()) == ["1", "one argument with spaces"])
        #expect(result.status == 0)
        #expect(result.execError == nil)
    }

    @Test func environmentIsReplacedAndPreservesNewlines() throws {
        let child = try PTYProcess.spawn(argv: [Self.probe, "env"], env: ["VALUE": "first\nsecond", "OTHER": "two words"],
                                        cwd: "/tmp", rows: 24, cols: 80)
        let result = try collect(child)
        #expect(Set(result.output.split(separator: "\n")) == ["VALUE=first", "second", "OTHER=two words"])
        #expect(result.output.contains("VALUE=first\nsecond\n"))
        #expect(result.status == 0)
    }

    @Test func outputSurvivesAReaderStalledPastTheExitDrain() throws {
        let child = try PTYProcess.spawn(argv: [Self.probe, "env"], env: ["VALUE": "kept"], cwd: "/tmp", rows: 24, cols: 80)
        Thread.sleep(forTimeInterval: 1.5)
        let result = try collect(child)
        #expect(result.output == "VALUE=kept\n")
        #expect(result.status == 0)
    }

    @Test func initialWindowSizeIsAvailableBeforeExec() throws {
        let child = try PTYProcess.spawn(argv: [Self.probe, "size"], env: [:], cwd: "/tmp", rows: 37, cols: 119)
        let result = try collect(child)
        #expect(result.output == "37 119\n")
        #expect(result.status == 0)
    }

    @Test func missingExecutableReportsErrnoToTheParent() throws {
        let child = try PTYProcess.spawn(argv: ["/no/such/session-host-command"], env: [:], cwd: "/tmp", rows: 24, cols: 80)
        let result = try collect(child)
        #expect(result.execError == ENOENT)
        #expect(result.status == 127 << 8)
        #expect(result.output.isEmpty)
    }

    @Test func missingWorkingDirectoryReportsErrnoWithoutRunningTheCommand() throws {
        let child = try PTYProcess.spawn(argv: ["/bin/echo", "must not run"], env: [:],
                                        cwd: "/no/such/session-host-directory", rows: 24, cols: 80)
        let result = try collect(child)
        #expect(result.execError == ENOENT)
        #expect(result.status == 127 << 8)
        #expect(result.output.isEmpty)
    }

    @Test func returnedDescriptorsAreCloseOnExec() throws {
        let child = try PTYProcess.spawn(argv: ["/bin/sleep", "30"], env: [:], cwd: "/tmp", rows: 24, cols: 80)
        defer { dispose(child) }
        let ptyFlags = fcntl(child.ptyFD, F_GETFD)
        let errorFlags = fcntl(child.execErrorFD, F_GETFD)
        try #require(ptyFlags >= 0 && errorFlags >= 0)
        #expect(ptyFlags & FD_CLOEXEC != 0)
        #expect(errorFlags & FD_CLOEXEC != 0)
    }

    @Test func successfulExecClosesTheErrorPipeBeforeTheChildExits() throws {
        let child = try PTYProcess.spawn(argv: ["/bin/sleep", "30"], env: [:], cwd: "/tmp", rows: 24, cols: 80)
        var reaped = false
        defer { dispose(child, reap: !reaped) }
        var fd = pollfd(fd: child.execErrorFD, events: Int16(POLLIN), revents: 0)
        try #require(poll(&fd, 1, 5000) > 0)
        var error: Int32 = 0
        let count = withUnsafeMutableBytes(of: &error) { read(child.execErrorFD, $0.baseAddress, $0.count) }
        #expect(count == 0)
        var status: Int32 = 0
        let waited = waitpid(child.pid, &status, WNOHANG)
        reaped = waited == child.pid
        #expect(waited == 0)
    }

    @Test func closeOnExecHostDescriptorDoesNotReachTheExecutedChild() throws {
        let original = open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(original >= 0)
        defer { close(original) }
        let privateFD = fcntl(original, F_DUPFD_CLOEXEC, 200)
        try #require(privateFD >= 0)
        defer { close(privateFD) }
        let child = try PTYProcess.spawn(argv: [Self.probe, "fd", String(privateFD)], env: [:], cwd: "/tmp", rows: 24, cols: 80)
        let result = try collect(child)
        #expect(result.output == "closed\n")
        #expect(result.status == 0)
        #expect(fcntl(privateFD, F_GETFD) >= 0)
    }

    @Test func invalidCStringInputsAreRejectedBeforeForking() {
        #expect(throws: PTYProcess.SpawnError.invalidArguments) {
            try PTYProcess.spawn(argv: [], env: [:], cwd: "/tmp", rows: 24, cols: 80)
        }
        #expect(throws: PTYProcess.SpawnError.invalidArguments) {
            try PTYProcess.spawn(argv: ["/bin/echo", "before\0after"], env: [:], cwd: "/tmp", rows: 24, cols: 80)
        }
        #expect(throws: PTYProcess.SpawnError.invalidArguments) {
            try PTYProcess.spawn(argv: ["/bin/echo"], env: ["BAD=KEY": "value"], cwd: "/tmp", rows: 24, cols: 80)
        }
        #expect(throws: PTYProcess.SpawnError.invalidArguments) {
            try PTYProcess.spawn(argv: ["/bin/echo"], env: [:], cwd: "/tmp\0elsewhere", rows: 24, cols: 80)
        }
    }

    private struct Collected {
        let output: String
        let status: Int32
        let execError: Int32?
    }

    private func collect(_ child: PTYProcess) throws -> Collected {
        var status: Int32?
        defer { dispose(child, reap: status == nil) }
        var output = Data()
        var errorData = Data()
        var outputOpen = true
        var errorOpen = true
        var acknowledged = false
        let marker = Data("--pty-probe-end--\r\n".utf8)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && (outputOpen || errorOpen || status == nil) {
            var fds = [
                pollfd(fd: outputOpen ? child.ptyFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorOpen ? child.execErrorFD : -1, events: Int16(POLLIN), revents: 0),
            ]
            let polled = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 50) }
            if polled < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if fds[0].revents != 0 { outputOpen = try readAvailable(child.ptyFD, into: &output, pty: true) }
            if !acknowledged, let range = output.range(of: marker) {
                output.removeSubrange(range)
                acknowledged = true
                var ack: UInt8 = 0x0A
                var written: Int
                repeat { written = write(child.ptyFD, &ack, 1) } while written < 0 && errno == EINTR
                guard written == 1 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            if fds[1].revents != 0 { errorOpen = try readAvailable(child.execErrorFD, into: &errorData, pty: false) }
            if status == nil {
                var rawStatus: Int32 = 0
                let waited = waitpid(child.pid, &rawStatus, WNOHANG)
                if waited == child.pid { status = rawStatus }
                if waited < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        guard !outputOpen, !errorOpen, let status else { throw POSIXError(.ETIMEDOUT) }
        try #require(errorData.isEmpty || errorData.count == MemoryLayout<Int32>.size)
        let execError: Int32? = errorData.isEmpty ? nil : errorData.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        return Collected(output: String(decoding: output, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n"),
                         status: status, execError: execError)
    }

    private func readAvailable(_ fd: Int32, into data: inout Data, pty: Bool) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 { data.append(contentsOf: buffer.prefix(count)); return true }
        if count == 0 || (pty && errno == EIO) { return false }
        if errno == EINTR || errno == EAGAIN { return true }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func dispose(_ child: PTYProcess, reap: Bool = true) {
        close(child.ptyFD)
        close(child.execErrorFD)
        if reap {
            kill(child.pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(child.pid, &status, 0) < 0 && errno == EINTR {}
        }
    }
}
