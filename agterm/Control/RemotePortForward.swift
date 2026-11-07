import Darwin
import Foundation
import agtermCore

/// PageForward is the port forward a forwarded page holds for as long as it is shown.
@MainActor
protocol PageForward: AnyObject {
    func start()
    func stop()
}

extension PooledForward: PageForward {}

/// RemoteForwardProcess is a running ssh forward; terminating it removes its listener.
protocol RemoteForwardProcess: AnyObject {
    func terminate()
}

/// RemoteForwardLauncher starts a forward's ssh. `onExit` runs once, with what the process wrote to stderr, when it
/// ends by itself.
@MainActor
protocol RemoteForwardLauncher {
    func launch(_ argv: [String], onExit: @escaping @MainActor (String) -> Void) throws -> RemoteForwardProcess
}

/// RemotePortForward is a forward of its own for a row with no pooled master: one ssh process holds the listener,
/// which is ready once it accepts a connection and gone once the process ends.
@MainActor
final class RemotePortForward: PageForward {
    private let argv: [String]
    private let host: String
    private let port: Int
    private let launcher: RemoteForwardLauncher
    private let timeout: Duration
    private let onEvent: @MainActor (PortForwardEvent) -> Void
    private var process: RemoteForwardProcess?
    private var probe: Task<Void, Never>?
    private var ready = false
    private var stopped = false

    /// `host` and `port` are the local listener the probe connects to.
    init(argv: [String], host: String, port: Int, launcher: RemoteForwardLauncher, timeout: Duration = .seconds(15),
         onEvent: @escaping @MainActor (PortForwardEvent) -> Void) {
        self.argv = argv
        self.host = host
        self.port = port
        self.launcher = launcher
        self.timeout = timeout
        self.onEvent = onEvent
    }

    func start() {
        do {
            process = try launcher.launch(argv) { [weak self] errors in self?.exited(errors) }
        } catch {
            return fail("the port forward could not start: \(error.localizedDescription)")
        }
        probe = Task { [weak self, host, port, timeout] in
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if Task.isCancelled { return }
                if Self.accepts(host: host, port: port) {
                    self?.becameReady()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.fail("the port forward did not come up")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        probe?.cancel()
        process?.terminate()
        process = nil
    }

    private func becameReady() {
        guard !stopped, !ready else { return }
        ready = true
        onEvent(.ready)
    }

    private func exited(_ errors: String) {
        process = nil
        let detail = errors.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
        fail("the port forward ended" + (detail.map { ": " + $0 } ?? ""))
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        stop()
        onEvent(.failed(reason))
    }

    /// accepts reports whether something listens at `host`:`port` on this Mac.
    nonisolated static func accepts(host: String, port: Int) -> Bool {
        let family = host == "::1" ? AF_INET6 : AF_INET
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withLoopback(family: family, port: port) { address, length in connect(fd, address, length) == 0 }
    }

    /// freePort is a port nothing listens on at the loopback address `host` binds, nil when none can be had. Another
    /// process can take it before ssh binds it, which ExitOnForwardFailure turns into the forward's failure.
    nonisolated static func freePort(host: String) -> Int? {
        let family = host == "::1" ? AF_INET6 : AF_INET
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let bound = withLoopback(family: family, port: 0) { address, length in bind(fd, address, length) == 0 }
        guard bound else { return nil }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        guard named else { return nil }
        let port = withUnsafePointer(to: &storage) { pointer -> UInt16 in
            family == AF_INET6
                ? pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port }
                : pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port }
        }
        return Int(UInt16(bigEndian: port))
    }

    private nonisolated static func withLoopback(family: Int32, port: Int,
                                                 _ body: (UnsafePointer<sockaddr>, socklen_t) -> Bool) -> Bool {
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(port).bigEndian
            address.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}

/// RemoteForwardProcessLauncher runs the forward's ssh as a child, resolving `ssh` through PATH as the other remote
/// commands do. Its stderr is read while it runs, since a forward that keeps failing connections writes enough to
/// fill the pipe and stall ssh, and only the last `tailBytes` are kept for the failure it reports.
struct RemoteForwardProcessLauncher: RemoteForwardLauncher {
    nonisolated static let tailBytes = 4096

    func launch(_ argv: [String], onExit: @escaping @MainActor (String) -> Void) throws -> RemoteForwardProcess {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let handle = ForwardProcess(process: process)
        let drained = DispatchSemaphore(value: 0)
        let reader = errors.fileHandleForReading
        reader.readabilityHandler = { file in
            let data = file.availableData
            guard data.isEmpty else { return handle.keep(data) }
            file.readabilityHandler = nil
            drained.signal()
        }
        process.terminationHandler = { process in
            // a ProxyCommand child can keep stderr open after ssh exits, so the reader gets a moment and is then stopped
            _ = drained.wait(timeout: .now() + 0.3)
            let text = handle.finish()
            reader.readabilityHandler = nil
            process.terminationHandler = nil
            Task { @MainActor in
                guard !handle.terminated else { return }
                onExit(text)
            }
        }
        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            process.terminationHandler = nil
            throw error
        }
        return handle
    }

    private final class ForwardProcess: RemoteForwardProcess, @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var ended = false
        // the reader's appends and the exit's snapshot run on one queue, so the snapshot sees every earlier chunk
        private let order = DispatchQueue(label: "agterm.forward.stderr.tail")
        private var kept = Data()
        private var finished = false

        init(process: Process) { self.process = process }

        var terminated: Bool { lock.withLock { ended } }

        func keep(_ data: Data) {
            order.sync {
                guard !finished else { return }
                kept.append(data)
                if kept.count > RemoteForwardProcessLauncher.tailBytes { kept = kept.suffix(RemoteForwardProcessLauncher.tailBytes) }
            }
        }

        /// finish returns the kept tail and drops whatever the reader takes after it.
        func finish() -> String {
            order.sync {
                finished = true
                return String(decoding: kept, as: UTF8.self)
            }
        }

        func terminate() {
            lock.withLock { ended = true }
            if process.isRunning { process.terminate() }
        }
    }
}
