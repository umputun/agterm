import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreHeadlessPaneTests {
    @Test func aHeadlessPrimaryExitPromotesALiveSplitDaemon() {
        let (store, session) = makeHeadlessSession(split: true)
        let primary = session.paneIdentity
        let split = session.splitPaneIdentity!

        #expect(store.closePrimaryPane(session.id) == .promoted)
        #expect(session.paneIdentity == split)
        #expect(session.splitPaneIdentity == nil)
        #expect(!session.hasSplit)
        #expect(session.daemonBackedPanes == [split])
        #expect(!session.daemonBackedPanes.contains(primary))
    }

    @Test func aHeadlessPrimaryExitClosesWhenTheSplitHasNoDaemon() {
        let (store, session) = makeHeadlessSession(split: true)
        session.daemonBackedPanes.remove(session.splitPaneIdentity!)

        #expect(store.closePrimaryPane(session.id) == .closed)
        #expect(store.session(withID: session.id) == nil)
    }

    @Test func aHeadlessCloseSplitDropsTheSplitDaemon() {
        let (store, session) = makeHeadlessSession(split: true)
        let primary = session.paneIdentity

        store.closeSplit(session.id)

        #expect(session.daemonBackedPanes == [primary])
        #expect(session.splitPaneIdentity == nil)
    }

    @Test func aHeadlessSplitExitCollapsesToTheLivePrimary() {
        let (store, session) = makeHeadlessSession(split: true)

        store.closeSplitPane(session.id)

        #expect(store.session(withID: session.id) != nil)
        #expect(!session.hasSplit)
        #expect(session.daemonBackedPanes == [session.paneIdentity])
    }

    @Test func aHeadlessSplitExitCollapsesWhenItsOwnDaemonIsAlreadyGone() {
        let (store, session) = makeHeadlessSession(split: true)
        session.daemonBackedPanes.remove(session.splitPaneIdentity!)

        store.closeSplitPane(session.id)

        #expect(store.session(withID: session.id) != nil)
        #expect(!session.hasSplit)
        #expect(session.daemonBackedPanes == [session.paneIdentity])
    }

    @Test func aHeadlessSplitExitWithoutAPrimaryDaemonClosesTheSession() {
        let (store, session) = makeHeadlessSession(split: true)
        session.daemonBackedPanes.remove(session.paneIdentity)

        store.closeSplitPane(session.id)

        #expect(store.session(withID: session.id) == nil)
    }
}
