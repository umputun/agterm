import Foundation

/// SpawnPacer rate-limits terminal spawns so a launch that replays captured commands does not start every
/// pane's program at the same instant. It is a leaky bucket: at most one paced grant per `interval`, the
/// next deadline measured from the ACTUAL previous grant, so a stalled main thread releases one grant on
/// waking rather than a catch-up burst.
///
/// Every key is a pane identity UUID (`Session.paneIdentity` or `splitPaneIdentity`), stable for the
/// surface wrapper's lifetime.
///
/// A launch restore arms it with the expected pane order and the burst set (the on-screen panes of every
/// window's selected session, which the user is looking at). Arming grants nothing: no view exists yet, so
/// a grant issued then would release a pane that spawns whenever SwiftUI later mounts it, collapsing
/// several spawns into one pass while every timestamp still looked paced. A key becomes grantable only
/// once its view calls `request`.
///
/// Host-free: the monotonic clock and the timer are injected, so the pacing is testable without real time.
@MainActor
public final class SpawnPacer {
    /// Runs `body` on the main actor after `delay`.
    typealias Scheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

    /// The default `Scheduler`: a main-actor task that sleeps on the system clock.
    static let liveSchedule: Scheduler = { delay, body in
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            body()
        }
    }

    /// Called with each granted key so the caller can spawn that pane's surface.
    public var onGrant: (@MainActor (UUID) -> Void)?

    /// Called once per launch when the last armed key is granted, cancelled or discarded, with the time
    /// since `arm`. Diagnostics only: the pacer is already passthrough when it fires.
    public var onDrain: (@MainActor (Duration) -> Void)?

    /// Minimum gap between paced grants.
    private let interval: Duration

    /// True when nothing is queued: unarmed, or every armed key granted, cancelled or discarded. In that
    /// state `request` answers synchronously, so a session created after the launch never waits.
    public var isPassthrough: Bool { !armed || pending.isEmpty }

    private enum State {
        case expected
        case ready
        case granted
    }

    private let now: @MainActor () -> ContinuousClock.Instant
    private let schedule: Scheduler
    private var armed = false
    private var pending: [UUID] = []
    private var states: [UUID: State] = [:]
    private var immediate: Set<UUID> = []
    private var lastGrant: ContinuousClock.Instant?
    private var armedAt: ContinuousClock.Instant?
    private var wakeScheduled = false

    /// Creates a pacer driven by the system clock.
    public convenience init(interval: Duration = .milliseconds(120)) {
        self.init(interval: interval, now: { ContinuousClock().now }, schedule: SpawnPacer.liveSchedule)
    }

    init(interval: Duration,
         now: @escaping @MainActor () -> ContinuousClock.Instant,
         schedule: @escaping Scheduler) {
        self.interval = interval
        self.now = now
        self.schedule = schedule
    }

    /// Records the expected spawn order and the keys exempt from pacing, and nothing else: no grant is
    /// issued and no timer starts. Called once per launch restore, before any window mounts.
    public func arm(order: [UUID], burst: Set<UUID>) {
        armed = true
        pending = order
        states = order.reduce(into: [:]) { $0[$1] = .expected }
        immediate = burst.intersection(order)
        lastGrant = nil
        wakeScheduled = false
        armedAt = now()
    }

    /// Marks `key` ready to spawn and answers whether it may spawn now. False leaves it queued for a later
    /// `onGrant`. True for a burst or expedited key, for a key already granted, and for any key outside the
    /// armed order, so calling it again after a grant is safe.
    public func request(_ key: UUID) -> Bool {
        guard !isPassthrough, let state = states[key] else { return true }
        if state == .granted { return true }
        if immediate.contains(key) {
            grant(key)
            return true
        }
        states[key] = .ready
        scheduleWake()
        return false
    }

    /// Grants `key` now, consuming the next token so the queue waits a full `interval` after it. A key
    /// whose view has not requested yet is marked instead and granted on that request. No-op for a granted,
    /// unknown or already-expedited key, so repeated selection of one pane cannot mint tokens.
    public func expedite(_ key: UUID) {
        guard let state = states[key], state != .granted, !immediate.contains(key) else { return }
        guard state == .ready else {
            immediate.insert(key)
            return
        }
        grant(key)
    }

    /// Moves `keys` to the front of the queue in the given order, releasing nothing. For a host that opens
    /// on many queued panes at once, such as the dashboard.
    public func prioritize(_ keys: [UUID]) {
        var seen: Set<UUID> = []
        let promoted = keys.filter { pending.contains($0) && seen.insert($0).inserted }
        guard !promoted.isEmpty else { return }
        pending = promoted + pending.filter { !seen.contains($0) }
        scheduleWake()
    }

    /// Drops `key` because its pane or its view is gone.
    public func cancel(_ key: UUID) { drop(key) }

    /// Drops `key` because it spawns without a permit: a pane that replays nothing, or one already
    /// realized elsewhere. It leaves the queue without a grant, so the pacing of the rest is unchanged.
    public func discard(_ key: UUID) { drop(key) }

    private func drop(_ key: UUID) {
        guard states.removeValue(forKey: key) != nil else { return }
        pending.removeAll { $0 == key }
        immediate.remove(key)
        scheduleWake()
        noteDrain()
    }

    private func noteDrain() {
        guard armed, pending.isEmpty, let armedAt else { return }
        armed = false
        self.armedAt = nil
        onDrain?(now() - armedAt)
    }

    private func grant(_ key: UUID) {
        states[key] = .granted
        pending.removeAll { $0 == key }
        immediate.remove(key)
        lastGrant = now()
        onGrant?(key)
        scheduleWake()
        noteDrain()
    }

    private func scheduleWake() {
        guard !wakeScheduled, grantableHead != nil else { return }
        wakeScheduled = true
        schedule(remainingDelay()) { [weak self] in self?.wake() }
    }

    private func wake() {
        wakeScheduled = false
        guard let head = grantableHead else { return }
        guard remainingDelay() == .zero else {
            scheduleWake()
            return
        }
        grant(head)
    }

    /// The next key to grant: the head of the expected order, and only when its view has requested. A later
    /// ready key never jumps it, so the queue drains in model order.
    private var grantableHead: UUID? {
        guard let head = pending.first, states[head] == .ready else { return nil }
        return head
    }

    private func remainingDelay() -> Duration {
        guard let lastGrant else { return .zero }
        let elapsed = now() - lastGrant
        return elapsed >= interval ? .zero : interval - elapsed
    }
}
