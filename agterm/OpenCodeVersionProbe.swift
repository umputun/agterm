import Foundation
import agtermCore

enum OpenCodeVersionProbe {
    static func detect(environment: [String: String], timeout: TimeInterval = 3,
                       executableURL: URL? = nil) async -> AgentHooksInstall.OpenCode.Version? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: run(environment: environment, timeout: timeout, executableURL: executableURL))
            }
        }
    }

    private static func run(environment: [String: String], timeout: TimeInterval,
                            executableURL: URL?) -> AgentHooksInstall.OpenCode.Version? {
        var environment = environment
        environment["PATH"] = CommandPath.widened(environment["PATH"], bundledCLIDirectory: nil)
        environment.removeValue(forKey: "AGTERM_SESSION_ID")
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "agterm-opencode-version-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = executableURL ?? URL(fileURLWithPath: shell)
        // Startup output must not be parsed as the command's version, even if the shell exits early.
        process.arguments = ["-ilc", "/usr/bin/printf '\\n\(marker)\\n'; exec /usr/bin/env opencode --version"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        guard let capture = try? ProcessOutputCapture(attachingTo: process) else { return nil }
        defer { capture.cancel() }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { @Sendable _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        capture.didLaunch()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + ProcessOutputCapture.terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            return nil
        }
        guard process.terminationStatus == 0,
              let output = capture.collect(until: .now() + ProcessOutputCapture.terminationGrace),
              let boundary = output.stdout.range(of: "\n\(marker)\n") else { return nil }
        return AgentHooksInstall.OpenCode.Version(versionOutput: String(output.stdout[boundary.upperBound...]))
    }
}
