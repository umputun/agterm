import Foundation
import agtermCore

/// Runs an ssh invocation off the main actor so the UI is free while the network is slow.
///
/// The deadline is the caller's, not ssh's: `ConnectTimeout` ends at the handshake and cannot bound a
/// remote command that never returns.
struct RemoteCommandProcessRunner: RemoteCommandRunner {
    /// Grace between SIGTERM and SIGKILL, matching `ZmxClient.terminationGrace`.
    private static let terminationGrace: TimeInterval = 0.25

    func run(_ argv: [String], deadline: TimeInterval) async -> RemoteCommandResult {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: Self.execute(argv, deadline: deadline))
            }
        }
    }

    private static func execute(_ argv: [String], deadline: TimeInterval) -> RemoteCommandResult {
        guard let executable = argv.first else {
            return RemoteCommandResult(status: -1, stdout: "", stderr: "no command to run")
        }
        let process = Process()
        // env resolves `ssh` through PATH, so a user who put their own ahead of /usr/bin keeps it
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return RemoteCommandResult(status: -1, stdout: "",
                                       stderr: "could not run \(executable): \(error.localizedDescription)")
        }

        // both pipes drain on their own threads while this one holds the deadline. Reading here instead
        // would make the deadline unreachable — `readDataToEndOfFile` returns only once the child closes
        // the pipe — and reading them in sequence deadlocks the moment the child fills the other one.
        let stdoutSink = Sink(output.fileHandleForReading)
        let stderrSink = Sink(errors.fileHandleForReading)
        let timedOut = finished.wait(timeout: .now() + deadline) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + terminationGrace) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        // joined after the process is gone, so its pipes are closed and the sinks have seen EOF: returning
        // on the semaphore alone can beat the tail of the output out of the pipe.
        let stdout = stdoutSink.wait()
        let stderr = stderrSink.wait()
        guard !timedOut else {
            return RemoteCommandResult(status: -1, stdout: "", stderr: "the remote did not answer in time")
        }
        return RemoteCommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// One pipe drained to EOF on its own thread. Each sink owns its storage outright, so the two never
    /// share state and the only synchronisation is the join.
    private final class Sink: @unchecked Sendable {
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            Thread.detachNewThread { [self] in
                data = handle.readDataToEndOfFile()
                done.signal()
            }
        }

        func wait() -> String {
            done.wait()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
