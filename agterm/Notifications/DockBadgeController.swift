import agtermCore
import Foundation
import Observation
import UserNotifications

/// Drives the Dock icon's unseen-notification badge from the app-wide total — the same `Session.unseenCount`
/// the sidebar's red pills show, summed across open windows by `WindowLibrary.totalUnseenCount`. Capped at 99
/// (the sidebar pill's `99+`), cleared at zero, gated by the SAME `GhosttyApp.notificationBadgeEnabled`
/// ("Show notification badges") toggle as the pills.
///
/// **Uses the modern UserNotifications badge, NOT `NSApp.dockTile.badgeLabel`.** The legacy dock-tile label
/// is silently suppressed for agterm — the value sets and persists on the tile, but the Dock never draws the
/// pill — because it requires the `.badge` authorization option (`NotificationManager` requests it alongside
/// `.alert`). `UNUserNotificationCenter.setBadgeCount(_:)` renders the count over the LIVE adaptive Icon
/// Composer icon with no loss of light/dark/tint/clear adaptivity, so the badge is purely the number — no
/// self-drawn icon, no `applicationIconImage` override.
///
/// `@MainActor` singleton like `NotificationManager`. Reactivity uses the Observation re-registration
/// pattern: `apply()` reads the observable inputs inside `withObservationTracking` and re-arms on the next
/// change, so a notification bump, a focus/select clear, and a session add/remove all refresh. Non-observable
/// changes are poked explicitly — a window CLOSE drops, and a REOPEN loads, an `@ObservationIgnored` store
/// (`refresh()` from the `willClose` teardown / `window.close`, and from `ContentView.resolveStore`), and a
/// badge-toggle flip lands in the non-`@Observable` `GhosttyApp` flag, riding `.agtermAppearanceChanged` like
/// the sidebar.
@MainActor
final class DockBadgeController {
    static let shared = DockBadgeController()

    /// The window library whose open sessions' unseen counts are summed. Weak, set at launch by
    /// `agtermApp`; the library outlives the controller by app lifetime, matching `NotificationManager`.
    weak var library: WindowLibrary?

    /// The appearance-notification token, installed once so a badge-toggle flip refreshes the Dock badge.
    private var appearanceObserver: NSObjectProtocol?

    /// Coalesces the deferred re-applies an observation change schedules into one per runloop turn.
    private var refreshScheduled = false

    /// Begin driving the Dock badge. Idempotent — re-running just re-applies (the appearance observer is
    /// installed once). Called from the scene `.task` alongside `NotificationManager.shared.start()`.
    func start() {
        if appearanceObserver == nil {
            appearanceObserver = NotificationCenter.default.addObserver(
                forName: .agtermAppearanceChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
        apply()
    }

    /// Recompute and set the badge now — the explicit poke for a change Observation can't see (a window close
    /// drops, or a reopen loads, an `@ObservationIgnored` store, leaving the tracked inputs unchanged).
    func refresh() { apply() }

    /// Zero the Dock badge immediately, from `applicationWillTerminate`. `setBadgeCount` writes an OS-level
    /// badge that OUTLIVES the process while `unseenCount` is ephemeral (never restored), so a quit with
    /// unseen > 0 would pin a stale count on the Dock icon until the next launch recomputes it. The
    /// `willClose` `refresh()` poke can't cover it: the quit-flush sets `library.isTerminating`, so
    /// `closeWindow` no-ops and the still-open stores recompute the same positive total.
    func clear() { UNUserNotificationCenter.current().setBadgeCount(0) }

    /// Defer a single re-apply to the next runloop turn. An observation `onChange` fires at willSet (before
    /// the new value is readable) and may fire from several live trackers at once, so this coalesces them
    /// into one read-and-set after the mutation has landed.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.apply()
        }
    }

    /// Read the observable inputs, set the Dock badge count, and re-arm tracking so the next change
    /// re-fires. `GhosttyApp.notificationBadgeEnabled` is read but NOT `@Observable`, so its flips don't
    /// re-arm here — they come through `start()`'s `.agtermAppearanceChanged` observer instead.
    private func apply() {
        let count = withObservationTracking { () -> Int in
            guard GhosttyApp.shared.notificationBadgeEnabled else { return 0 }
            return self.library?.totalUnseenCount ?? 0
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleRefresh() } }
        }
        // capped at 99 to mirror the sidebar pill's `99+` ceiling — the OS renders the raw Int.
        UNUserNotificationCenter.current().setBadgeCount(min(count, 99))
    }
}
