import agtermCore
import Foundation
import os

private let logger = Logger(subsystem: "com.umputun.agterm", category: "HookProcessRunner")

/// The app-side `HookLauncher`. Two constraints carry the contract: the write end of the stdin pipe is
/// owned by one `DispatchIO` channel and closed only by its cleanup handler, and `onExit` is delivered
/// only once the child has terminated AND that cleanup has run, so no input channel outlives the run it
/// belongs to.
@MainActor
final class HookProcessRunner: HookLauncher {
    struct LaunchError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private let socketProvider: () -> String
    private let executableURL: URL
    private let encode: @Sendable (ControlEvent) throws -> Data
    private let queue = DispatchQueue(label: "com.umputun.agterm.hooks", qos: .utility)

    /// `executableURL` and `encode` are injection points for the hosted tests (a missing shell, a failing
    /// encoder); production uses `/bin/sh` and a plain `JSONEncoder`.
    init(socketProvider: @escaping () -> String,
         executableURL: URL = URL(fileURLWithPath: "/bin/sh"),
         encode: @escaping @Sendable (ControlEvent) throws -> Data = { try JSONEncoder().encode($0) }) {
        self.socketProvider = socketProvider
        self.executableURL = executableURL
        self.encode = encode
    }

    func launch(entry: HookEntry, event: ControlEvent,
                onDeliveryFailure: @escaping @MainActor @Sendable (String) -> Void,
                onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws -> Int32 {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw LaunchError(detail: "pipe: \(String(cString: strerror(errno)))") }
        let readFD = fds[0]
        let writeFD = fds[1]
        // a script that exits without reading turns the write into EPIPE instead of a SIGPIPE that would
        // kill the app; the flag is per descriptor, so it is set here rather than process-wide.
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0 else {
            let message = String(cString: strerror(errno))
            close(readFD)
            close(writeFD)
            throw LaunchError(detail: "F_SETNOSIGPIPE: \(message)")
        }
        let state = LaunchState(onExit: onExit)
        // both dispatch callbacks are declared @Sendable: written inside a @MainActor method they would
        // otherwise inherit main-actor isolation, and libdispatch running them on `queue` trips the runtime's
        // executor assertion (EXC_BREAKPOINT in dispatch_assert_queue).
        let cleanup: @Sendable (Int32) -> Void = { _ in
            close(writeFD)
            state.cleanedUp = true
            state.finishIfDone()
        }
        let channel = DispatchIO(type: .stream, fileDescriptor: writeFD, queue: queue, cleanupHandler: cleanup)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-c", entry.command]
        process.environment = environment(for: event)
        process.standardInput = FileHandle(fileDescriptor: readFD, closeOnDealloc: false)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [queue] proc in
            let status = proc.terminationStatus
            queue.async {
                state.exitStatus = status
                // .stop cancels a write still blocked on a full pipe; the cleanup handler then closes the fd
                // and is what completes the run.
                channel.close(flags: .stop)
                state.finishIfDone()
            }
        }
        do {
            try process.run()
        } catch {
            close(readFD)
            channel.close()
            throw LaunchError(detail: error.localizedDescription)
        }
        // the child holds its own copy; keeping ours open would keep the pipe alive past the child's exit.
        close(readFD)

        let encode = encode
        let queue = queue
        queue.async {
            guard state.exitStatus == nil else { return }
            let data: Data
            do {
                data = try encode(event) + Data("\n".utf8)
            } catch {
                Task { @MainActor in onDeliveryFailure("encode: \(error.localizedDescription)") }
                channel.close()
                return
            }
            let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
            channel.write(offset: 0, data: payload, queue: queue) { @Sendable done, _, error in
                if error != 0, error != EPIPE, error != ECANCELED {
                    let message = String(cString: strerror(error))
                    Task { @MainActor in onDeliveryFailure(message) }
                }
                // a normal close delivers EOF once the queued data has drained; an error or cancel closes too.
                if done { channel.close() }
            }
        }
        return process.processIdentifier
    }

    /// Every fixed variable is set explicitly, empty when the event lacks the field, so an inherited value
    /// can never point a script at the wrong session.
    private func environment(for event: ControlEvent) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["AGT_EVENT_KIND"] = event.kind.rawValue
        environment["AGT_EVENT_STATUS"] = event.payload.status ?? ""
        environment["AGT_SESSION_ID"] = event.session ?? ""
        environment["AGT_WORKSPACE_ID"] = event.workspace ?? ""
        environment["AGT_WINDOW_ID"] = event.window ?? ""
        environment["AGT_SOCKET"] = socketProvider()
        environment["PATH"] = CommandPath.widened(environment["PATH"],
                                                  bundledCLIDirectory: CLIInstaller.bundledTool?
                                                      .deletingLastPathComponent().path)
        return environment
    }
}

/// Per-launch state touched only on the runner's serial queue (the termination job, the encoding job and
/// the channel's handlers all run there), which is what makes the unchecked conformance sound. `onExit`
/// fires once, when both the exit status and the channel cleanup are in.
private final class LaunchState: @unchecked Sendable {
    var exitStatus: Int32?
    var cleanedUp = false
    private var delivered = false
    private let onExit: @MainActor @Sendable (Int32) -> Void

    init(onExit: @escaping @MainActor @Sendable (Int32) -> Void) {
        self.onExit = onExit
    }

    func finishIfDone() {
        guard let status = exitStatus, cleanedUp, !delivered else { return }
        delivered = true
        let onExit = onExit
        Task { @MainActor in onExit(status) }
    }
}
