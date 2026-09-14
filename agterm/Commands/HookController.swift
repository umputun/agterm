import agtermCore
import Foundation

/// Owns the hook scheduler and its process launcher: feeds it every ring event through the library's
/// post-append observer, applies `hooks.conf` from the settings model on start and on every
/// `.agtermHooksChanged`, and routes the scheduler's failure sink to the notification banner.
@MainActor
final class HookController {
    let scheduler: HookScheduler
    private let settings: SettingsModel
    private var observer: NSObjectProtocol?

    init(library: WindowLibrary, settings: SettingsModel, socketProvider: @escaping () -> String) {
        self.settings = settings
        scheduler = HookScheduler(launcher: HookProcessRunner(socketProvider: socketProvider))
        scheduler.onFailure = { entry, detail in
            NotificationManager.shared.notifyHookFailure(kind: entry.kind.rawValue, command: entry.command, detail: detail)
        }
        library.onControlEvent = { [scheduler] event in scheduler.dispatch(event) }
    }

    /// Apply the current definitions and follow reloads. Idempotent: the scene `.task` fires once per window.
    func start() {
        guard observer == nil else { return }
        scheduler.apply(settings.hooks)
        observer = NotificationCenter.default.addObserver(
            forName: .agtermHooksChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private func apply() {
        scheduler.apply(settings.hooks)
    }
}
