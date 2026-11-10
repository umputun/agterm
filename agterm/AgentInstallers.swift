import Foundation

/// Shares one login-shell snapshot and keeps installation dialogs sequential, including reentry from Help.
@MainActor
enum AgentInstallers {
    private static var isRunning = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func run(
        skill: Bool, hooks: Bool,
        probe: () async -> OpenCodeEnvironmentProbe.Result? = {
            await OpenCodeEnvironmentProbe.detect(environment: ProcessInfo.processInfo.environment)
        },
        installSkill: (OpenCodeEnvironmentProbe.Result?) -> Void = { SkillInstaller.run(probe: $0) },
        installHooks: (OpenCodeEnvironmentProbe.Result?) async -> Void = { await AgentHooksInstaller.run(probe: $0) }
    ) async {
        guard skill || hooks else { return }
        if isRunning {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isRunning = true
        }
        defer {
            if waiters.isEmpty {
                isRunning = false
            } else {
                // Keep the turn reserved until the resumed request takes over.
                waiters.removeFirst().resume()
            }
        }
        let result = await probe()
        if skill { installSkill(result) }
        if hooks { await installHooks(result) }
    }
}
