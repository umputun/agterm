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
@MainActor
final class StatusSoundPlayer {
    /// Shared so every caller reuses one `NSSound` cache.
    static let shared = StatusSoundPlayer()

    private var cache: [String: NSSound] = [:]
    private let resolve: @Sendable (String) -> NSSound?

    init(resolve: @escaping @Sendable (String) -> NSSound? = { NSSound(named: NSSound.Name($0)) }) {
        self.resolve = resolve
    }

    /// Playback runs here, never on the main actor: the first `NSSound.play()` in a process is slow enough
    /// to stall keystroke delivery in every session, measured at ~0.9s in #575 (the cause inside AppKit was
    /// never established). Serial, so one clip's `stop()`/`play()` pair can't interleave with another's.
    private static let playQueue = DispatchQueue(label: "com.umputun.agterm.status-sound", qos: .userInitiated)

    /// Lookup I/O gets its own queue so a slow name never occupies `playQueue`. Serial by choice: parallel
    /// lookups would let a slow blocked default overlap a later command's first lookup, but `NSSound(named:)`
    /// reads a shared registry with no documented concurrency guarantee, and that is the worse bet.
    private static let resolveQueue = DispatchQueue(label: "com.umputun.agterm.status-sound.resolve", qos: .userInitiated)

    /// Suppress rapid repeats of the same status sound to avoid stuttering; Settings previews bypass this.
    private var throttle = SoundThrottle(window: .milliseconds(200))

    /// The standard macOS system sound names: the Settings sound pickers' option list (blocked-status and
    /// notification) and the `unknown sound` error's suggestions; any name `NSSound(named:)` resolves works.
    static let standardNames = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse",
                                "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink", "Glass"]

    /// Resolve a `session.status` sound value to its one-shot play action, or nil when a named sound can't
    /// be found. `default`/`beep` plays the system alert sound; anything else plays the named system sound.
    /// Cache misses use the resolution queue; cache hits return without queueing.
    func action(for name: String) async -> (() -> Void)? {
        if name == "default" || name == "beep" { return { Self.playQueue.async { NSSound.beep() } } }
        if let cached = cache[name] { return Self.playAction(for: cached) }
        let resolved = await withCheckedContinuation { continuation in
            Self.resolveQueue.async { [resolve] in
                continuation.resume(returning: resolve(name))
            }
        }
        guard let sound = resolved else { return nil }
        cache[name] = sound
        return Self.playAction(for: sound)
    }

    /// Resolve and play `name`, suppressing identical replays within the throttle window.
    /// False lets callers report an unknown name; true includes a valid sound intentionally silenced by
    /// throttling, so a suppressed replay is not mistaken for a resolution failure.
    @discardableResult
    func play(_ name: String) async -> Bool {
        guard let action = await action(for: name) else { return false }
        play(name, using: action)
        return true
    }

    /// Submit an already validated action without another resolution or suspension after the status write.
    func play(_ name: String, using action: () -> Void) {
        if throttle.allow(name, at: ContinuousClock().now) { action() }
    }

    /// Preview only while its selection still applies, bypassing status throttling.
    func preview(_ name: String, ifCurrent: () -> Bool) async {
        guard let action = await action(for: name), ifCurrent() else { return }
        action()
    }

    private static func playAction(for sound: NSSound) -> () -> Void {
        { playQueue.async { sound.stop(); sound.play() } }
    }
}
