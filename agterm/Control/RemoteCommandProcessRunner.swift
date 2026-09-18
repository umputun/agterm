import Foundation
import agtermCore

/// Runs an ssh invocation off the main actor so the UI is free while the network is slow.
///
/// The deadline is the caller's, not ssh's: `ConnectTimeout` ends at the handshake and cannot bound a
/// remote command that never returns.
struct RemoteCommandProcessRunner: RemoteCommandRunner {
    /// Grace between SIGTERM and SIGKILL, and for the output to close after exit, matching
    /// `ZmxClient.terminationGrace`.
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
        let capture: ProcessOutputCapture
        do {
            capture = try ProcessOutputCapture(attachingTo: process)
        } catch {
            return RemoteCommandResult(status: -1, stdout: "",
                                       stderr: "could not run \(executable): \(error.localizedDescription)")
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            capture.cancel()
            return RemoteCommandResult(status: -1, stdout: "",
                                       stderr: "could not run \(executable): \(error.localizedDescription)")
        }
        capture.didLaunch()

        if finished.wait(timeout: .now() + deadline) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + terminationGrace) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            capture.cancel()
            return RemoteCommandResult(status: -1, stdout: "", stderr: "the remote did not answer in time")
        }
        // stdout stays empty on a miss: the caller prefers a remote error parsed from stdout, and a partial
        // one must not replace this diagnostic
        guard let output = capture.collect(until: .now() + terminationGrace) else {
            return RemoteCommandResult(status: -1, stdout: "", stderr: "the remote command output did not close in time")
        }
        return RemoteCommandResult(status: process.terminationStatus, stdout: output.stdout, stderr: output.stderr)
    }
}
