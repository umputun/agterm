import Foundation
import Testing
@testable import agtermCore

struct RemoteRetryBackoffTests {
    @Test func theScheduleDoublesToThirtySecondsThenSlowsDown() {
        let delays = (1...10).map(RemoteRetryBackoff.delay(afterFailures:))
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30, 256, 300])
    }
}

struct RemoteLinkNoticeTests {
    @Test func theWrappersTitleRoundTrips() throws {
        let notice = try #require(RemoteLinkNotice(title: RemoteLinkNotice.title(nonce: "n1")))
        #expect(notice.nonce == "n1")
    }

    @Test(arguments: ["agterm-remote;n1", "agterm-remote;n1:gone", "zmx-role;n1:leader:1", "build"])
    func anyOtherTitleIsNotANotice(_ title: String) {
        #expect(RemoteLinkNotice(title: title) == nil)
    }
}

@MainActor
struct RemoteReconnectBookTests {
    let pane = UUID()
    let session = UUID()
    let t0 = Date(timeIntervalSince1970: 1_000)

    private func waiting(cover: Bool = false) -> RemoteReconnectBook {
        let book = RemoteReconnectBook()
        book.wait(pane: pane, session: session, host: "mini", cover: cover, now: t0)
        return book
    }

    @Test func theFirstProbeIsImmediateAndNeverStartedTwice() {
        let book = waiting()
        #expect(book.due(now: t0) == [pane])
        #expect(book.due(now: t0.addingTimeInterval(60)).isEmpty)
        #expect(book.waiting(pane: pane))
    }

    @Test func aFailedProbeBacksOff() {
        let book = waiting()
        _ = book.due(now: t0)
        #expect(book.finished(pane: pane, ok: false, now: t0) == nil)
        #expect(book.due(now: t0.addingTimeInterval(0.5)).isEmpty)
        #expect(book.due(now: t0.addingTimeInterval(1)) == [pane])
        _ = book.finished(pane: pane, ok: false, now: t0.addingTimeInterval(1))
        #expect(book.due(now: t0.addingTimeInterval(2.5)).isEmpty)
        #expect(book.due(now: t0.addingTimeInterval(3)) == [pane])
    }

    @Test func aProbeThatAnswersEndsTheWaitAndCarriesTheCover() throws {
        let book = waiting(cover: true)
        _ = book.due(now: t0)
        let entry = try #require(book.finished(pane: pane, ok: true, now: t0))
        #expect(entry.session == session && entry.host == "mini" && entry.cover)
        #expect(!book.waiting(pane: pane))
        #expect(book.isEmpty)
    }

    @Test func retryNowMakesALaterProbeDueButNotASecondConcurrentOne() {
        let book = waiting()
        for step in 0..<6 {
            _ = book.due(now: t0.addingTimeInterval(Double(step) * 100))
            _ = book.finished(pane: pane, ok: false, now: t0.addingTimeInterval(Double(step) * 100))
        }
        let later = t0.addingTimeInterval(501)
        #expect(book.due(now: later).isEmpty)
        book.retryNow(pane: pane, now: later)
        #expect(book.due(now: later) == [pane])
        book.retryNow(pane: pane, now: later)
        #expect(book.due(now: later).isEmpty)
    }

    @Test func aCancelledPanesProbeResultIsDropped() {
        let book = waiting()
        _ = book.due(now: t0)
        book.cancel(pane: pane)
        #expect(book.finished(pane: pane, ok: true, now: t0) == nil)
        #expect(book.isEmpty)
    }

    @Test func aPaneThatLosesTheLinkSoonAfterAttachingKeepsItsBackoff() {
        let book = waiting()
        _ = book.due(now: t0)
        _ = book.finished(pane: pane, ok: false, now: t0)
        _ = book.due(now: t0.addingTimeInterval(1))
        _ = book.finished(pane: pane, ok: true, now: t0.addingTimeInterval(1))

        book.wait(pane: pane, session: session, host: "mini", cover: false, now: t0.addingTimeInterval(5))
        #expect(book.due(now: t0.addingTimeInterval(6)).isEmpty)
        #expect(book.due(now: t0.addingTimeInterval(7)) == [pane])
    }

    @Test func aPaneThatLosesTheLinkLongAfterStartsOver() {
        let book = waiting()
        _ = book.due(now: t0)
        _ = book.finished(pane: pane, ok: true, now: t0)

        book.wait(pane: pane, session: session, host: "mini", cover: false, now: t0.addingTimeInterval(600))
        #expect(book.due(now: t0.addingTimeInterval(600)) == [pane])
    }

    @Test func waitingAgainWhileWaitingKeepsTheProbeInFlight() {
        let book = waiting()
        #expect(book.due(now: t0) == [pane])
        book.wait(pane: pane, session: UUID(), host: "other", cover: true, now: t0)
        #expect(book.due(now: t0).isEmpty)
        #expect(book.finished(pane: pane, ok: true, now: t0)?.host == "mini")
    }
}
