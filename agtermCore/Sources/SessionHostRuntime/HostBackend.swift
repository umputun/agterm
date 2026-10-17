import AgtermResponsibility
import Darwin
import Foundation
import agtermCore

final class NativeHostChild: HostChild {
    static let settleLimit: TimeInterval = 0.25
    static let settleQuiet: TimeInterval = 0.05
    static let settleStep: TimeInterval = 0.005
    private let process: PTYProcess
    private var descriptorsOpen = true
    private var errorOpen = true
    private var errorBytes = Data()
    private var preparationFailed = false
    private var responder = DeviceAttributeResponder()
    private var pendingWrites: [UInt8] = []
    private let writePTY: (Int32, UnsafeRawPointer, Int) -> Int
    private let now: () -> TimeInterval
    private let pause: (TimeInterval) -> Void
    private let signal: (Int32, Int32) -> Int32
    private var answeredQuery = false
    private var replyWriteFailed = false
    private(set) var hasExited = false
    private var stopCauses: [String] = []
    private var outputTail = Data()
    var pid: Int32 { process.pid }

    /// Why the child is no longer running, with the end of its terminal output; nil while it runs.
    var stopReason: String? {
        var parts = stopCauses
        if errorBytes.count == MemoryLayout<Int32>.size {
            parts.append("pre-exec errno \(errorBytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })")
        }
        guard !parts.isEmpty else { return nil }
        if !outputTail.isEmpty { parts.append("output: \(String(decoding: outputTail, as: UTF8.self))") }
        return parts.joined(separator: "; ")
    }

    init(_ process: PTYProcess, writePTY: @escaping (Int32, UnsafeRawPointer, Int) -> Int = { write($0, $1, $2) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         signal: @escaping (Int32, Int32) -> Int32 = { kill($0, $1) }) {
        self.process = process
        self.writePTY = writePTY
        self.now = now
        self.pause = pause
        self.signal = signal
        do {
            try hostNonblocking(process.ptyFD)
            try hostNonblocking(process.execErrorFD)
        } catch {
            preparationFailed = true
            stopCauses.append("descriptor preparation failed: \(error)")
        }
    }

    deinit { closeDescriptors() }

    func poll() -> HostChildState {
        do {
            _ = try reap()
            if preparationFailed { return hasExited ? .exited : .failed }
            if descriptorsOpen {
                try drainPTY()
                servicePendingWrites()
                try readExecError()
            }
            if hasExited { return .exited }
            return errorBytes.isEmpty ? .running : .failed
        } catch {
            stopCauses.append("poll failed: \(error)")
            return .failed
        }
    }

    func terminate(grace: TimeInterval) throws {
        defer { closeDescriptors() }
        if try reap() { return }
        if descriptorsOpen && !preparationFailed {
            try? drainPTY()
            servicePendingWrites()
            settleAttributeReplies()
            if hasExited { return }
        }
        // a written reply can still be buffered in the attach client or socket/pty queues when sigterm prevents its delivery.
        if signal(pid, SIGTERM) < 0 && errno != ESRCH { throw HostFailure.system(errno) }
        if try awaitExit(until: ProcessInfo.processInfo.systemUptime + grace) { return }
        if signal(pid, SIGKILL) < 0 && errno != ESRCH { throw HostFailure.system(errno) }
        guard try awaitExit(until: ProcessInfo.processInfo.systemUptime + grace) else { throw HostFailure.cleanupIncomplete }
    }

    private func reap() throws -> Bool {
        if hasExited { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            hasExited = true
            stopCauses.append("exited with wait status \(status)")
        } else if result < 0 && errno == ECHILD {
            hasExited = true
            stopCauses.append("waitpid found no child")
        } else if result < 0 && errno != EINTR { throw HostFailure.system(errno) }
        return hasExited
    }

    /// An attach that never carried a DA query (every zsh creation) is signalled at once. Otherwise, or while a
    /// reply or an unfinished escape prefix (even a lone ESC) is held, the host keeps answering until replies are
    /// flushed and the PTY stays quiet: the final pass can precede a query the daemon is still forwarding.
    private func settleAttributeReplies() {
        guard answeredQuery || !pendingWrites.isEmpty || responder.holdsPartialQuery else { return }
        let limit = now() + Self.settleLimit
        var quietSince = now()
        while !replyWriteFailed && now() < limit {
            pause(Self.settleStep)
            guard (try? reap()) == false else { return }
            let produced = (try? drainPTY()) ?? false
            servicePendingWrites()
            if produced || !pendingWrites.isEmpty || responder.holdsPartialQuery {
                quietSince = now()
            } else if now() - quietSince >= Self.settleQuiet {
                return
            }
        }
    }

    private func awaitExit(until deadline: TimeInterval) throws -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try reap() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try reap()
    }

    /// True when the bytes read produced a reply.
    @discardableResult
    private func drainPTY() throws -> Bool {
        var produced = false
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<16 {
            // reserve a maximum-size reply per input byte, including a carried query prefix.
            let capacity = min(bytes.count, (64 * 1024 - pendingWrites.count) / DeviceAttributeResponder.maximumReplyLength)
            guard capacity > 0 else { return produced }
            let count = read(process.ptyFD, &bytes, capacity)
            if count > 0 {
                outputTail = (outputTail + bytes.prefix(count)).suffix(1024)
                let replies = bytes.withUnsafeBufferPointer { responder.feed(UnsafeBufferPointer(rebasing: $0.prefix(count))) }
                if !replies.isEmpty {
                    produced = true
                    answeredQuery = true
                    pendingWrites.append(contentsOf: replies)
                }
                continue
            }
            if count == 0 || errno == EIO || errno == EAGAIN { return produced }
            if errno != EINTR { throw HostFailure.system(errno) }
        }
        return produced
    }

    private func servicePendingWrites() {
        guard !hasExited else { return }
        for _ in 0..<4 {
            guard !pendingWrites.isEmpty else { return }
            let count = pendingWrites.withUnsafeBytes { writePTY(process.ptyFD, $0.baseAddress!, $0.count) }
            if count > 0 {
                pendingWrites.removeFirst(count)
                return
            }
            if count == 0 { return }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK { return }
            if !replyWriteFailed {
                replyWriteFailed = true
                try? FileHandle.standardError.write(contentsOf: Data("creation attach reply write failed: errno=\(code)\n".utf8))
            }
            return
        }
    }

    private func readExecError() throws {
        guard errorOpen else { return }
        var bytes = [UInt8](repeating: 0, count: MemoryLayout<Int32>.size)
        let count = read(process.execErrorFD, &bytes, bytes.count)
        if count > 0 {
            errorBytes.append(contentsOf: bytes.prefix(count))
        } else if count == 0 {
            errorOpen = false
        } else if errno != EAGAIN && errno != EINTR { throw HostFailure.system(errno) }
    }

    private func closeDescriptors() {
        guard descriptorsOpen else { return }
        close(process.ptyFD)
        close(process.execErrorFD)
        descriptorsOpen = false
    }
}

final class NativeHostBackend: HostBackend {
    private let zmxPath: String
    private let socketDirectory: String
    private let environment: [String: String]
    private var pendingProcesses: [Process] = []

    init(socketDirectory: String, zmxPath: String, environment: [String: String]) {
        self.socketDirectory = socketDirectory
        self.zmxPath = zmxPath
        self.environment = environment.merging(["ZMX_DIR": socketDirectory, "ZMX_SESSION": "", "ZMX_SESSION_PREFIX": ""]) { _, value in value }
    }

    func spawn(_ request: SessionHost.Ensure) throws -> any HostChild {
        try NativeHostChild(PTYProcess.spawn(argv: request.argv, env: request.env, cwd: request.cwd, rows: request.rows, cols: request.cols))
    }

    func responsibleProcess(of pid: Int32) -> Int32? { Responsibility.system.responsibleProcess(of: pid) }

    func daemonPID(for leader: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(leader, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = Int32(info.pbi_ppid)
        guard parent > 0, let path = try? HostIdentity.executablePath(pid: parent), path == HostIdentity.canonical(zmxPath) else { return nil }
        return parent
    }

    func isAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    func list(deadline: TimeInterval) throws -> [ZmxSessionRecord] {
        pendingProcesses.removeAll { !$0.isRunning }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmxPath)
        process.arguments = ["list"]
        process.currentDirectoryURL = URL(fileURLWithPath: socketDirectory)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try hostCloseOnExec(output.fileHandleForReading.fileDescriptor)
        try hostCloseOnExec(output.fileHandleForWriting.fileDescriptor)
        let fd = output.fileHandleForReading.fileDescriptor
        try hostNonblocking(fd)
        defer {
            if process.isRunning { terminateListing(process) }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try process.run()
        try output.fileHandleForWriting.close()
        var data = Data()
        var streamOpen = true
        while streamOpen || process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HostFailure.timeout }
            if !streamOpen { Thread.sleep(forTimeInterval: 0.005); continue }
            try hostWait(fd, events: Int16(POLLIN), deadline: deadline)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 1024 * 1024 else { throw HostFailure.outputTooLarge }
            } else if count == 0 {
                streamOpen = false
            } else if errno != EAGAIN && errno != EINTR { throw HostFailure.system(errno) }
        }
        guard process.terminationStatus == 0 else { throw HostFailure.invalidRequest }
        return try ZmxListParser.parse(String(decoding: data, as: UTF8.self))
    }

    private func terminateListing(_ process: Process) {
        process.terminate()
        let termDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < termDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let killDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { pendingProcesses.append(process) }
    }
}
