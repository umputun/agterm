/// SoundThrottle suppresses a replay of the SAME sound within a short window, so a burst of rapid
/// `session.status --sound` calls (or repeated `blocked` transitions) can't machine-gun an identical
/// clip. It tracks the last play time per sound name; a DIFFERENT sound is never suppressed. Host-free
/// and clock-injected (the caller passes a monotonic `now`) so the window decision is unit-testable
/// without real time.
public struct SoundThrottle: Sendable {
    /// Minimum gap before the same sound name may play again.
    private let window: Duration
    private var lastPlayed: [String: ContinuousClock.Instant] = [:]

    public init(window: Duration) { self.window = window }

    /// Whether `name` may play at `now`, recording the play when it may. Returns false WITHOUT changing
    /// state for a same-sound replay still inside `window` (so the window is always measured from the last
    /// ALLOWED play, not the last attempt); otherwise records `now` and returns true — including the first
    /// play of a name and any play at or past the window boundary.
    public mutating func allow(_ name: String, at now: ContinuousClock.Instant) -> Bool {
        if let last = lastPlayed[name], now - last < window { return false }
        lastPlayed[name] = now
        return true
    }
}
