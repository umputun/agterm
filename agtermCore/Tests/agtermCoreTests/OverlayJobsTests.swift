import Foundation
import Testing
@testable import agtermCore

@MainActor
struct OverlayJobsTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_789_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    nonisolated static let context = OverlayLaunchContext(command: "revdiff", cwd: "/work", sessionEnvironment: [:])

    let clock = Clock()

    func makeJobs() -> (OverlayJobs, () -> [OverlayJob]) {
        let clock = clock
        let jobs = OverlayJobs(now: { clock.now })
        var finished: [OverlayJob] = []
        jobs.onFinished = { finished.append($0) }
        return (jobs, { finished })
    }

    func register(_ jobs: OverlayJobs) -> String {
        jobs.register(session: UUID(), pane: nil, owner: 1, context: Self.context)
    }

    @Test func aClaimBeforeTheDeadlineGetsTheContextOnce() {
        let (jobs, _) = makeJobs()
        let id = register(jobs)

        #expect(jobs.claim(id) {} == Self.context)
        #expect(jobs.claim(id) {} == nil)
    }

    @Test func aClaimThatWonCannotBeFailedByTheLaunchDeadline() {
        let (jobs, finished) = makeJobs()
        let id = register(jobs)
        _ = jobs.claim(id) {}
        jobs.started(id)

        clock.advance(OverlayJobs.launchWindow + 1)
        jobs.expire()

        #expect(jobs.job(id)?.state == .running)
        #expect(finished().isEmpty)
    }

    @Test func aDeadlineThatWonFailsTheLaunchAndALateClaimSpawnsNothing() {
        let (jobs, finished) = makeJobs()
        let id = register(jobs)

        clock.advance(OverlayJobs.launchWindow)
        jobs.expire()

        #expect(jobs.job(id)?.state == .finished(.launchFailed))
        #expect(jobs.claim(id) {} == nil)
        #expect(finished().map(\.id) == [id])
    }

    @Test func aClaimArrivingAfterTheDeadlineButBeforeAnyExpiryRunIsStillRefused() {
        let (jobs, _) = makeJobs()
        let id = register(jobs)

        clock.advance(OverlayJobs.launchWindow)

        #expect(jobs.claim(id) {} == nil)
        #expect(jobs.job(id)?.state == .finished(.launchFailed))
    }

    @Test func aClaimThatNeverReportsStartingEndsUnknown() {
        let (jobs, _) = makeJobs()
        let id = register(jobs)
        _ = jobs.claim(id) {}

        clock.advance(OverlayJobs.startWindow)
        jobs.expire()

        #expect(jobs.job(id)?.state == .finished(.unknown))
    }

    // regression: a start reported after the claim's deadline, before the scheduled expiry ran, read as running
    @Test func aStartReportedPastTheDeadlineBeforeAnyExpiryRunEndsUnknown() {
        let (jobs, _) = makeJobs()
        let id = register(jobs)
        _ = jobs.claim(id) {}

        clock.advance(OverlayJobs.startWindow + 0.05)
        jobs.started(id)

        #expect(jobs.job(id)?.state == .finished(.unknown))
    }

    @Test func aHelperGoingAwayWithoutAReportEndsUnknown() {
        let (jobs, _) = makeJobs()
        let id = register(jobs)
        _ = jobs.claim(id) {}
        jobs.started(id)

        jobs.helperGone(id)

        #expect(jobs.job(id)?.state == .finished(.unknown))
    }

    @Test func aRunningJobOutlivesEveryTimeout() {
        let (jobs, _) = makeJobs()
        let id = register(jobs)
        _ = jobs.claim(id) {}
        jobs.started(id)

        clock.advance(24 * 3600)
        jobs.expire()

        #expect(jobs.job(id)?.state == .running)
    }

    @Test func onlyTheFirstTerminalOutcomeCounts() {
        let (jobs, finished) = makeJobs()
        let id = register(jobs)
        _ = jobs.claim(id) {}
        jobs.started(id)

        #expect(jobs.finish(id, .exited(3)))
        #expect(!jobs.finish(id, .exited(0)))
        jobs.helperGone(id)

        #expect(jobs.job(id)?.state == .finished(.exited(3)))
        #expect(finished().count == 1)
    }

    @Test func aReportForAJobNotHeldChangesNothing() {
        let (jobs, finished) = makeJobs()

        #expect(!jobs.finish("nope", .exited(0)))
        #expect(finished().isEmpty)
    }

    @Test func cancellingAnUnclaimedJobEndsItAndRefusesALateClaim() {
        let (jobs, _) = makeJobs()
        let id = register(jobs)

        #expect(jobs.cancel(id))

        #expect(jobs.job(id)?.state == .finished(.canceled))
        #expect(jobs.claim(id) {} == nil)
    }

    @Test func cancellingAClaimedJobReachesItsHelperAndWaitsForItsReport() {
        let (jobs, _) = makeJobs()
        let id = register(jobs)
        var reached = 0
        _ = jobs.claim(id) { reached += 1 }

        #expect(jobs.cancel(id))

        #expect(reached == 1)
        #expect(jobs.job(id)?.state == .claimed(deadline: clock.now.addingTimeInterval(OverlayJobs.startWindow)))
    }

    @Test func cancellingAFinishedJobIsRefused() {
        let (jobs, _) = makeJobs()
        let id = register(jobs)
        jobs.finish(id, .exited(0))

        #expect(!jobs.cancel(id))
    }

    @Test(arguments: [OverlayJobFrame.context(context), .cancel, .started, .exited(3), .canceled,
                      .launchFailed("no such command")])
    func everyJobFrameSurvivesTheWire(_ frame: OverlayJobFrame) throws {
        let line = try frame.line()

        #expect(line.last == UInt8(ascii: "\n"))
        #expect(try JSONDecoder().decode(OverlayJobFrame.self, from: line.dropLast()) == frame)
    }

    @Test(arguments: [(OverlayJobOutcome.exited(0), String?.none), (.canceled, "canceled"),
                      (.launchFailed, "launch-failed"), (.unknown, "unknown")])
    func onlyAnOutcomeWithoutAnExitCodeHasAFailureName(_ outcome: OverlayJobOutcome, _ name: String?) {
        #expect(outcome.failureName == name)
    }
}
