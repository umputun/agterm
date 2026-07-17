import Foundation
import Testing
@testable import agtermCore

/// `AppStore.duplicateSession` — the store half of the sidebar's "Duplicate Session" row action and the
/// `session.duplicate` control command. The contract under test: same workspace, inserted directly after
/// the source, seeded with the source's LIVE cwd, and carrying over NOTHING else.
@MainActor
struct AppStoreDuplicateTests {
    @Test func duplicateSessionInsertsAfterSourceInSameWorkspaceAndSelects() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let first = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let last = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))

        let dupe = try! #require(store.duplicateSession(first.id))

        // lands directly AFTER its source, not appended at the end.
        #expect(store.workspaces[0].sessions.map(\.id) == [first.id, dupe.id, last.id])
        #expect(dupe.initialCwd == "/a")
        #expect(store.selectedSessionID == dupe.id)
    }

    /// The seed is the FOCUSED pane's cwd, not the primary's: a split focused on its non-primary pane
    /// duplicates into the split pane's directory (`focusedCwd`), not the primary's (`effectiveCwd`). Pins
    /// the `focusedCwd`-over-`effectiveCwd` choice — swapping the seed to `effectiveCwd` fails only here.
    @Test func duplicateSessionSeedsFromFocusedSplitPane() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let source = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/primary"))
        source.currentCwd = "/primary"
        source.isSplit = true
        source.hasSplit = true
        source.splitSurface = SpySurface() // a focused split always has a live split surface
        source.splitCwd = "/split-pane"
        source.splitFocused = true

        let dupe = try! #require(store.duplicateSession(source.id))

        // the duplicate opens where FOCUS is (the split pane), not the primary pane's cwd.
        #expect(dupe.initialCwd == "/split-pane")
    }

    @Test func duplicateSessionTracksLiveCwd() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let source = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/start"))
        source.currentCwd = "/moved" // an OSC 7 report after a `cd`

        let dupe = try! #require(store.duplicateSession(source.id))

        // the duplicate opens where the shell IS, not where it started.
        #expect(dupe.initialCwd == "/moved")
    }

    /// The directory-only contract: a duplicate is a plain new session, NOT a clone of the source's state.
    @Test func duplicateSessionCopiesOnlyTheDirectory() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let source = try! #require(store.addSession(toWorkspace: ws.id, cwd: "/a", command: "ssh host", name: "prod"))
        source.flagged = true
        source.isSplit = true
        source.hasSplit = true
        source.fontSize = 18

        let dupe = try! #require(store.duplicateSession(source.id))

        #expect(dupe.initialCwd == "/a")
        #expect(dupe.customName == nil) // auto basename, NOT "prod"
        #expect(dupe.initialCommand == nil)
        #expect(dupe.flagged == false)
        #expect(dupe.isSplit == false)
        #expect(dupe.hasSplit == false)
        #expect(dupe.fontSize == nil)
        #expect(dupe.id != source.id)
    }

    @Test func duplicateSessionOfUnknownSessionReturnsNil() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        store.addSession(toWorkspace: ws.id, cwd: "/a")
        #expect(store.duplicateSession(UUID()) == nil)
        #expect(store.workspaces[0].sessions.count == 1)
    }
}
