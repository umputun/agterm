import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ZmxClientLiveResetTests: XCTestCase {
    private func client(_ runner: @escaping ZmxClient.Runner) -> ZmxClient {
        ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", runner: runner)
    }

    func testSessionRecordsKeepUnreadableRows() throws {
        let records = client { _ in "name=agterm-a\tpid=11\tclients=0\nname=agterm-b\terr=unreachable" }.sessionRecords()

        let rows = try XCTUnwrap(records)
        XCTAssertEqual(rows.map(\.name), ["agterm-a", "agterm-b"])
        XCTAssertEqual(rows[0].leaderPID, 11)
        XCTAssertNil(rows[1].clients)
        XCTAssertNil(rows[1].leaderPID)
    }

    func testSessionRecordsNilOnFailedListing() {
        XCTAssertNil(client { _ in throw ZmxClient.CommandError.timedOut }.sessionRecords())
    }

    func testKillBatchSendsOneInvocationUnderTimeout() {
        var invocations: [ZmxClient.Invocation] = []
        let client = client { invocation in invocations.append(invocation); return "" }

        XCTAssertTrue(client.killBatch(names: ["agterm-a", "agterm-b", "agterm-a"], timeout: 5))

        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.arguments, ["kill", "agterm-a", "agterm-b", "--force"])
        XCTAssertEqual(invocations.first?.timeout, 5)
    }

    func testKillBatchReportsFailure() {
        XCTAssertFalse(client { _ in throw ZmxClient.CommandError.failed(1, "boom") }.killBatch(names: ["agterm-a"], timeout: 5))
    }

    func testLeadersExitedReturnsEmptyWhenAllExit() {
        var clock = ContinuousClock.Instant.now
        var polls = 0
        let poll = ZmxClient.LeaderPoll(now: { clock }, sleep: { clock = clock.advanced(by: $0) })

        let survivors = ZmxClient.leadersExited([10, 20], deadline: clock.advanced(by: .seconds(10)), poll: poll) { _ in
            polls += 1
            return polls < 4
        }

        XCTAssertEqual(survivors, [])
        XCTAssertLessThan(clock, ContinuousClock.Instant.now.advanced(by: .seconds(10)))
    }

    func testLeadersExitedReturnsSurvivorsAtDeadline() {
        var clock = ContinuousClock.Instant.now
        var slept: Duration = .zero
        let poll = ZmxClient.LeaderPoll(now: { clock }, sleep: { clock = clock.advanced(by: $0); slept += $0 })

        let survivors = ZmxClient.leadersExited([10, 20], deadline: clock.advanced(by: .seconds(1)), poll: poll) { $0 == 20 }

        XCTAssertEqual(survivors, [20])
        XCTAssertGreaterThanOrEqual(slept, .seconds(1))
        XCTAssertLessThan(slept, .seconds(2))
    }
}
