import agtermCore
import Foundation
import Observation
import UserNotifications

/// Drives the Dock icon's unseen-notification badge from the app-wide total of unseen terminal
/// notifications — the same `Session.unseenCount` the sidebar's red pills show, summed across every open
/// window by `WindowLibrary.totalUnseenCount`. Capped at 99 (mirrors the sidebar pill's `99+`), cleared at
/// zero, gated by the SAME `GhosttyApp.notificationBadgeEnabled` ("Show notification badges") Settings
/// toggle — one switch governs both surfaces.
///
/// **Uses the modern UserNotifications badge, NOT `NSApp.dockTile.badgeLabel`.** For agterm the legacy
/// dock-tile label is silently suppressed — the value sets and persists on the tile, but the Dock never
/// draws the pill — because it requires the `.badge` authorization option (which `NotificationManager` now
/// requests alongside `.alert`). `UNUserNotificationCenter.setBadgeCount(_:)` renders the count correctly
/// over the LIVE adaptive Icon Composer icon with no loss of light/dark/tint/clear adaptivity, so the badge
/// is purely the number — no self-drawn icon, no `applicationIconImage` override.
///
/// `@MainActor` singleton like `NotificationManager`. Reactivity uses the Observation re-registration
/// pattern: `apply()` reads the observable inputs inside `withObservationTracking` and re-arms itself on
/// the next change, so a notification bump, a focus/select clear, and a session add/remove all refresh the
/// badge. Changes that are NOT observable are poked explicitly: a window CLOSE drops, and a window REOPEN
/// loads, an `@ObservationIgnored` store (`refresh()` on the `willClose` teardown / `window.close`, and on
/// `ContentView.resolveStore`), and a badge-toggle flip lands in the non-`@Observable` `GhosttyApp` flag
/// (it rides `.agtermAppearanceChanged`, the same channel the sidebar uses).
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

    /// Recompute and set the badge now — the explicit poke for a change the Observation tracking can't see
    /// (a window close drops, or a reopen loads, an `@ObservationIgnored` store, leaving the tracked inputs
    /// unchanged).
    func refresh() { apply() }

    /// Zero the Dock badge immediately — called from `applicationWillTerminate`. `setBadgeCount` writes an
    /// OS-level badge that OUTLIVES the process, and `unseenCount` is ephemeral (never restored), so a quit
    /// with unseen > 0 would otherwise leave a stale count pinned on the Dock icon until the next launch
    /// recomputes it. The `willClose` `refresh()` poke can't cover this: the quit-flush sets
    /// `library.isTerminating`, so `closeWindow` no-ops and the still-open stores recompute the same
    /// positive total.
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
        // setBadgeCount(0) clears the badge; a positive count shows the OS-rendered pill over the live
        // adaptive icon (needs the `.badge` authorization `NotificationManager` requests). Capped at 99
        // to mirror the sidebar pill's `99+` ceiling (the OS renders the raw Int, so this is the cap).
        UNUserNotificationCenter.current().setBadgeCount(min(count, 99))
    }
}
