import AppKit
import Foundation

/// Follows the macOS light/dark appearance for the dual `theme = light:,dark:` conditional.
///
/// The single source of truth is the APP-level `NSApplication.effectiveAppearance`, observed via KVO —
/// the same mechanism Ghostty and the AppKit community use (Apple exposes no notification API for
/// appearance; KVO is it). Two properties make it survive sleep/wake, where the old per-view
/// `viewDidChangeEffectiveAppearance` hook wedged:
///
/// - KVO fires when the property actually SETTLES, including the belated update after wake, so there is
///   no dead callback to route around (the wedge that stuck the theme on the old side).
/// - The change delivers the new value directly (`change.newValue`), so the side is never re-read at
///   receive time — no stale read. This is why we take the value from the change, not from a property
///   read inside the handler.
///
/// Deliberately NOT `AppleInterfaceStyle` (wrong under macOS "Auto" scheduled switching, and cached
/// per-process) and NOT the distributed `AppleInterfaceThemeChangedNotification` (undocumented, fires
/// before `effectiveAppearance` settles). The observer feeds the resolved side into the same
/// `.agtermSystemAppearanceChanged` channel a real flip uses, so `SettingsModel.appearanceChanged`
/// applies the follow guard, debounce, latch suppression, and zoom-preserving reload unchanged.
@MainActor
final class SystemAppearanceObserver {
    private var observation: NSKeyValueObservation?

    /// Register the observer. Idempotent — the scene `.task` runs once per window, so guard against
    /// stacking observations. `[.initial]` fires once at registration to seed the launch side (a dark
    /// launch re-sides the chrome via the zero-surface-safe reload); `[.new]` catches every later flip.
    func start() {
        guard observation == nil else { return }
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new, .initial]) { [weak self] _, change in
            // Resolve the Bool in the non-isolated KVO closure so the non-Sendable NSAppearance never
            // crosses the hop. The change carries the SETTLED value — never re-read here. KVO's handler is
            // @Sendable (no main-thread guarantee), so HOP to main rather than assert isolation — matches
            // the GhosttyCallbacks convention (`DispatchQueue.main.async`, never `assumeIsolated`).
            let isDark = change.newValue?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            DispatchQueue.main.async { self?.post(isDark: isDark) }
        }
    }

    /// Feed the resolved side into the flip pipeline — the same channel as a real appearance flip, so
    /// the follow guard, debounce, latch suppression, and zoom-preserving reload all apply unchanged.
    private func post(isDark: Bool) {
        NotificationCenter.default.post(name: .agtermSystemAppearanceChanged, object: nil,
                                        userInfo: ["isDark": isDark])
    }
}
