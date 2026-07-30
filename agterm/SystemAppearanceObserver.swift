import AppKit
import Foundation

/// Follows the macOS light/dark appearance for the dual `theme = light:,dark:` conditional.
///
/// The single source of truth is the APP-level `NSApplication.effectiveAppearance`, observed via KVO —
/// what Ghostty and the AppKit community use, since Apple exposes no notification API for appearance.
/// Two properties make it survive sleep/wake, where the old per-view `viewDidChangeEffectiveAppearance`
/// hook wedged and stuck the theme on the old side: KVO fires when the property actually SETTLES,
/// including the belated update after wake, so there is no dead callback to route around; and the change
/// carries the new value (`change.newValue`), so the side is never re-read at receive time — take it from
/// the change, never from a property read inside the handler.
///
/// Deliberately NOT `AppleInterfaceStyle` (wrong under macOS "Auto" scheduled switching, and cached
/// per-process) nor the distributed `AppleInterfaceThemeChangedNotification` (undocumented, fires before
/// `effectiveAppearance` settles). The resolved side goes into the same `.agtermSystemAppearanceChanged`
/// channel a real flip uses, so `SettingsModel.appearanceChanged` applies the follow guard, debounce,
/// latch suppression, and zoom-preserving reload unchanged.
@MainActor
final class SystemAppearanceObserver {
    private var observation: NSKeyValueObservation?

    /// Register the observer. Idempotent — the scene `.task` runs once per window, so guard against
    /// stacking observations. `[.initial]` fires once at registration to seed the launch side (a dark
    /// launch re-sides the chrome via the zero-surface-safe reload); `[.new]` catches every later flip.
    func start() {
        guard observation == nil else { return }
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new, .initial]) { [weak self] _, change in
            // resolve the Bool inside the non-isolated KVO closure so the non-Sendable NSAppearance never
            // crosses the hop; the change carries the SETTLED value, never re-read here. The @Sendable
            // handler has no main-thread guarantee, so HOP to main rather than assert isolation — the
            // GhosttyCallbacks convention (`DispatchQueue.main.async`, never `assumeIsolated`).
            let isDark = change.newValue?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            DispatchQueue.main.async { self?.post(isDark: isDark) }
        }
    }

    /// Feed the resolved side into the same `.agtermSystemAppearanceChanged` channel a real flip uses.
    private func post(isDark: Bool) {
        NotificationCenter.default.post(name: .agtermSystemAppearanceChanged, object: nil,
                                        userInfo: ["isDark": isDark])
    }
}
