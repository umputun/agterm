import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreCloseSelectionAboveTests {
    @Test func closingAMiddleRowSelectsTheRowAboveOverTheRecentOne() throws {
        let store = makeStore()
        store.closeSelection = .above
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let third = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        store.selectSession(third.id)
        store.selectSession(second.id)

        store.closeSession(second.id)
        #expect(store.selectedSessionID == first.id)
    }

    @Test func closingTheTopRowSelectsTheRowBelow() throws {
        let store = makeStore()
        store.closeSelection = .above
        let upper = store.addWorkspace(name: "upper")
        let work = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: upper.id, cwd: "/u"))
        let top = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let below = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let recent = try #require(store.addSession(toWorkspace: work.id, cwd: "/c"))
        store.selectSession(recent.id)
        store.selectSession(top.id)

        store.closeSession(top.id)
        #expect(store.selectedSessionID == below.id)
    }

    @Test func softCloseHonorsAbove() throws {
        let store = makeStore()
        store.closeSelection = .above
        let ws = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let third = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        store.selectSession(third.id)
        store.selectSession(second.id)

        #expect(store.softCloseSession(second.id, grace: 60))
        #expect(store.selectedSessionID == first.id)
    }

    @Test func emptyingTheWorkspaceFallsBackToTheRecentSurvivor() throws {
        let store = makeStore()
        store.closeSelection = .above
        let work = store.addWorkspace(name: "work")
        let lone = store.addWorkspace(name: "lone")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let cameFrom = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let only = try #require(store.addSession(toWorkspace: lone.id, cwd: "/x"))
        store.selectSession(cameFrom.id)
        store.selectSession(only.id)

        store.closeSession(only.id)
        #expect(store.selectedSessionID == cameFrom.id)
    }

    @Test func flatFlaggedViewSkipsAFlaggedRowAboveFromAnotherWorkspace() throws {
        let store = makeStore()
        store.closeSelection = .above
        let other = store.addWorkspace(name: "other")
        let work = store.addWorkspace(name: "work")
        let elsewhere = try #require(store.addSession(toWorkspace: other.id, cwd: "/x"))
        let closing = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/unflagged"))
        let nearestBelow = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let recentBelow = try #require(store.addSession(toWorkspace: work.id, cwd: "/c"))
        for session in [elsewhere, closing, nearestBelow, recentBelow] { store.setFlag(true, forSession: session.id) }
        store.sidebarMode = .flagged
        store.selectSession(recentBelow.id)
        store.selectSession(elsewhere.id)
        store.selectSession(closing.id)

        store.closeSession(closing.id)
        #expect(store.selectedSessionID == nearestBelow.id)
    }

    @Test func recentStaysTheDefault() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let third = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        store.selectSession(third.id)
        store.selectSession(second.id)

        store.closeSession(second.id)
        #expect(store.closeSelection == .recent)
        #expect(store.selectedSessionID == third.id)
    }
}
