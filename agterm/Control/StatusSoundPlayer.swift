import AppKit

/// StatusSoundPlayer plays the one-shot sound requested by `session.status --sound`. It is a thin AppKit
/// wrapper over `NSSound`, owned by `ControlServer` for the app's lifetime.
///
/// `action(for:)` resolves a sound name to its play closure (or nil when a named sound can't be found),
/// so the caller can validate before mutating the indicator and surface an `unknown sound` error. The
/// `default`/`beep` value maps to the system alert sound; any other value is a named system sound via
/// `NSSound(named:)`, which also resolves custom sounds in `~/Library/Sounds`.
///
/// Resolved `NSSound` instances are cached and thus retained for the app's lifetime — both to skip
/// reloading and to avoid the AppKit gotcha where a locally-scoped `NSSound` is deallocated mid-play and
/// the clip is cut off.
@MainActor
final class StatusSoundPlayer {
    private var cache: [String: NSSound] = [:]

    /// The standard macOS system sound names, used only to suggest valid values in the `unknown sound`
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
}
