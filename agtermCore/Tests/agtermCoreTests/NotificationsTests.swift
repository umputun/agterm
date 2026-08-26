import Foundation
import Testing
@testable import agtermCore

struct NotificationsTests {
    @Test func identityRoundTripsForEveryPane() {
        let windowID = UUID()
        let sessionID = UUID()
        for pane in PaneRole.allCases {
            let identity = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: pane)
            let parsed = TerminalNotification.parseIdentity(identity)
            #expect(parsed?.windowID == windowID)
            #expect(parsed?.sessionID == sessionID)
            #expect(parsed?.pane == pane)
        }
    }

    @Test func identityFormatIsWindowColonSessionColonRole() {
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let identity = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: .split)
        #expect(identity == "00000000-0000-0000-0000-000000000000:11111111-1111-1111-1111-111111111111:split")
    }

    @Test func parseRejectsMalformed() {
        let win = UUID().uuidString
        let sess = UUID().uuidString
        #expect(TerminalNotification.parseIdentity("\(win):not-a-uuid:main") == nil)
        #expect(TerminalNotification.parseIdentity("\(win):\(sess):bogus") == nil)
        #expect(TerminalNotification.parseIdentity("not-a-uuid:\(sess):main") == nil)
        #expect(TerminalNotification.parseIdentity("\(sess):main") == nil) // missing windowID
        #expect(TerminalNotification.parseIdentity("no-colon") == nil)
        #expect(TerminalNotification.parseIdentity("") == nil)
    }

    @Test func isStaleTracksTheWindowHostingTheSessionNow() {
        let source = UUID()
        let destination = UUID()
        let identity = TerminalNotification.identity(windowID: source, sessionID: UUID(), pane: .main)
        #expect(TerminalNotification.isStale(identity: identity, currentWindowID: source) == false)
        #expect(TerminalNotification.isStale(identity: identity, currentWindowID: destination) == true)
        // unknown host: a plain window close, whose banner still reopens the window it names
        #expect(TerminalNotification.isStale(identity: identity, currentWindowID: nil) == false)
    }

    @Test func isStaleIgnoresIdentifiersThatAreNotSessionBanners() {
        #expect(TerminalNotification.isStale(identity: "keymap-diagnostics", currentWindowID: UUID()) == false)
        #expect(TerminalNotification.isStale(identity: "command-failure:build", currentWindowID: UUID()) == false)
    }

    @Test func shouldSweepTakesOnlyTheSessionsBannersDeliveredBeforeTheSweep() {
        let session = UUID()
        let source = UUID()
        let destination = UUID()
        let cutoff = Date()
        let before = cutoff.addingTimeInterval(-1)
        let after = cutoff.addingTimeInterval(1)
        let stale = TerminalNotification.identity(windowID: source, sessionID: session, pane: .main)
        let owned = TerminalNotification.identity(windowID: destination, sessionID: session, pane: .main)
        let other = TerminalNotification.identity(windowID: source, sessionID: UUID(), pane: .main)
        func sweep(_ identity: String, deliveredAt: Date, lastPostedAt: Date?) -> Bool {
            let banner = TerminalNotification.DeliveredBanner(identity: identity, deliveredAt: deliveredAt,
                                                              lastPostedAt: lastPostedAt)
            return TerminalNotification.shouldSweep(banner, sessionID: session, staleRelativeTo: destination,
                                                    cutoff: cutoff)
        }
        #expect(sweep(stale, deliveredAt: before, lastPostedAt: before))
        #expect(sweep(owned, deliveredAt: before, lastPostedAt: before) == false)
        #expect(sweep(other, deliveredAt: before, lastPostedAt: before) == false)
        // a banner the sweep's async query picked up after it started, e.g. the destination of a later move
        #expect(sweep(stale, deliveredAt: after, lastPostedAt: after) == false)
        // the query named an older banner, but the identity was reused after the sweep started: removing it
        // by identifier would take the newer banner that replaced it
        #expect(sweep(stale, deliveredAt: before, lastPostedAt: after) == false)
        // never posted by this launch, so only the delivery date decides
        #expect(sweep(stale, deliveredAt: before, lastPostedAt: nil))
    }

    @Test func shouldSweepWithoutAWindowTakesEveryEarlierBannerOfTheSession() {
        let session = UUID()
        let cutoff = Date()
        let identity = TerminalNotification.identity(windowID: UUID(), sessionID: session, pane: .split)
        func sweep(_ identity: String, deliveredAt: Date) -> Bool {
            let banner = TerminalNotification.DeliveredBanner(identity: identity, deliveredAt: deliveredAt,
                                                              lastPostedAt: nil)
            return TerminalNotification.shouldSweep(banner, sessionID: session, staleRelativeTo: nil, cutoff: cutoff)
        }
        #expect(sweep(identity, deliveredAt: cutoff.addingTimeInterval(-1)))
        #expect(sweep(identity, deliveredAt: cutoff.addingTimeInterval(1)) == false)
        #expect(sweep("keymap-diagnostics", deliveredAt: cutoff) == false)
    }

    @Test func retainedMoveRecordsKeepsOnlySessionsABannerCanStillReach() {
        let swept = UUID(), withBanner = UUID(), closed = UUID()
        let destination = UUID()
        let delivered = [
            TerminalNotification.identity(windowID: UUID(), sessionID: withBanner, pane: .main),
            "keymap-diagnostics",
        ]
        let records = [swept: destination, withBanner: destination, closed: destination]
        let kept = TerminalNotification.retainedMoveRecords(records, delivered: delivered, unsettled: [swept])
        #expect(kept == [swept: destination, withBanner: destination])
    }

    @Test func retainedMoveRecordsDropsEverythingWhenNothingIsDelivered() {
        let session = UUID()
        let kept = TerminalNotification.retainedMoveRecords([session: UUID()], delivered: [], unsettled: [UUID()])
        #expect(kept.isEmpty)
    }

    @Test func retainedMoveRecordsKeepsSessionsWithASubmissionOrSweepStillOutstanding() {
        let swept = UUID(), concurrent = UUID(), posting = UUID(), closed = UUID()
        let destination = UUID()
        let records = [swept: destination, concurrent: destination, posting: destination, closed: destination]
        let kept = TerminalNotification.retainedMoveRecords(records, delivered: [],
                                                           unsettled: [swept, concurrent, posting])
        #expect(kept == [swept: destination, concurrent: destination, posting: destination])
    }

    @Test func shouldDeliverSuppressesOnlyTheFocusedActivePane() {
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: true, appActive: true) == false)
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: true, appActive: false) == true)
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: false, appActive: true) == true)
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: false, appActive: false) == true)
    }
}
