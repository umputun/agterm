import AgtermResponsibility
import Darwin
import Foundation
import agtermCore

final class NativeHostChild: HostChild {
    private let process: PTYProcess
    private var descriptorsOpen = true
    private var errorOpen = true
    private var errorBytes = Data()
    private var preparationFailed = false
    private(set) var hasExited = false
    var pid: Int32 { process.pid }

    init(_ process: PTYProcess) {
        self.process = process
        do {
            try hostNonblocking(process.ptyFD)
            try hostNonblocking(process.execErrorFD)
        } catch { preparationFailed = true }
    }

    deinit { closeDescriptors() }

    func poll() -> HostChildState {
        do {
            _ = try reap()
            if preparationFailed { return hasExited ? .exited : .failed }
            if descriptorsOpen {
                try drainPTY()
                try readExecError()
            }
            if hasExited { return .exited }
            return errorBytes.isEmpty ? .running : .failed
        } catch { return .failed }
    }

    func terminate(grace: TimeInterval) throws {
        defer { closeDescriptors() }
        if try reap() { return }
        if kill(pid, SIGTERM) < 0 && errno != ESRCH { throw HostFailure.system(errno) }
        if try awaitExit(until: ProcessInfo.processInfo.systemUptime + grace) { return }
        if kill(pid, SIGKILL) < 0 && errno != ESRCH { throw HostFailure.system(errno) }
        guard try awaitExit(until: ProcessInfo.processInfo.systemUptime + grace) else { throw HostFailure.cleanupIncomplete }
    }

    private func reap() throws -> Bool {
        if hasExited { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result < 0 && errno == ECHILD) {
            hasExited = true
        } else if result < 0 && errno != EINTR { throw HostFailure.system(errno) }
        return hasExited
    }

    private func awaitExit(until deadline: TimeInterval) throws -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try reap() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try reap()
    }

    private func drainPTY() throws {
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<16 {
            let count = read(process.ptyFD, &bytes, bytes.count)
            if count > 0 { continue }
            if count == 0 || errno == EIO || errno == EAGAIN { return }
            if errno != EINTR { throw HostFailure.system(errno) }
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
