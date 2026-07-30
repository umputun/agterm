import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreOrganizationTests {
    @Test func moveSessionDoesNotTearDownSurface() {
        let store = makeStore()
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
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let moved = store.addSession(toWorkspace: work.id, cwd: "/moved")!
        let x = store.addSession(toWorkspace: personal.id, cwd: "/x")!
        store.moveSession(moved.id, toWorkspace: personal.id, at: -5)
        #expect(store.workspaces[1].sessions.map(\.id) == [moved.id, x.id])
    }

    @Test func moveSessionAppendsToTargetWorkspace() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.moveSession(a.id, toWorkspace: personal.id)
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.workspaces[1].sessions.map(\.id) == [b.id, a.id])
    }

    @Test func moveSessionInsertsAtIndex() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let moved = store.addSession(toWorkspace: work.id, cwd: "/moved")!
        let x = store.addSession(toWorkspace: personal.id, cwd: "/x")!
        let y = store.addSession(toWorkspace: personal.id, cwd: "/y")!
        store.moveSession(moved.id, toWorkspace: personal.id, at: 1)
        #expect(store.workspaces[1].sessions.map(\.id) == [x.id, moved.id, y.id])
    }

    @Test func moveSessionClampsOutOfRangeIndex() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let moved = store.addSession(toWorkspace: work.id, cwd: "/moved")!
        let x = store.addSession(toWorkspace: personal.id, cwd: "/x")!
        store.moveSession(moved.id, toWorkspace: personal.id, at: 99)
        #expect(store.workspaces[1].sessions.map(\.id) == [x.id, moved.id])
    }

    @Test func moveSessionPreservesSameInstance() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let session = store.addSession(toWorkspace: work.id, cwd: "/a")!
        session.customName = "build"
        store.moveSession(session.id, toWorkspace: personal.id)
        let movedRef = store.workspaces[1].sessions[0]
        #expect(movedRef === session)
        #expect(movedRef.customName == "build")
    }

    @Test func addSessionAppendsWhenIndexNil() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, b.id])
    }

    @Test func addSessionInsertsAtHead() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let head = store.addSession(toWorkspace: work.id, cwd: "/head", at: 0)!
        #expect(store.workspaces[0].sessions.map(\.id) == [head.id, a.id])
    }

    @Test func addSessionInsertsAtMiddle() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        let mid = store.addSession(toWorkspace: work.id, cwd: "/mid", at: 1)!
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, mid.id, b.id])
    }

    @Test func addSessionInsertsAtTail() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let tail = store.addSession(toWorkspace: work.id, cwd: "/tail", at: 1)!
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, tail.id])
    }

    @Test func addSessionClampsNegativeIndexToHead() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let clamped = store.addSession(toWorkspace: work.id, cwd: "/clamped", at: -5)!
        #expect(store.workspaces[0].sessions.map(\.id) == [clamped.id, a.id])
    }

    @Test func addSessionClampsOutOfRangeIndexToTail() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let clamped = store.addSession(toWorkspace: work.id, cwd: "/clamped", at: 99)!
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, clamped.id])
    }

    @Test func addSessionUnknownWorkspaceReturnsNilWithIndex() {
        let store = makeStore()
        #expect(store.addSession(toWorkspace: UUID(), cwd: "/a", at: 0) == nil)
    }

    @Test func setFlagTogglesAndPersists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        #expect(!a.flagged)
        store.setFlag(true, forSession: a.id)
        #expect(a.flagged)
        #expect(persistence.load().workspaces[0].sessions[0].flagged == true) // structural save hit disk
        store.setFlag(false, forSession: a.id)
        #expect(!a.flagged)
        #expect(persistence.load().workspaces[0].sessions[0].flagged == false)
    }

    @Test func setFlagUnknownIdIsNoOp() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setFlag(true, forSession: UUID()) // unknown id
        #expect(!a.flagged)
    }

    @Test func clearFlagsEmptiesTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.setFlag(true, forSession: a.id)
        store.setFlag(true, forSession: b.id)
        #expect(store.flaggedSessions.count == 2)
        store.clearFlags()
        #expect(store.flaggedSessions.isEmpty)
        #expect(!a.flagged)
        #expect(!b.flagged)
    }

    @Test func flaggedSessionsReturnsMatchesInTreeOrder() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: work.id, cwd: "/b")! // unflagged, skipped
        let c = store.addSession(toWorkspace: personal.id, cwd: "/c")!
        store.setFlag(true, forSession: c.id)
        store.setFlag(true, forSession: a.id)
        // workspace-then-session order, regardless of flag-setting order
        #expect(store.flaggedSessions.map(\.id) == [a.id, c.id])
    }

    @Test func flaggedSessionMovedToOtherWorkspaceResorts() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.setFlag(true, forSession: a.id)
        store.setFlag(true, forSession: b.id)
        #expect(store.flaggedSessions.map(\.id) == [a.id, b.id])
        store.moveSession(a.id, toWorkspace: personal.id)
        #expect(a.flagged)
        #expect(store.flaggedSessions.map(\.id) == [b.id, a.id])
    }

    @Test func ensureWorkspaceRevealNewWorkspaceFalsePreservesFocusOnCreate() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        store.setFocusedWorkspace(ws1.id)
        #expect(store.focusedWorkspaceIDs == [ws1.id] && store.focusEnabled)
        let two = store.addWorkspace(name: "two")
        #expect(store.focusedWorkspaceIDs == [ws1.id, two.id] && store.focusEnabled)
        // revealNewWorkspace: false backs `session.new --no-select --create-workspace`
        store.setFocusedWorkspace(ws1.id)
        let created = store.ensureWorkspace(named: "bg", revealNewWorkspace: false)
        #expect(created != nil)
        #expect(store.focusedWorkspaceIDs == [ws1.id] && store.focusEnabled)
        let reused = store.ensureWorkspace(named: "bg", revealNewWorkspace: true)
        #expect(reused?.id == created?.id)
        #expect(store.focusedWorkspaceIDs == [ws1.id] && store.focusEnabled)
    }

    @Test func newWorkspaceStartsExpanded() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        #expect(work.isExpanded)
        #expect(store.workspaces[0].isExpanded)
    }

    @Test func newWorkspaceCollapsedStartsCollapsed() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work", collapsed: true)
        #expect(!work.isExpanded)
        #expect(!store.workspaces[0].isExpanded)
    }

    @Test func setWorkspacesExpandedTogglesAndPersists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        store.setWorkspacesExpanded([a.id])
        #expect(store.workspaces[0].isExpanded)
        #expect(!store.workspaces[1].isExpanded)
        let loaded = persistence.load()
        #expect(loaded.workspaces[0].collapsed == nil)   // expanded → omitted
        #expect(loaded.workspaces[1].collapsed == true)  // collapsed → written
        _ = b
    }

    @Test func setWorkspacesExpandedUnchangedDoesNotWrite() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let a = store.addWorkspace(name: "a")
        // the sentinel proves the no-op setter skipped save(): a real write would replace this bad JSON.
        store.setWorkspacesExpanded([]) // a collapsed, saved
        let sentinelURL = dir.appendingPathComponent("workspaces.json")
        try! Data("{ not json }".utf8).write(to: sentinelURL)
        store.setWorkspacesExpanded([]) // same state → no save, sentinel survives
        #expect(try! Data(contentsOf: sentinelURL) == Data("{ not json }".utf8))
        _ = a
    }

    @Test func setWorkspaceExpandedTogglesSingleWorkspaceAndPersists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        store.setWorkspaceExpanded(a.id, expanded: false)
        #expect(!store.workspaces[0].isExpanded)
        #expect(store.workspaces[1].isExpanded) // b untouched — per-workspace, not whole-tree
        let loaded = persistence.load()
        #expect(loaded.workspaces[0].collapsed == true)
        #expect(loaded.workspaces[1].collapsed == nil)
        _ = b
    }

    @Test func setWorkspaceExpandedUnknownOrUnchangedIsNoOp() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        store.setWorkspaceExpanded(UUID(), expanded: false) // unknown id
        #expect(store.workspaces[0].isExpanded)
        store.setWorkspaceExpanded(a.id, expanded: true) // already expanded
        #expect(store.workspaces[0].isExpanded)
    }

    @Test func selectSessionWhileUnfocusedIsNoOpOnFocus() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.selectSession(a.id)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func closeFocusedSessionRevealingOtherWorkspaceDisablesTheFilter() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let only = store.addSession(toWorkspace: work.id, cwd: "/only")!
        _ = store.addSession(toWorkspace: personal.id, cwd: "/other")!
        store.selectSession(only.id)
        store.setFocusedWorkspace(work.id)
        store.closeSession(only.id) // reselects the personal session — outside the now-empty focused work
        #expect(store.activeSession != nil)
        #expect(store.workspace(forSession: store.selectedSessionID!)?.id == personal.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled)
    }

    @Test func removingTheOnlyMarkedWorkspaceReselectsOutsideAndDisablesTheFilter() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let activeInA = store.addSession(toWorkspace: a.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: b.id, cwd: "/b", select: false)!
        store.selectSession(activeInA.id)
        store.setFocusedWorkspace(a.id)
        #expect(store.selectedSessionID == activeInA.id)

        store.removeWorkspace(a.id)
        #expect(store.workspace(forSession: store.selectedSessionID!)?.id == b.id)
        #expect(store.focusedWorkspaceIDs.isEmpty && !store.focusEnabled)
    }

    @Test func removingAMarkedWorkspaceStaysInsideTheMarkedSet() {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        let unmarked = store.addWorkspace(name: "unmarked")
        let alsoMarked = store.addWorkspace(name: "also-marked")
        let active = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: unmarked.id, cwd: "/stray", select: false)!
        let survivor = store.addSession(toWorkspace: alsoMarked.id, cwd: "/keep", select: false)!
        store.selectSession(active.id)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusMembership(alsoMarked.id, member: true)
        store.setFocusEnabled(true)

        store.removeWorkspace(doomed.id)

        #expect(store.selectedSessionID == survivor.id)
        #expect(store.focusedWorkspaceIDs == [alsoMarked.id] && store.focusEnabled)
    }

    @Test func removingTheActiveWorkspaceInFlaggedModeStaysInsideTheFlaggedSet() {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        let unflagged = store.addWorkspace(name: "unflagged")
        let elsewhere = store.addWorkspace(name: "elsewhere")
        let active = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: unflagged.id, cwd: "/stray", select: false)!
        let survivor = store.addSession(toWorkspace: elsewhere.id, cwd: "/keep", select: false)!
        store.setFlag(true, forSession: active.id)
        store.setFlag(true, forSession: survivor.id)
        store.setSidebarMode(.flagged)
        store.selectSession(active.id)

        store.removeWorkspace(doomed.id)

        #expect(store.selectedSessionID == survivor.id)
        #expect(store.flaggedSessions.map(\.id) == [survivor.id])
    }

    @Test func softRemovingAMarkedWorkspaceStaysInsideTheMarkedSet() {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        let unmarked = store.addWorkspace(name: "unmarked")
        let alsoMarked = store.addWorkspace(name: "also-marked")
        let active = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: unmarked.id, cwd: "/stray", select: false)!
        let survivor = store.addSession(toWorkspace: alsoMarked.id, cwd: "/keep", select: false)!
        store.selectSession(active.id)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusMembership(alsoMarked.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.softRemoveWorkspace(doomed.id, grace: 60))

        #expect(store.selectedSessionID == survivor.id)
        #expect(store.focusedWorkspaceIDs == [alsoMarked.id] && store.focusEnabled)
    }

    @Test func removingTheLastFlaggedWorkspaceFallsBackToAnUnflaggedSurvivor() {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        let elsewhere = store.addWorkspace(name: "elsewhere")
        let active = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        let unflagged = store.addSession(toWorkspace: elsewhere.id, cwd: "/keep", select: false)!
        store.setFlag(true, forSession: active.id)
        store.setSidebarMode(.flagged)
        store.selectSession(active.id)

        store.removeWorkspace(doomed.id)

        #expect(store.navigableSessions.isEmpty)
        #expect(store.selectedSessionID == unflagged.id)
    }

    @Test func removingAMarkedWorkspacePrefersTheMostRecentVisibleSurvivor() {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        let alsoMarked = store.addWorkspace(name: "also-marked")
        let active = store.addSession(toWorkspace: doomed.id, cwd: "/a")!
        let first = store.addSession(toWorkspace: alsoMarked.id, cwd: "/first", select: false)!
        let recent = store.addSession(toWorkspace: alsoMarked.id, cwd: "/recent", select: false)!
        store.selectSession(recent.id)
        store.selectSession(active.id)
        store.setFocusMembership(doomed.id, member: true)
        store.setFocusMembership(alsoMarked.id, member: true)
        store.setFocusEnabled(true)

        store.removeWorkspace(doomed.id)

        #expect(store.selectedSessionID == recent.id)
        #expect(first.id != recent.id)
    }

    @Test func addSessionToOtherWorkspaceWhileFocusedDisablesTheFilter() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        _ = store.addSession(toWorkspace: work.id, cwd: "/w")!
        store.setFocusedWorkspace(work.id)
        let created = store.addSession(toWorkspace: other.id, cwd: "/o")! // a control add into another workspace
        #expect(store.selectedSessionID == created.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled)
    }

    @Test func addSessionInsideFocusedWorkspaceKeepsFocus() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.setFocusedWorkspace(work.id)
        let created = store.addSession(toWorkspace: work.id, cwd: "/b")! // the GUI new-session path lands here
        #expect(store.selectedSessionID == created.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func selectNilWhileFocusedKeepsFocus() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.selectSession(a.id)
        store.setFocusedWorkspace(work.id)
        store.selectSession(nil) // deselect reveals nothing, so focus is retained
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func moveActiveSessionOutOfFocusedWorkspaceDisablesTheFilter() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.selectSession(a.id)
        store.setFocusedWorkspace(work.id)
        store.moveSession(a.id, toWorkspace: other.id) // the active session leaves the focused workspace
        #expect(store.selectedSessionID == a.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && !store.focusEnabled)
    }

    @Test func moveNonActiveSessionOutOfFocusedWorkspaceKeepsFocus() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        store.selectSession(a.id)
        store.setFocusedWorkspace(work.id)
        store.moveSession(b.id, toWorkspace: other.id) // a non-active session leaves; focus must stand
        #expect(store.selectedSessionID == a.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func addWorkspaceWhileFocusedJoinsTheSetAndRevealsNew() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addWorkspace(name: "hidden")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.setFocusedWorkspace(work.id)
        let fresh = store.addWorkspace(name: "fresh") // a new (empty) workspace must become visible
        #expect(store.focusedWorkspaceIDs == [work.id, fresh.id] && store.focusEnabled) // the filter survives
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, fresh.id]) // `hidden` stays filtered out
    }

    @Test func flaggedSessionsIgnoreFocus() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.setFlag(true, forSession: a.id)
        store.setFlag(true, forSession: b.id)
        store.setFocusedWorkspace(work.id) // focus is orthogonal — it must NOT shrink the flagged set
        #expect(store.flaggedSessions.map(\.id) == [a.id, b.id]) // spans both workspaces, not just the focused one
    }

    @Test func setSameValuesAreNoOpWritesAndStable() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        store.setFlag(true, forSession: a.id)
        store.setSidebarMode(.flagged)
        store.setFocusedWorkspace(ws.id)
        let file = dir.appendingPathComponent("workspaces.json")
        try? FileManager.default.removeItem(at: file) // a no-op setter must NOT recreate the file
        store.setFlag(true, forSession: a.id)       // unchanged
        store.setSidebarMode(.flagged)              // unchanged
        store.setFocusedWorkspace(ws.id)            // unchanged
        #expect(!FileManager.default.fileExists(atPath: file.path)) // no write happened
        #expect(a.flagged)
        #expect(store.sidebarMode == .flagged)
        #expect(store.focusedWorkspaceIDs == [ws.id] && store.focusEnabled) // state stable across the no-op setters
    }

    @Test func moveActiveSessionKeepsItSelected() {
        let store = makeStore()
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
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        store.selectSession(b.id)
        store.moveSession(a.id, toWorkspace: personal.id)
        #expect(store.selectedSessionID == b.id)
    }

    @Test func moveLastSessionLeavesSourceEmpty() {
        let store = makeStore()
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
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        store.moveSession(a.id, toWorkspace: ws.id, at: 2)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func moveSessionWithinSameWorkspaceToCurrentSlotIsNoOp() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        store.moveSession(a.id, toWorkspace: ws.id, at: 0)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, b.id])
    }

    @Test func moveUnknownSessionIsIgnored() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.moveSession(UUID(), toWorkspace: personal.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
        #expect(store.workspaces[1].sessions.isEmpty)
    }

    @Test func moveToUnknownWorkspaceIsIgnored() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.moveSession(a.id, toWorkspace: UUID())
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
    }

    /// Builds a single-workspace tree (a, b, c) with the middle session (b) selected.
    static func makeReorderTree() -> (store: AppStore, ws: Workspace, ids: [UUID]) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws.id, cwd: "/c")!
        store.selectSession(b.id)
        return (store, ws, [a.id, b.id, c.id])
    }

    @Test func reorderSessionUp() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[1], .up)
        #expect(store.workspaces[0].sessions.map(\.id) == [ids[1], ids[0], ids[2]])
        #expect(store.selectedSessionID == ids[1])
    }

    @Test func reorderSessionDown() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[1], .down)
        #expect(store.workspaces[0].sessions.map(\.id) == [ids[0], ids[2], ids[1]])
        #expect(store.selectedSessionID == ids[1])
    }

    @Test func reorderSessionTop() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[2], .top)
        #expect(store.workspaces[0].sessions.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func reorderSessionBottom() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[0], .bottom)
        #expect(store.workspaces[0].sessions.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func reorderSessionUpAtTopIsNoOp() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[0], .up)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
        store.reorderSession(ids[0], .top)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
    }

    @Test func reorderSessionDownAtBottomIsNoOp() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(ids[2], .down)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
        store.reorderSession(ids[2], .bottom)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
    }

    @Test func reorderUnknownSessionIsIgnored() {
        let (store, _, ids) = Self.makeReorderTree()
        store.reorderSession(UUID(), .up)
        #expect(store.workspaces[0].sessions.map(\.id) == ids)
    }

    @Test func sessionLocationReportsWorkspaceIndexAndCount() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: personal.id, cwd: "/c")!

        let locA = store.sessionLocation(ofSession: a.id)
        #expect(locA?.workspace == work.id)
        #expect(locA?.index == 0)
        #expect(locA?.count == 2)

        let locB = store.sessionLocation(ofSession: b.id)
        #expect(locB?.workspace == work.id)
        #expect(locB?.index == 1)
        #expect(locB?.count == 2)

        let locC = store.sessionLocation(ofSession: c.id)
        #expect(locC?.workspace == personal.id)
        #expect(locC?.index == 0)
        #expect(locC?.count == 1)
    }

    @Test func sessionLocationOfUnknownSessionIsNil() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")!
        #expect(store.sessionLocation(ofSession: UUID()) == nil)
    }

    /// Builds a three-workspace tree [w0, w1, w2] with no sessions.
    static func makeWorkspaceReorderTree() -> (store: AppStore, ids: [UUID]) {
        let store = makeStore()
        let w0 = store.addWorkspace(name: "w0")
        let w1 = store.addWorkspace(name: "w1")
        let w2 = store.addWorkspace(name: "w2")
        return (store, [w0.id, w1.id, w2.id])
    }

    @Test func moveWorkspaceReordersWithinBounds() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.moveWorkspace(ids[0], at: 2)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func moveWorkspaceClampsIndexAtBothEnds() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.moveWorkspace(ids[1], at: 99)
        #expect(store.workspaces.map(\.id) == [ids[0], ids[2], ids[1]])
        store.moveWorkspace(ids[1], at: -5)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[0], ids[2]])
    }

    @Test func moveUnknownWorkspaceIsIgnored() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.moveWorkspace(UUID(), at: 0)
        #expect(store.workspaces.map(\.id) == ids)
    }

    @Test func reorderWorkspaceUp() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[1], .up)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[0], ids[2]])
    }

    @Test func reorderWorkspaceDown() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[1], .down)
        #expect(store.workspaces.map(\.id) == [ids[0], ids[2], ids[1]])
    }

    @Test func reorderWorkspaceTop() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[2], .top)
        #expect(store.workspaces.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func reorderWorkspaceBottom() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[0], .bottom)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func reorderWorkspaceAtEndsIsNoOp() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        store.reorderWorkspace(ids[0], .up)
        store.reorderWorkspace(ids[0], .top)
        store.reorderWorkspace(ids[2], .down)
        store.reorderWorkspace(ids[2], .bottom)
        #expect(store.workspaces.map(\.id) == ids)
    }

    @Test func reorderWorkspaceKeepsSelectedSession() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        let session = store.addSession(toWorkspace: ids[0], cwd: "/a")!
        store.selectSession(session.id)
        store.reorderWorkspace(ids[0], .bottom)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(store.selectedSessionID == session.id)
    }

    @Test func moveWorkspaceKeepsSelectedSession() {
        let (store, ids) = Self.makeWorkspaceReorderTree()
        let session = store.addSession(toWorkspace: ids[1], cwd: "/a")!
        store.selectSession(session.id)
        store.moveWorkspace(ids[1], at: 0)
        #expect(store.workspaces.map(\.id) == [ids[1], ids[0], ids[2]])
        #expect(store.selectedSessionID == session.id)
    }

    @Test func reorderOrderSurvivesSnapshotRestore() {
        let store = makeStore()
        let w0 = store.addWorkspace(name: "w0")
        let w1 = store.addWorkspace(name: "w1")
        let a = store.addSession(toWorkspace: w0.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: w0.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: w0.id, cwd: "/c")!
        store.reorderSession(a.id, .bottom) // sessions -> [b, c, a]
        store.reorderWorkspace(w1.id, .top) // workspaces -> [w1, w0]

        let snap = store.snapshot()
        let restored = makeStore()
        restored.restore(from: snap)
        #expect(restored.workspaces.map(\.id) == [w1.id, w0.id])
        #expect(restored.workspaces[1].sessions.map(\.id) == [b.id, c.id, a.id])
    }
}
