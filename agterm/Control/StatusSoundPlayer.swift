import AppKit
import agtermCore

/// StatusSoundPlayer plays the one-shot sound requested by `session.status --sound`. It is a thin AppKit
/// wrapper over `NSSound`: a shared `@MainActor` singleton used by `ControlServer` (the per-call and
/// blocked-default status sounds) and by the Settings sound pickers' selection previews.
///
/// `action(for:)` resolves a sound name to its play closure (or nil when a named sound can't be found),
/// so the caller can validate before mutating the indicator and surface an `unknown sound` error. The
/// `default`/`beep` value maps to the system alert sound; any other value is a named system sound via
/// `NSSound(named:)`, which also resolves custom sounds in `~/Library/Sounds`. `play(_:)` resolves AND
/// plays, but de-bounces a replay of the same sound within a short window (`SoundThrottle`) so a burst of
/// rapid status sets can't machine-gun an identical clip.
///
/// Resolved `NSSound` instances are cached and thus retained for the app's lifetime — both to skip
/// reloading and to avoid the AppKit gotcha where a locally-scoped `NSSound` is deallocated mid-play and
/// the clip is cut off.
@MainActor
final class StatusSoundPlayer {
    /// Shared player so the control server (per-call + blocked-default sounds) and the Settings picker
    /// preview share one `NSSound` cache.
    static let shared = StatusSoundPlayer()

    private var cache: [String: NSSound] = [:]

    /// De-bounce identical replays so a rapid run of `session.status --sound` (or repeated `blocked`
    /// transitions) doesn't stutter the same clip; the Settings preview bypasses this and always sounds.
    private var throttle = SoundThrottle(window: .milliseconds(200))

    /// The standard macOS system sound names: the option list of the Settings sound pickers (the
    /// blocked-status and notification sounds), and the suggested valid values in the `unknown sound`
    /// error; any name `NSSound(named:)` can resolve is accepted, not just these.
    static let standardNames = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse",
                                "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink", "Glass"]

    /// Resolve a `session.status` sound value to its one-shot play action, or nil when a named sound can't
    /// be found. `default`/`beep` plays the system alert sound; anything else plays the named system sound.
    func action(for name: String) -> (() -> Void)? {
        if name == "default" || name == "beep" { return { NSSound.beep() } }
        if let cached = cache[name] { return { cached.stop(); cached.play() } }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return nil }
        cache[name] = sound
        return { sound.stop(); sound.play() }
    }

    /// Resolve and play `name`, suppressing a replay of the SAME sound within the throttle window so a
    /// burst of rapid status sets doesn't machine-gun an identical clip. Returns false ONLY when the name
    /// can't be resolved (so the caller can surface `unknown sound`); a throttled replay returns true
    /// (resolvable, just intentionally silent). The control server's play path uses this; the Settings
    /// picker preview calls `action(for:)` directly so a deliberate preview click always sounds.
    @discardableResult
    func play(_ name: String) -> Bool {
        guard let action = action(for: name) else { return false }
        if throttle.allow(name, at: ContinuousClock().now) { action() }
        return true
    }
}
