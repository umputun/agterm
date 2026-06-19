import Foundation
import Testing
@testable import agtCore

@MainActor
struct AppStoreTests {
    /// A store backed by a throwaway temp directory so mutation-time saves never
    /// touch the real Application Support path. PersistenceStore creates the
    /// directory lazily on first write.
    static func makeStore() -> AppStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agt-tests-\(UUID().uuidString)")
        return AppStore(persistence: PersistenceStore(directory: dir))
    }

    @Test func emptyStoreHasNoSelectionOrActiveSession() {
        let store = Self.makeStore()
        #expect(store.workspaces.isEmpty)
        #expect(store.selectedSessionID == nil)
        #expect(store.activeSession == nil)
    }

    @Test func defaultWorkspaceNameCountsUp() {
        let store = Self.makeStore()
        #expect(store.defaultWorkspaceName == "workspace 1")
        store.addWorkspace(name: "work")
        #expect(store.defaultWorkspaceName == "workspace 2")
    }

    @Test func currentWorkspaceFollowsSelectionThenFallsBackToLast() {
        let store = Self.makeStore()
        #expect(store.currentWorkspaceID == nil)
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        // no selection -> last workspace.
        #expect(store.currentWorkspaceID == personal.id)
        // a selected session pins its owning workspace.
        let session = try! #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        #expect(store.currentWorkspaceID == work.id)
        // deselecting falls back to the last workspace again.
        store.selectSession(nil)
        #expect(store.currentWorkspaceID == personal.id)
    }

    @Test func addWorkspaceAppends() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        #expect(store.workspaces.map(\.id) == [work.id, personal.id])
        #expect(store.workspaces.map(\.name) == ["work", "personal"])
    }

    @Test func addSessionAppendsAndSelects() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/tmp")
        let unwrapped = try! #require(session)
        #expect(store.workspaces[0].sessions.map(\.id) == [unwrapped.id])
        #expect(unwrapped.initialCwd == "/tmp")
        #expect(store.selectedSessionID == unwrapped.id)
        #expect(store.activeSession?.id == unwrapped.id)
    }

    @Test func addSessionToUnknownWorkspaceReturnsNil() {
        let store = Self.makeStore()
        #expect(store.addSession(toWorkspace: UUID(), cwd: "/tmp") == nil)
        #expect(store.selectedSessionID == nil)
    }

    @Test func selectSessionUpdatesActive() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        #expect(store.activeSession?.id == a.id)
        store.selectSession(b.id)
        #expect(store.activeSession?.id == b.id)
    }

    @Test func selectUnknownSessionIsIgnored() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectSession(UUID())
        #expect(store.selectedSessionID == a.id)
    }

    @Test func workspaceForSessionDerivesOwner() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inWork = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let inPersonal = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        #expect(store.workspace(forSession: inWork.id)?.id == work.id)
        #expect(store.workspace(forSession: inPersonal.id)?.id == personal.id)
        #expect(store.workspace(forSession: UUID()) == nil)
    }

    @Test func closeNonActiveSessionKeepsSelection() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(b.id)
        store.closeSession(a.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id])
        #expect(store.selectedSessionID == b.id)
    }

    @Test func closeActiveSessionReselectsNext() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(a.id)
        store.closeSession(a.id)
        #expect(store.selectedSessionID == b.id)
        #expect(store.activeSession?.id == b.id)
    }

    @Test func closeActiveLastSessionReselectsPrevious() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.selectSession(b.id)
        store.closeSession(b.id)
        #expect(store.selectedSessionID == a.id)
    }

    @Test func closeActiveSessionFallsBackToOtherWorkspace() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let other = store.addSession(toWorkspace: personal.id, cwd: "/other")!
        let only = store.addSession(toWorkspace: work.id, cwd: "/only")!
        store.selectSession(only.id)
        store.closeSession(only.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.selectedSessionID == other.id)
    }

    @Test func closeLastSessionClearsSelection() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let only = store.addSession(toWorkspace: ws.id, cwd: "/only")!
        store.closeSession(only.id)
        #expect(store.selectedSessionID == nil)
        #expect(store.activeSession == nil)
    }

    @Test func closeSessionTearsDownSurface() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let surface = SpySurface()
        session.surface = surface
        store.closeSession(session.id)
        #expect(surface.teardownCount == 1)
    }

    @Test func closeSessionTearsDownSplitSurface() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let split = SpySurface()
        session.splitSurface = split
        store.closeSession(session.id)
        #expect(split.teardownCount == 1)
    }

    @Test func removeWorkspaceTearsDownSessionsAndPrunesRecency() {
        let store = Self.makeStore()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        let session = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        let surface = SpySurface(); session.surface = surface
        let split = SpySurface(); session.splitSurface = split
        store.removeWorkspace(doomed.id)
        #expect(store.workspaces.map(\.id) == [keep.id])
        #expect(surface.teardownCount == 1)
        #expect(split.teardownCount == 1)
        #expect(!store.sessionRecency.items.contains(session.id))
    }

    @Test func removeWorkspaceReselectsWhenActiveInside() {
        let store = Self.makeStore()
        let keep = store.addWorkspace(name: "keep")
        let kept = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        let doomed = store.addWorkspace(name: "doomed")
        let active = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        store.selectSession(active.id)
        store.removeWorkspace(doomed.id)
        #expect(store.selectedSessionID == kept.id)
    }

    @Test func removeWorkspaceLeavesSelectionWhenActiveElsewhere() {
        let store = Self.makeStore()
        let keep = store.addWorkspace(name: "keep")
        let active = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addSession(toWorkspace: doomed.id, cwd: "/d")!
        store.selectSession(active.id)
        store.removeWorkspace(doomed.id)
        #expect(store.selectedSessionID == active.id)
    }

    @Test func removeWorkspaceKeepsAtLeastOne() {
        let store = Self.makeStore()
        let only = store.addWorkspace(name: "only")
        #expect(store.canRemoveWorkspace == false)
        store.removeWorkspace(only.id)
        #expect(store.workspaces.map(\.id) == [only.id])
    }

    @Test func toggleSplitFlipsFlag() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.isSplit == false)
        store.toggleSplit(session.id)
        #expect(session.isSplit == true)
        store.toggleSplit(session.id)
        #expect(session.isSplit == false)
    }

    @Test func closeSplitHidesAndTearsDownSurface() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        session.isSplit = true
        let split = SpySurface()
        session.splitSurface = split
        store.closeSplit(session.id)
        #expect(session.isSplit == false)
        #expect(session.splitSurface == nil)
        #expect(split.teardownCount == 1)
    }

    @Test func openOverlaySetsCommandAndFlag() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(store.openOverlay(session.id, command: "revdiff", cwd: "/b") == true)
        #expect(session.overlayActive == true)
        #expect(session.overlayCommand == "revdiff")
        #expect(session.overlayCwd == "/b")
        // a second open while one is active is a no-op.
        #expect(store.openOverlay(session.id, command: "other") == false)
        #expect(session.overlayCommand == "revdiff")
    }

    @Test func closeOverlayTearsDownAndClears() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openOverlay(session.id, command: "revdiff")
        let overlay = SpySurface()
        session.overlaySurface = overlay
        #expect(store.closeOverlay(session.id) == true)
        #expect(session.overlayActive == false)
        #expect(session.overlaySurface == nil)
        #expect(session.overlayCommand == nil)
        #expect(overlay.teardownCount == 1)
        // closing again is a no-op.
        #expect(store.closeOverlay(session.id) == false)
    }

    @Test func closeSessionTearsDownOverlaySurface() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.openOverlay(session.id, command: "revdiff")
        let overlay = SpySurface()
        session.overlaySurface = overlay
        store.closeSession(session.id)
        #expect(overlay.teardownCount == 1)
    }

    @Test func selectionUpdatesRecencyMostRecentFirst() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        #expect(store.sessionRecency.items == [b.id, a.id]) // b selected last
        store.selectSession(a.id)
        #expect(store.sessionRecency.items == [a.id, b.id]) // a now front, b is the previous
        #expect(store.sessionRecency.items[1] == b.id)
    }

    @Test func closeSessionRemovesFromRecency() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.closeSession(b.id)
        #expect(!store.sessionRecency.items.contains(b.id))
        #expect(store.sessionRecency.items == [a.id])
    }

    @Test func setFontSizeRecordsValue() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(session.fontSize == nil)
        store.setFontSize(session.id, 16)
        #expect(session.fontSize == 16)
        store.setFontSize(session.id, 16) // unchanged: no-op, value unchanged
        #expect(session.fontSize == 16)
        store.setFontSize(session.id, 13)
        #expect(session.fontSize == 13)
    }

    @Test func resetSessionFontSizesClearsAllOverrides() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.setFontSize(a.id, 16)
        store.setFontSize(b.id, 18)
        store.resetSessionFontSizes()
        #expect(a.fontSize == nil)
        #expect(b.fontSize == nil)
    }

    @Test func setFontSizeUnknownSessionIsIgnored() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setFontSize(UUID(), 20)
        #expect(session.fontSize == nil)
    }

    @Test func closeUnknownSessionIsIgnored() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.selectSession(a.id)
        store.closeSession(UUID())
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
        #expect(store.selectedSessionID == a.id)
    }

    @Test func moveSessionDoesNotTearDownSurface() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let surface = SpySurface()
        session.surface = surface
        store.moveSession(session.id, toWorkspace: personal.id)
        #expect(surface.teardownCount == 0)
        #expect(store.workspaces[1].sessions[0].surface === surface)
    }

    @Test func moveSessionClampsNegativeIndex() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let moved = store.addSession(toWorkspace: work.id, cwd: "/moved")!
        let x = store.addSession(toWorkspace: personal.id, cwd: "/x")!
        store.moveSession(moved.id, toWorkspace: personal.id, at: -5)
        #expect(store.workspaces[1].sessions.map(\.id) == [moved.id, x.id])
    }

    @Test func renameUnknownWorkspaceIsIgnored() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        store.renameWorkspace(UUID(), to: "renamed")
        #expect(store.workspaces.map(\.name) == ["work"])
        #expect(store.workspaces[0].id == ws.id)
    }

    @Test func mutationSurvivesSaveFailure() {
        let unwritable = URL(fileURLWithPath: "/dev/null/agt-cannot-write")
        let store = AppStore(persistence: PersistenceStore(directory: unwritable))
        let ws = store.addWorkspace(name: "work")
        // save() to an unwritable directory is swallowed; the in-memory mutation stands.
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")
        #expect(session != nil)
        #expect(store.workspaces[0].sessions.count == 1)
    }

    @Test func renameSessionSetsCustomName() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.renameSession(session.id, to: "build")
        #expect(session.customName == "build")
        #expect(session.displayName == "build")
    }

    @Test func renameSessionWithBlankClearsCustomName() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/Users/umputun/foo")!
        store.renameSession(session.id, to: "build")
        store.renameSession(session.id, to: "   ")
        #expect(session.customName == nil)
        #expect(session.displayName == "foo")
    }

    @Test func renameSessionTrimsWhitespace() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.renameSession(session.id, to: "  build  ")
        #expect(session.customName == "build")
    }

    @Test func renameWorkspaceSetsName() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        store.renameWorkspace(ws.id, to: "personal")
        #expect(store.workspaces[0].name == "personal")
    }

    @Test func renameWorkspaceWithBlankIsIgnored() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        store.renameWorkspace(ws.id, to: "   ")
        #expect(store.workspaces[0].name == "work")
    }

    @Test func moveSessionAppendsToTargetWorkspace() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.moveSession(a.id, toWorkspace: personal.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.workspaces[1].sessions.map(\.id) == [b.id, a.id])
    }

    @Test func moveSessionInsertsAtIndex() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let moved = store.addSession(toWorkspace: work.id, cwd: "/moved")!
        let x = store.addSession(toWorkspace: personal.id, cwd: "/x")!
        let y = store.addSession(toWorkspace: personal.id, cwd: "/y")!
        store.moveSession(moved.id, toWorkspace: personal.id, at: 1)
        #expect(store.workspaces[1].sessions.map(\.id) == [x.id, moved.id, y.id])
    }

    @Test func moveSessionClampsOutOfRangeIndex() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let moved = store.addSession(toWorkspace: work.id, cwd: "/moved")!
        let x = store.addSession(toWorkspace: personal.id, cwd: "/x")!
        store.moveSession(moved.id, toWorkspace: personal.id, at: 99)
        #expect(store.workspaces[1].sessions.map(\.id) == [x.id, moved.id])
    }

    @Test func moveSessionPreservesSameInstance() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        session.customName = "build"
        store.moveSession(session.id, toWorkspace: personal.id)
        let movedRef = store.workspaces[1].sessions[0]
        #expect(movedRef === session)
        #expect(movedRef.customName == "build")
    }

    @Test func moveActiveSessionKeepsItSelected() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.selectSession(a.id)
        store.moveSession(a.id, toWorkspace: personal.id)
        #expect(store.selectedSessionID == a.id)
        #expect(store.activeSession?.id == a.id)
        #expect(store.workspace(forSession: a.id)?.id == personal.id)
    }

    @Test func moveNonActiveSessionLeavesSelectionUntouched() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        store.selectSession(b.id)
        store.moveSession(a.id, toWorkspace: personal.id)
        #expect(store.selectedSessionID == b.id)
    }

    @Test func moveLastSessionLeavesSourceEmpty() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let only = store.addSession(toWorkspace: work.id, cwd: "/only")!
        store.selectSession(only.id)
        store.moveSession(only.id, toWorkspace: personal.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.workspaces[1].sessions.map(\.id) == [only.id])
        #expect(store.selectedSessionID == only.id)
    }

    @Test func moveSessionWithinSameWorkspaceReorders() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        store.moveSession(a.id, toWorkspace: ws.id, at: 2)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func moveSessionWithinSameWorkspaceToCurrentSlotIsNoOp() {
        let store = Self.makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.moveSession(a.id, toWorkspace: ws.id, at: 0)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, b.id])
    }

    @Test func moveUnknownSessionIsIgnored() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.moveSession(UUID(), toWorkspace: personal.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
        #expect(store.workspaces[1].sessions.isEmpty)
    }

    @Test func moveToUnknownWorkspaceIsIgnored() {
        let store = Self.makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.moveSession(a.id, toWorkspace: UUID())
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
    }
}

private final class SpySurface: TerminalSurface {
    var teardownCount = 0
    func teardown() { teardownCount += 1 }
}
