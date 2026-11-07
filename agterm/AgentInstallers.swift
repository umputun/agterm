import Foundation

/// Shares one login-shell snapshot and keeps installation dialogs sequential, including reentry from Help.
@MainActor
enum AgentInstallers {
    private static var isRunning = false

    static func run(
        skill: Bool, hooks: Bool,
        probe: () async -> OpenCodeEnvironmentProbe.Result? = {
            await OpenCodeEnvironmentProbe.detect(environment: ProcessInfo.processInfo.environment)
        },
        installSkill: (OpenCodeEnvironmentProbe.Result?) -> Void = { SkillInstaller.run(probe: $0) },
        installHooks: (OpenCodeEnvironmentProbe.Result?) async -> Void = { await AgentHooksInstaller.run(probe: $0) }
    ) async {
        guard skill || hooks, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let result = await probe()
        if skill { installSkill(result) }
        if hooks { await installHooks(result) }
    }
}
