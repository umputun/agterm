import AppKit
import agtermCore

/// StatusSoundPlayer plays the one-shot sound requested by `session.status --sound`: a thin `@MainActor`
/// singleton over `NSSound`, used by `ControlServer` (the per-call and blocked-default status sounds) and
/// by the Settings sound pickers' selection previews.
///
/// `action(for:)` resolves a name without playing it, so the caller can validate before mutating the
/// indicator and surface an `unknown sound` error; `NSSound(named:)` also resolves `~/Library/Sounds`.
/// Resolved sounds are cached, so they are retained for the app's lifetime — skipping a reload, and dodging
/// the AppKit gotcha where a locally-scoped `NSSound` is deallocated mid-play and the clip is cut off.
///
/// Resolution stays on the main actor because `session.status` must answer `unknown sound` before it mutates
/// anything; only playback leaves it, on `playQueue`.
@MainActor
final class StatusSoundPlayer {
    /// Shared so every caller reuses one `NSSound` cache.
    static let shared = StatusSoundPlayer()

    private var cache: [String: NSSound] = [:]

    /// Playback runs here, never on the main actor: the first `NSSound.play()` in a process spins up
    /// CoreAudio and held the main queue for ~0.7s (#575), which stalls keystroke delivery in every session.
    /// Serial, so one clip's `stop()`/`play()` pair can't interleave with another's on the same instance.
    private static let playQueue = DispatchQueue(label: "com.umputun.agterm.status-sound", qos: .userInitiated)

    /// De-bounce identical replays so a rapid run of `session.status --sound` (or repeated `blocked`
    /// transitions) doesn't stutter the same clip; the Settings preview bypasses this and always sounds.
    private var throttle = SoundThrottle(window: .milliseconds(200))

    /// The standard macOS system sound names: the Settings sound pickers' option list (blocked-status and
    /// notification) and the `unknown sound` error's suggestions; any name `NSSound(named:)` resolves works.
    static let standardNames = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse",
                                "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink", "Glass"]

    /// Resolve a `session.status` sound value to its one-shot play action, or nil when a named sound can't
    /// be found. `default`/`beep` plays the system alert sound; anything else plays the named system sound.
    func action(for name: String) -> (() -> Void)? {
        if name == "default" || name == "beep" { return { Self.playQueue.async { NSSound.beep() } } }
        if let cached = cache[name] { return Self.playAction(for: cached) }
        guard let sound = NSSound(named: NSSound.Name(name)) else { return nil }
        cache[name] = sound
        return Self.playAction(for: sound)
    }

    /// Resolve and play `name`, suppressing a replay of the SAME sound within the throttle window so a burst
    /// of rapid status sets doesn't machine-gun an identical clip. Returns false ONLY when the name can't be
    /// resolved (so the caller can surface `unknown sound`); a throttled replay returns true — resolvable,
    /// just intentionally silent. The control server plays through this; the Settings picker preview calls
    /// `action(for:)` directly so a deliberate click always sounds.
    @discardableResult
    func play(_ name: String) -> Bool {
        guard let action = action(for: name) else { return false }
        if throttle.allow(name, at: ContinuousClock().now) { action() }
        return true
    }

    /// The one-shot play action for an already-resolved sound, hopping to `playQueue` so the caller's thread
    /// — the main actor, for every caller here — never waits on audio startup.
    private static func playAction(for sound: NSSound) -> () -> Void {
        { playQueue.async { sound.stop(); sound.play() } }
    }
}
