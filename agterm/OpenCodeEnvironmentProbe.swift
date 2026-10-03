import Foundation
import agtermCore

enum OpenCodeEnvironmentProbe {
    struct Result: Sendable {
        let version: AgentHooksInstall.OpenCode.Version?
        let v2ConfigurationDirectory: String?
    }

    static func detect(environment: [String: String], timeout: TimeInterval = 3,
                       executableURL: URL? = nil) async -> Result? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: run(environment: environment, timeout: timeout, executableURL: executableURL))
            }
        }
    }

    private static func run(environment: [String: String], timeout: TimeInterval,
                            executableURL: URL?) -> Result? {
        var environment = environment
        environment["PATH"] = CommandPath.widened(environment["PATH"], bundledCLIDirectory: nil)
        environment.removeValue(forKey: "AGTERM_SESSION_ID")
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "agterm-opencode-version-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = executableURL ?? URL(fileURLWithPath: shell)
        // A POSIX hop reads only exported values, including fish's, before the version command can fail.
        let command = "/usr/bin/printf '\\n\(marker)\\n%s\\000%s\\000%s\\000%s\\000%s\\000' "
            + "\"$HOME\" \"$PWD\" \"${OPENCODE_CONFIG_DIR+x}\" \"${OPENCODE_CONFIG_DIR-}\" \"${XDG_CONFIG_HOME-}\"; "
            + "exec /usr/bin/env opencode --version"
        process.arguments = ["-ilc", "exec /bin/sh -c " + CommandRestore.shellQuotedLine([command])]
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
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + ProcessOutputCapture.terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        guard let output = capture.collect(until: .now() + ProcessOutputCapture.terminationGrace),
              let boundary = output.stdout.range(of: "\n\(marker)\n") else { return nil }
        let fields = output.stdout[boundary.upperBound...].split(separator: "\0", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6 else { return nil }
        let home = fields[0].isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : fields[0]
        return Result(
            version: !timedOut && process.terminationStatus == 0 ? AgentHooksInstall.OpenCode.Version(versionOutput: fields[5]) : nil,
            v2ConfigurationDirectory: AgentHooksInstall.OpenCode.configurationDirectory(
                home: home, opencodeConfigDirectory: fields[2].isEmpty ? nil : fields[3],
                xdgConfigHome: fields[4], workingDirectory: fields[1]
            )
        )
    }
}
