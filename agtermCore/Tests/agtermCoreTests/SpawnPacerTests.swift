import Foundation
import Testing
@testable import agtermCore

@MainActor
struct SpawnPacerTests {
    private let interval = Duration.milliseconds(100)

    @Test func unarmedPacerGrantsSynchronously() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        #expect(pacer.isPassthrough)
        #expect(pacer.request(UUID()))
        #expect(!clock.hasPendingWake)
        #expect(log.keys.isEmpty)
    }

    @Test func armEmitsNothingWhileNoKeyRequests() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let keys = [UUID(), UUID(), UUID()]
        pacer.arm(order: keys, burst: [keys[0]])
        #expect(!pacer.isPassthrough)
        #expect(!clock.hasPendingWake)
        clock.advance(interval * 10)
        clock.drain()
        #expect(log.keys.isEmpty)
    }

    @Test func readyKeysGrantInExpectedOrderEachIntervalApart() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let keys = [UUID(), UUID(), UUID()]
        pacer.arm(order: keys, burst: [])
        #expect(!pacer.request(keys[2]))
        #expect(!pacer.request(keys[0]))
        #expect(!pacer.request(keys[1]))
        #expect(log.keys.isEmpty)

        clock.drain()
        #expect(log.keys == keys)
        #expect(log.instants[1] - log.instants[0] == interval)
        #expect(log.instants[2] - log.instants[1] == interval)
        #expect(pacer.isPassthrough)
    }

    @Test func burstKeyGrantsOnItsRequestNotOnArm() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let visible = UUID(), queued = UUID()
        pacer.arm(order: [visible, queued], burst: [visible])
        clock.advance(interval * 5)
        #expect(log.keys.isEmpty)

        #expect(pacer.request(visible))
        #expect(log.keys == [visible])
        #expect(!pacer.request(queued))
        #expect(log.keys == [visible])
    }

    @Test func pacedGrantWaitsForAnExpectedKeyThatHasNotRequested() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let keys = [UUID(), UUID(), UUID()]
        pacer.arm(order: keys, burst: [])
        #expect(!pacer.request(keys[1]))
        #expect(!pacer.request(keys[2]))
        #expect(!clock.hasPendingWake)

        clock.advance(interval * 10)
        clock.drain()
        #expect(log.keys.isEmpty)

        #expect(!pacer.request(keys[0]))
        clock.drain()
        #expect(log.keys == keys)
    }

    @Test func lateWakeReleasesOneGrantOnly() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let keys = [UUID(), UUID(), UUID(), UUID()]
        pacer.arm(order: keys, burst: [])
        for key in keys { _ = pacer.request(key) }

        clock.fireNextWake()
        #expect(log.keys == [keys[0]])

        clock.advance(interval * 3)
        clock.firePendingWake()
        #expect(log.keys == [keys[0], keys[1]])

        clock.firePendingWake()
        #expect(log.keys == [keys[0], keys[1]])
    }

    @Test func expediteGrantsNowAndResetsTheDeadline() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let keys = [UUID(), UUID(), UUID()]
        pacer.arm(order: keys, burst: [])
        for key in keys { _ = pacer.request(key) }
        clock.fireNextWake()
        #expect(log.keys == [keys[0]])

        pacer.expedite(keys[2])
        #expect(log.keys == [keys[0], keys[2]])
        #expect(log.instants[1] == log.instants[0])

        clock.fireNextWake()
        #expect(log.keys == [keys[0], keys[2], keys[1]])
        #expect(log.instants[2] - log.instants[1] == interval)
    }

    @Test func expediteBeforeARequestGrantsOnThatRequest() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let first = UUID(), late = UUID()
        pacer.arm(order: [first, late], burst: [])
        pacer.expedite(late)
        #expect(log.keys.isEmpty)

        pacer.expedite(late)
        #expect(log.keys.isEmpty)

        #expect(pacer.request(late))
        #expect(log.keys == [late])
    }

    @Test func expediteIsANoOpForGrantedAndUnknownKeys() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let keys = [UUID(), UUID()]
        pacer.arm(order: keys, burst: [])
        for key in keys { _ = pacer.request(key) }
        clock.fireNextWake()
        #expect(log.keys == [keys[0]])

        pacer.expedite(keys[0])
        pacer.expedite(UUID())
        #expect(log.keys == [keys[0]])
    }

    @Test func prioritizeReordersWithoutGranting() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let keys = [UUID(), UUID(), UUID()]
        pacer.arm(order: keys, burst: [])
        for key in keys { _ = pacer.request(key) }

        pacer.prioritize([keys[2]])
        #expect(log.keys.isEmpty)

        clock.drain()
        #expect(log.keys == [keys[2], keys[0], keys[1]])
    }

    @Test func repeatedRequestOfAQueuedKeyIsIdempotent() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let keys = [UUID(), UUID()]
        pacer.arm(order: keys, burst: [])
        #expect(!pacer.request(keys[0]))
        #expect(!pacer.request(keys[0]))
        #expect(!pacer.request(keys[1]))

        clock.drain()
        #expect(log.keys == keys)
        #expect(pacer.request(keys[0]))
    }

    @Test func cancelAndDiscardDropWithoutGrantOrCatchUp() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let keys = [UUID(), UUID(), UUID()]
        pacer.arm(order: keys, burst: [])
        for key in keys { _ = pacer.request(key) }
        clock.fireNextWake()
        #expect(log.keys == [keys[0]])

        pacer.cancel(keys[1])
        pacer.discard(keys[2])
        #expect(log.keys == [keys[0]])
        #expect(pacer.isPassthrough)

        clock.drain()
        #expect(log.keys == [keys[0]])
    }

    @Test func discardingAnExpectedKeyThatNeverRequestsDoesNotBlockDrain() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let unmounted = UUID(), queued = UUID()
        pacer.arm(order: [unmounted, queued], burst: [])
        #expect(!pacer.request(queued))
        #expect(!clock.hasPendingWake)

        pacer.discard(unmounted)
        clock.drain()
        #expect(log.keys == [queued])
        #expect(pacer.isPassthrough)
    }

    @Test func requestAfterDrainIsSynchronous() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let armed = UUID()
        pacer.arm(order: [armed], burst: [])
        #expect(!pacer.request(armed))
        clock.drain()
        #expect(pacer.isPassthrough)

        #expect(pacer.request(UUID()))
        #expect(log.keys == [armed])
    }

    @Test func keyOutsideTheArmedOrderGrantsSynchronously() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let armed = UUID()
        pacer.arm(order: [armed], burst: [])
        #expect(pacer.request(UUID()))
        #expect(log.keys.isEmpty)
        #expect(!pacer.isPassthrough)
    }

    @Test func burstGrantReleasesAFollowerThatRequestedFirst() throws {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let visible = UUID(), later = UUID()
        pacer.arm(order: [visible, later], burst: [visible])
        #expect(!pacer.request(later))
        #expect(!clock.hasPendingWake)

        clock.advance(interval * 5)
        #expect(pacer.request(visible))
        #expect(log.keys == [visible])

        clock.advance(interval / 2)
        clock.firePendingWake()
        #expect(log.keys == [visible])

        clock.fireNextWake()
        try #require(log.keys == [visible, later])
        #expect(log.instants[1] - log.instants[0] == interval)
        #expect(pacer.isPassthrough)
    }

    @Test func deferredExpediteGrantReleasesAFollowerThatRequestedFirst() throws {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let head = UUID(), follower = UUID()
        pacer.arm(order: [head, follower], burst: [])
        #expect(!pacer.request(follower))
        #expect(!clock.hasPendingWake)

        pacer.expedite(head)
        #expect(log.keys.isEmpty)

        #expect(pacer.request(head))
        #expect(log.keys == [head])

        clock.fireNextWake()
        try #require(log.keys == [head, follower])
        #expect(log.instants[1] - log.instants[0] == interval)
        #expect(pacer.isPassthrough)
    }

    @Test func drainFiresOnceWithTheTimeSinceArm() {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        var drains: [Duration] = []
        pacer.onDrain = { drains.append($0) }
        let keys = [UUID(), UUID()]
        pacer.arm(order: keys, burst: [keys[0]])

        #expect(pacer.request(keys[0]))
        #expect(drains.isEmpty)
        clock.advance(interval)
        pacer.discard(keys[1])

        #expect(drains == [interval])
        #expect(pacer.isPassthrough)
        pacer.cancel(keys[0])
        #expect(drains.count == 1, "a drop after the drain must not report again")
    }

    /// A second window mounting after the first drained: its selected pane is burst and spawns on request,
    /// and its follower is spaced from that grant, never released together with it.
    @Test func aWindowMountingAfterTheFirstDrainedStillSpacesItsFollower() throws {
        let clock = FakeSpawnClock()
        let log = GrantLog()
        let pacer = makePacer(clock: clock, log: log)
        let first = [UUID(), UUID()]
        let second = [UUID(), UUID()]
        pacer.arm(order: first + second, burst: [first[0], second[0]])
        #expect(pacer.request(first[0]))
        #expect(!pacer.request(first[1]))
        clock.fireNextWake()
        try #require(log.keys == [first[0], first[1]])
        clock.advance(interval * 3)

        #expect(pacer.request(second[0]))
        #expect(!pacer.request(second[1]))
        clock.fireNextWake()

        try #require(log.keys == [first[0], first[1], second[0], second[1]])
        #expect(log.instants[3] - log.instants[2] == interval)
        #expect(pacer.isPassthrough)
    }

    private func makePacer(clock: FakeSpawnClock, log: GrantLog) -> SpawnPacer {
        let pacer = SpawnPacer(interval: interval, now: { clock.now }, schedule: { clock.schedule($0, $1) })
        pacer.onGrant = { key in log.record(key, at: clock.now) }
        return pacer
    }
}

@MainActor
private final class FakeSpawnClock {
    private(set) var now = ContinuousClock().now
    private var pending: (deadline: ContinuousClock.Instant, body: @MainActor () -> Void)?

    var hasPendingWake: Bool { pending != nil }

    func schedule(_ delay: Duration, _ body: @escaping @MainActor () -> Void) {
        pending = (now + delay, body)
    }

    func advance(_ amount: Duration) { now += amount }

    /// Runs the pending wake where the clock stands, so a test can wake the pacer late or early.
    @discardableResult func firePendingWake() -> Bool {
        guard let wake = pending else { return false }
        pending = nil
        wake.body()
        return true
    }

    @discardableResult func fireNextWake() -> Bool {
        guard let wake = pending else { return false }
        if wake.deadline > now { now = wake.deadline }
        return firePendingWake()
    }

    func drain(limit: Int = 20) {
        for _ in 0..<limit where hasPendingWake { fireNextWake() }
    }
}

@MainActor
private final class GrantLog {
    private(set) var keys: [UUID] = []
    private(set) var instants: [ContinuousClock.Instant] = []

    func record(_ key: UUID, at instant: ContinuousClock.Instant) {
        keys.append(key)
        instants.append(instant)
    }
}
