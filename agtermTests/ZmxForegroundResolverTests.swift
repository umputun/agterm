import Darwin
import XCTest
@testable import agterm

@MainActor
final class ZmxForegroundResolverTests: XCTestCase {
    func testRefreshPopulatesTheCacheBeforeReturningToTreeProjection() {
        let resolver = ZmxForegroundResolver(
            leaderProvider: { _ in ["agterm-a": 10] },
            leaderProbe: { .foreground($0 + 1) })

        resolver.refreshIfNeeded(now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11)
    }

    func testOneRefreshServesMultiplePaneLookupsUntilLifecycleInvalidation() {
        var listings = 0
        var leaders = ["agterm-a": pid_t(10), "agterm-b": pid_t(20)]
        let resolver = ZmxForegroundResolver(
            leaderProvider: { _ in
                listings += 1
                return leaders
            },
            leaderProbe: { .foreground($0 + 1) })
        let start = Date(timeIntervalSince1970: 100)

        resolver.refreshIfNeeded(now: start)
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11)
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-b"), 21)
        XCTAssertEqual(listings, 1)
        resolver.refreshIfNeeded(now: start.addingTimeInterval(1))
        XCTAssertEqual(listings, 1)

        leaders["agterm-a"] = 30
        resolver.noteLifecycleChange()
        resolver.refreshIfNeeded(now: start.addingTimeInterval(2))
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 31)
        XCTAssertEqual(listings, 2)
    }

    func testMissingNameInvalidatesTheNextRefresh() {
        var listings = 0
        var leaders: [String: pid_t] = [:]
        let resolver = ZmxForegroundResolver(
            leaderProvider: { _ in
                listings += 1
                return leaders
            },
            leaderProbe: { .foreground($0 + 1) })
        let start = Date(timeIntervalSince1970: 100)

        resolver.refreshIfNeeded(now: start)
        XCTAssertNil(resolver.foregroundPID(sessionName: "agterm-a"))
        leaders["agterm-a"] = 10
        resolver.refreshIfNeeded(now: start.addingTimeInterval(1))

        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11)
        XCTAssertEqual(listings, 2)
    }

    func testFailedRefreshKeepsLiveCacheAndDeadLeaderIsEvicted() {
        var failRefresh = false
        var dead = false
        let resolver = ZmxForegroundResolver(
            leaderProvider: { _ in failRefresh ? nil : ["agterm-a": 10] },
            leaderProbe: { dead ? .dead : .foreground($0 + 1) })
        let start = Date(timeIntervalSince1970: 100)

        resolver.refreshIfNeeded(now: start)
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11)
        failRefresh = true
        resolver.noteLifecycleChange()
        resolver.refreshIfNeeded(now: start.addingTimeInterval(1))
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11)

        dead = true
        XCTAssertNil(resolver.foregroundPID(sessionName: "agterm-a"))
        dead = false
        XCTAssertNil(resolver.foregroundPID(sessionName: "agterm-a"), "dead entries stay evicted until refresh")
    }

    func testNoForegroundDoesNotEvictALiveLeader() {
        var hasForeground = false
        let resolver = ZmxForegroundResolver(
            leaderProvider: { _ in ["agterm-a": 10] },
            leaderProbe: { hasForeground ? .foreground($0 + 1) : .noForeground })

        resolver.refreshIfNeeded(now: Date(timeIntervalSince1970: 100))
        XCTAssertNil(resolver.foregroundPID(sessionName: "agterm-a"))
        hasForeground = true
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11)
    }

    func testFreshSnapshotUsesItsTimeoutAndDoesNotMutateTheLiveCache() throws {
        var timeouts: [TimeInterval?] = []
        var leaders = ["agterm-a": pid_t(10)]
        let resolver = ZmxForegroundResolver(
            leaderProvider: {
                timeouts.append($0)
                return leaders
            },
            leaderProbe: { .foreground($0 + 1) })
        resolver.refreshIfNeeded(now: Date(timeIntervalSince1970: 100))
        leaders["agterm-a"] = 20

        let snapshot = try XCTUnwrap(resolver.freshSnapshot(timeout: 0.1))

        XCTAssertEqual(snapshot.foregroundPID(sessionName: "agterm-a"), 21)
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11)
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertNil(timeouts[0])
        XCTAssertEqual(timeouts[1], 0.1)
    }

    func testFailedFreshSnapshotReturnsNilWithoutExposingTheRetainedMap() {
        var fail = false
        let resolver = ZmxForegroundResolver(
            leaderProvider: { _ in fail ? nil : ["agterm-a": 10] },
            leaderProbe: { .foreground($0 + 1) })
        resolver.refreshIfNeeded(now: Date(timeIntervalSince1970: 100))
        fail = true

        XCTAssertNil(resolver.freshSnapshot(timeout: 0.1))
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11,
                       "capture failure must not change the live tree cache")
    }
}
