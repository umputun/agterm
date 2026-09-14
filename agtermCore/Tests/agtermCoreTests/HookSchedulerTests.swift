import Foundation
import Testing
@testable import agtermCore

@MainActor
final class FakeHookLauncher: HookLauncher {
    struct Launch {
        let entry: HookEntry
        let event: ControlEvent
        let onDeliveryFailure: @MainActor @Sendable (String) -> Void
        let onExit: @MainActor @Sendable (Int32) -> Void
    }

    var launches: [Launch] = []
    var throwNext: String?
    private var nextPid: Int32 = 100

    func launch(entry: HookEntry, event: ControlEvent,
                onDeliveryFailure: @escaping @MainActor @Sendable (String) -> Void,
                onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws -> Int32 {
        if let message = throwNext {
            throwNext = nil
            throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        launches.append(Launch(entry: entry, event: event, onDeliveryFailure: onDeliveryFailure, onExit: onExit))
        nextPid += 1
        return nextPid
    }
}

@MainActor
struct HookSchedulerTests {
    private let launcher = FakeHookLauncher()
    private func event(_ kind: ControlEventKind, seq: UInt64) -> ControlEvent {
        ControlEvent(seq: seq, ts: Double(seq), kind: kind, session: "s\(seq)")
    }

    private func hooks(_ lines: String) -> Hooks {
        parseHooksConf(lines).hooks
    }

    private func makeScheduler() -> HookScheduler {
        HookScheduler(launcher: launcher, now: { Date(timeIntervalSince1970: 1_000) })
    }

    @Test func eventsFanOutToEveryMatchingHookWithIndependentSlots() {
        let scheduler = makeScheduler()
        scheduler.apply(hooks("on status a\non status b\non notify c"))

        scheduler.dispatch(event(.status, seq: 1))
        scheduler.dispatch(event(.treeChanged, seq: 2))

        #expect(launcher.launches.map(\.entry.command) == ["a", "b"])
        #expect(launcher.launches.map(\.event.seq) == [1, 1])
        launcher.launches[0].onExit(0)
        scheduler.dispatch(event(.status, seq: 3))
        #expect(launcher.launches.map(\.entry.command) == ["a", "b", "a"])
        #expect(scheduler.status.map(\.pending) == [0, 1, 0])
    }

    @Test func burstIsDeliveredInOrderOneChildAtATime() {
        let scheduler = makeScheduler()
        scheduler.apply(hooks("on status a"))

        for seq in 1...4 { scheduler.dispatch(event(.status, seq: UInt64(seq))) }
        #expect(launcher.launches.map(\.event.seq) == [1])
        #expect(scheduler.status[0].pending == 3)
        #expect(scheduler.status[0].runningPid != nil)

        launcher.launches[0].onExit(0)
        #expect(launcher.launches.map(\.event.seq) == [1, 2])
        launcher.launches[1].onExit(0)
        launcher.launches[2].onExit(0)
        #expect(launcher.launches.map(\.event.seq) == [1, 2, 3, 4])
        #expect(scheduler.status[0].pending == 0)
        launcher.launches[3].onExit(0)
        #expect(scheduler.status[0].runningPid == nil)
    }

    @Test func pendingIsCappedDroppingTheOldestAndCounting() {
        let scheduler = makeScheduler()
        scheduler.apply(hooks("on status a"))

        for seq in 1...(HookScheduler.pendingCapacity + 3) { scheduler.dispatch(event(.status, seq: UInt64(seq))) }
        #expect(scheduler.status[0].pending == HookScheduler.pendingCapacity)
        #expect(scheduler.status[0].dropped == 2)

        launcher.launches[0].onExit(0)
        #expect(launcher.launches.last?.event.seq == 4)
    }

    @Test func launchThrowAdvancesTheQueueAndRecordsOneFailure() {
        let scheduler = makeScheduler()
        var banners: [String] = []
        scheduler.onFailure = { _, message in banners.append(message) }
        scheduler.apply(hooks("on status a"))

        scheduler.dispatch(event(.status, seq: 1))
        launcher.throwNext = "no such file"
        scheduler.dispatch(event(.status, seq: 2))
        scheduler.dispatch(event(.status, seq: 3))
        launcher.launches[0].onExit(0)

        #expect(launcher.launches.map(\.event.seq) == [1, 3])
        #expect(scheduler.status[0].lastFailure == "spawn failed: no such file")
        #expect(banners == ["spawn failed: no such file"])
        launcher.launches[1].onExit(0)
        #expect(scheduler.status[0].lastFailure == nil)
    }

    @Test func deliveryFailureOnALiveRunNeverReleasesTheSlot() {
        let scheduler = makeScheduler()
        var banners: [String] = []
        scheduler.onFailure = { _, message in banners.append(message) }
        scheduler.apply(hooks("on status a"))

        scheduler.dispatch(event(.status, seq: 1))
        scheduler.dispatch(event(.status, seq: 2))
        launcher.launches[0].onDeliveryFailure("EBADF")
        #expect(launcher.launches.count == 1)
        #expect(scheduler.status[0].runningPid != nil)
        #expect(scheduler.status[0].pending == 1)
        #expect(scheduler.status[0].lastFailure == "delivery failed: EBADF")
        #expect(banners == ["delivery failed: EBADF"])

        scheduler.apply(hooks("on status a"))
        #expect(scheduler.status[0].lastFailure == "delivery failed: EBADF")

        launcher.launches[0].onExit(0)
        #expect(scheduler.status[0].lastFailure == "delivery failed: EBADF")
        #expect(launcher.launches.map(\.event.seq) == [1, 2])
        launcher.launches[1].onExit(0)
        #expect(scheduler.status[0].lastFailure == nil)
    }

    @Test func nonZeroExitBannersOnceUntilSuccessOrReload() {
        let scheduler = makeScheduler()
        var banners: [String] = []
        scheduler.onFailure = { _, message in banners.append(message) }
        scheduler.apply(hooks("on status a"))

        scheduler.dispatch(event(.status, seq: 1))
        launcher.launches[0].onExit(2)
        scheduler.dispatch(event(.status, seq: 2))
        launcher.launches[1].onExit(3)
        #expect(banners == ["exit 2"])
        #expect(scheduler.status[0].lastFailure == "exit 3")

        scheduler.apply(hooks("on status a"))
        scheduler.dispatch(event(.status, seq: 3))
        launcher.launches[2].onExit(4)
        #expect(banners == ["exit 2", "exit 4"])

        scheduler.dispatch(event(.status, seq: 4))
        launcher.launches[3].onExit(0)
        #expect(scheduler.status[0].lastFailure == nil)
        scheduler.dispatch(event(.status, seq: 5))
        launcher.launches[4].onExit(5)
        #expect(banners == ["exit 2", "exit 4", "exit 5"])
    }

    @Test func reloadAfterReorderAndCommentsKeepsStateAndUpdatesLines() {
        let scheduler = makeScheduler()
        var banners: [String] = []
        scheduler.onFailure = { _, message in banners.append(message) }
        scheduler.apply(hooks("on status a\non status b"))
        for seq in 1...3 { scheduler.dispatch(event(.status, seq: UInt64(seq))) }
        launcher.launches[1].onExit(7)
        let pidA = scheduler.status[0].runningPid

        scheduler.apply(hooks("# moved\n\non status b\n# a comment above a\non status a"))

        #expect(scheduler.status.map(\.command) == ["b", "a"])
        #expect(scheduler.status.map(\.line) == [3, 5])
        #expect(scheduler.status[1].runningPid == pidA)
        #expect(scheduler.status[1].pending == 2)
        #expect(scheduler.status[0].lastFailure == "exit 7")
        #expect(scheduler.status[0].pending == 1)
        #expect(launcher.launches.map(\.event.seq) == [1, 1, 2])

        scheduler.dispatch(event(.status, seq: 4))
        #expect(launcher.launches.count == 3)
        launcher.launches[2].onExit(8)
        #expect(banners == ["exit 7", "exit 8"])
        #expect(launcher.launches.map(\.event.seq) == [1, 1, 2, 3])
    }

    @Test func reloadKeepsANonzeroDroppedCount() {
        let scheduler = makeScheduler()
        scheduler.apply(hooks("on status a"))
        for seq in 1...(HookScheduler.pendingCapacity + 3) { scheduler.dispatch(event(.status, seq: UInt64(seq))) }

        scheduler.apply(hooks("# comment\non status a"))

        #expect(scheduler.status[0].dropped == 2)
        #expect(scheduler.status[0].pending == HookScheduler.pendingCapacity)
        #expect(scheduler.status[0].line == 2)
    }

    @Test func removedHookDropsPendingAndStaysOccupiedUntilExit() {
        let scheduler = makeScheduler()
        scheduler.apply(hooks("on status a\non status b"))
        for seq in 1...3 { scheduler.dispatch(event(.status, seq: UInt64(seq))) }

        scheduler.apply(hooks("on status b"))
        scheduler.dispatch(event(.status, seq: 4))
        #expect(scheduler.status.map(\.command) == ["b", "a"])
        #expect(scheduler.status.map(\.retired) == [nil, true])
        #expect(scheduler.status[1].pending == 0)
        #expect(scheduler.status[1].runningPid == 101)
        #expect(launcher.launches.filter { $0.entry.command == "a" }.count == 1)

        launcher.launches[0].onExit(0)
        #expect(launcher.launches.filter { $0.entry.command == "a" }.count == 1)
        #expect(scheduler.status.map(\.command) == ["b"])
    }

    @Test func changedCommandIsANewIdentityRunningAlongsideTheRetiredOne() {
        let scheduler = makeScheduler()
        scheduler.apply(hooks("on status a"))
        scheduler.dispatch(event(.status, seq: 1))

        scheduler.apply(hooks("on status a2"))
        scheduler.dispatch(event(.status, seq: 2))

        #expect(launcher.launches.map(\.entry.command) == ["a", "a2"])
        #expect(scheduler.status.map(\.command) == ["a2", "a"])
        #expect(scheduler.status.map(\.retired) == [nil, true])
        launcher.launches[0].onExit(0)
        #expect(launcher.launches.count == 2)
        #expect(scheduler.status.map(\.command) == ["a2"])
    }

    @Test func reAddBeforeExitReattachesAndTheOriginalExitStartsTheNewQueue() {
        let scheduler = makeScheduler()
        scheduler.apply(hooks("on status a"))
        scheduler.dispatch(event(.status, seq: 1))
        scheduler.dispatch(event(.status, seq: 2))
        let firstExit = launcher.launches[0].onExit

        scheduler.apply(hooks(""))
        #expect(scheduler.status.map(\.retired) == [true])
        scheduler.apply(hooks("on status a"))
        scheduler.dispatch(event(.status, seq: 3))
        #expect(launcher.launches.count == 1)
        #expect(scheduler.status.count == 1)
        #expect(scheduler.status[0].retired == nil)
        #expect(scheduler.status[0].pending == 1)
        #expect(scheduler.status[0].runningPid == 101)

        firstExit(0)
        #expect(launcher.launches.map(\.event.seq) == [1, 3])

        firstExit(0)
        #expect(launcher.launches.count == 2)
        #expect(scheduler.status[0].runningPid != nil)
        launcher.launches[1].onExit(0)
        #expect(scheduler.status[0].runningPid == nil)
    }

    @Test func statusReportsLiveStateInFileOrder() {
        var tick = 1_000.0
        let scheduler = HookScheduler(launcher: launcher, now: { Date(timeIntervalSince1970: tick) })
        scheduler.apply(hooks("on notify n\non status a"))
        scheduler.dispatch(event(.status, seq: 1))
        scheduler.dispatch(event(.status, seq: 2))
        tick += 2.5

        let rows = scheduler.status
        #expect(rows.map(\.kind) == ["notify", "status"])
        #expect(rows[0] == ControlHookEntry(kind: "notify", command: "n", line: 1))
        #expect(rows[1].runningPid == 101)
        #expect(rows[1].elapsedSeconds == 2.5)
        #expect(rows[1].pending == 1)
        #expect(rows[1].dropped == 0)
        #expect(rows[1].lastFailure == nil)
    }
}
