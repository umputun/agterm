import Foundation

/// The outcome of feeding one chord to a `KeybindMatcher`.
public enum MatchResult: Equatable, Sendable {
    /// The pending prefix plus this chord exactly matches a bound keybind; the matcher has reset.
    case fired(UUID)
    /// The pending prefix plus this chord is a strict prefix of a longer bind; the matcher now awaits the
    /// next chord (the leader is armed).
    case armed
    /// No bind starts with the pending prefix plus this chord; the matcher has reset.
    case unmatched
}

/// The leader/sequence state machine that turns a stream of chords into command fires.
///
/// Built from `(Keybind, UUID)` pairs, it holds the chords typed so far as a pending prefix; `advance(_:)`
/// consumes one chord and reports `.fired`/`.armed`/`.unmatched`. Deadline-free — the leader timeout that
/// abandons a half-typed sequence is app-side and calls `reset()`, as Esc does. No AppKit, no timers.
public struct KeybindMatcher: Sendable {
    private let binds: [(keybind: Keybind, id: UUID)]
    private var pending: [Chord] = []

    public init(_ binds: [(Keybind, UUID)]) {
        self.binds = binds.map { (keybind: $0.0, id: $0.1) }
    }

    /// Whether a sequence is partway through (a leader is armed). The app uses this to gate the timeout
    /// timer and the on-screen hint.
    public var isArmed: Bool { !pending.isEmpty }

    /// Feed one chord: an exact match fires and resets, a strict prefix arms (keeping the pending prefix for
    /// the next chord), anything else is unmatched and resets. When armed, a chord completing no bind resets
    /// so the caller can pass it through to the terminal — UNLESS the chord is itself a fresh leader, in
    /// which case the matcher re-arms on it, so re-pressing a leader restarts rather than abandons the
    /// sequence.
    public mutating func advance(_ chord: Chord) -> MatchResult {
        let candidate = pending + [chord]

        for bind in binds where bind.keybind == candidate {
            pending = []
            return .fired(bind.id)
        }

        if binds.contains(where: { isStrictPrefix(candidate, of: $0.keybind) }) {
            pending = candidate
            return .armed
        }

        // the extended prefix matches nothing; if the chord on its own is a fresh leader (or an
        // exact single-chord bind), restart from it instead of dropping the press.
        if isArmed {
            pending = []
            return advance(chord)
        }

        pending = []
        return .unmatched
    }

    /// Clear the pending prefix (Esc or the app-side leader timeout).
    public mutating func reset() {
        pending = []
    }

    /// Whether `prefix` is a strict (shorter, leading) prefix of `keybind`.
    private func isStrictPrefix(_ prefix: [Chord], of keybind: Keybind) -> Bool {
        guard prefix.count < keybind.count else { return false }
        return Array(keybind.prefix(prefix.count)) == prefix
    }
}
