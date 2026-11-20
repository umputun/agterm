import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreRootTests {
    private func rooted(_ names: String...) -> AppStore {
        let store = makeStore()
        for name in names { store.addWorkspace(name: name, revealNewWorkspace: false) }
        store.ensureRoot()
        return store
    }

    @Test func aDirectlyBuiltStoreHasNoRoot() {
        let store = makeStore()
        store.addWorkspace(name: "one")
        #expect(store.rootWorkspace == nil)
        #expect(store.namedWorkspaces.map(\.name) == ["one"])
    }

    @Test func ensureRootMintsOneEmptyRootStoredLast() throws {
        let store = makeStore()
        store.addWorkspace(name: "one")
        #expect(store.ensureRoot())
        let root = try #require(store.rootWorkspace)
        #expect(root.name.isEmpty)
        #expect(root.sessions.isEmpty)
        #expect(store.workspaces.last?.id == root.id)
        #expect(!store.ensureRoot())
        #expect(store.workspaces.filter(\.isRoot).count == 1)
    }

    @Test func restoreFoldsASecondRootBeforeRepairingTheSelection() throws {
        let rootID = UUID()
        let first = SessionSnapshot(id: UUID(), customName: nil, cwd: "/a")
        let second = SessionSnapshot(id: UUID(), customName: nil, cwd: "/b")
        let snapshot = Snapshot(selectedSessionID: first.id, workspaces: [
            WorkspaceSnapshot(id: rootID, name: "", sessions: [first], root: true),
            WorkspaceSnapshot(id: UUID(), name: "one", sessions: []),
            WorkspaceSnapshot(id: UUID(), name: "", sessions: [second], root: true),
        ], focusedWorkspaceIDs: [rootID], focusEnabled: true)
        let store = makeStore()

        store.restore(from: snapshot)
        store.ensureRoot()

        #expect(store.workspaces.map(\.isRoot) == [false, true])
        #expect(store.rootWorkspace?.id == rootID)
        #expect(store.rootWorkspace?.sessions.map(\.id) == [first.id, second.id])
        #expect(store.selectedSessionID == first.id)
        #expect(store.focusEnabled)
    }

    @Test func namedAppendsMovesAndReordersKeepTheRootLast() throws {
        let store = rooted("one")
        let two = store.addWorkspace(name: "two")
        #expect(store.workspaces.map(\.name) == ["one", "two", ""])
        store.moveWorkspace(two.id, at: 99)
        #expect(store.workspaces.last?.isRoot == true)
        store.reorderWorkspace(try #require(store.namedWorkspaces.first).id, .bottom)
        #expect(store.namedWorkspaces.map(\.name) == ["two", "one"])
        #expect(store.workspaces.last?.isRoot == true)
    }

    @Test func theRootRefusesNamedOperations() throws {
        let store = rooted("one", "two")
        let root = try #require(store.rootWorkspace)
        let before = store.workspaces.map(\.id)
        store.moveWorkspace(root.id, at: 0)
        store.reorderWorkspace(root.id, .top)
        store.renameWorkspace(root.id, to: "renamed")
        store.setWorkspaceExpanded(root.id, expanded: false)
        store.setWorkspacesExpanded([])
        store.removeWorkspace(root.id)
        #expect(!store.softRemoveWorkspace(root.id, grace: 60))
        #expect(!store.setTint(SidebarTint(color: TintColor.red), forWorkspace: root.id))
        #expect(store.selectWorkspace(root.id) == nil)
        #expect(store.workspaces.map(\.id) == before)
        let after = try #require(store.rootWorkspace)
        #expect(after.name.isEmpty)
        #expect(after.isExpanded)
        #expect(after.tint == nil)
    }

    @Test func theCurrentWorkspaceIsTheRootWhileARootSessionIsSelected() throws {
        let store = rooted("one")
        #expect(!store.isCurrentWorkspaceRoot)
        let root = try #require(store.rootWorkspace)
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        _ = store.selectSession(top.id)
        #expect(store.isCurrentWorkspaceRoot)
        #expect(!makeStore().isCurrentWorkspaceRoot)
    }

    @Test func workspaceCountsReadNamedWorkspacesOnly() {
        let store = rooted("one")
        #expect(store.defaultWorkspaceName == "workspace 2")
        #expect(store.canRemoveWorkspace)
        #expect(!rooted().canRemoveWorkspace)
    }

    @Test func currentWorkspaceFallsBackToTheLastNamedThenTheRoot() throws {
        let store = rooted("one", "two")
        #expect(store.currentWorkspaceID == store.namedWorkspaces.last?.id)
        let lone = makeStore()
        lone.ensureRoot()
        #expect(lone.currentWorkspaceID == lone.rootWorkspace?.id)
    }

    @Test func aSelectedRootSessionMakesTheRootCurrent() throws {
        let store = rooted("one")
        let root = try #require(store.rootWorkspace)
        let session = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        _ = store.selectSession(session.id)
        #expect(store.currentWorkspaceID == root.id)
    }

    @Test func theRootReadsAsTopLevelSessionsAndANamedWorkspaceAsItsName() {
        #expect(Workspace(name: "", isRoot: true).label == "Top-Level Sessions")
        #expect(Workspace(name: "dev").label == "dev")
    }

    @Test func displayOrderPutsTheRootFirst() throws {
        let store = rooted("one")
        let root = try #require(store.rootWorkspace)
        let one = try #require(store.namedWorkspaces.first)
        let named = try #require(store.addSession(toWorkspace: one.id, cwd: "/one"))
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        #expect(store.visibleWorkspaces.map(\.id) == [root.id, one.id])
        #expect(store.navigableSessions.map(\.id) == [top.id, named.id])
    }

    @Test func flaggedOrderAndBatchMovesFollowDisplayOrder() throws {
        let store = rooted("one", "two")
        let root = try #require(store.rootWorkspace)
        let named = try #require(store.addSession(toWorkspace: store.namedWorkspaces[0].id, cwd: "/one"))
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        store.setFlag(true, forSession: named.id)
        store.setFlag(true, forSession: top.id)
        #expect(store.flaggedSessions.map(\.id) == [top.id, named.id])

        let target = store.namedWorkspaces[1].id
        #expect(store.moveSessions([named.id, top.id], toWorkspace: target) == 2)
        #expect(store.namedWorkspaces[1].sessions.map(\.id) == [top.id, named.id])
    }

    @Test func closingAWorkspacesLastSessionReselectsInDisplayOrder() throws {
        let store = rooted("one", "two")
        let root = try #require(store.rootWorkspace)
        let closing = try #require(store.addSession(toWorkspace: store.namedWorkspaces[0].id, cwd: "/one"))
        _ = try #require(store.addSession(toWorkspace: store.namedWorkspaces[1].id, cwd: "/two"))
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        let location = try #require(store.location(ofSession: closing.id))
        store.workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex)

        #expect(store.reselectionTarget(after: location) == top.id)
    }

    @Test func aDroppedSelectionPersistsTheFirstSessionInDisplayOrder() throws {
        let store = rooted("one")
        let root = try #require(store.rootWorkspace)
        _ = try #require(store.addSession(toWorkspace: store.namedWorkspaces[0].id, cwd: "/one", select: false))
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top", select: false))
        let remote = try #require(store.addSession(toWorkspace: root.id, cwd: "/r", select: false, remoteHost: "box"))
        store.sessionRecency = RecencyStack(items: [])
        store.selectedSessionID = remote.id

        #expect(store.snapshot().selectedSessionID == top.id)
    }

    @Test func theFocusFilterHidesRootSessionsUnlessTheRootIsAMember() throws {
        let store = rooted("one", "two")
        let root = try #require(store.rootWorkspace)
        let one = store.namedWorkspaces[0]
        store.setFocusMembership(one.id, member: true)
        store.setFocusEnabled(true)
        #expect(store.visibleWorkspaces.map(\.id) == [one.id])
        store.setFocusMembership(root.id, member: true)
        #expect(store.visibleWorkspaces.map(\.id) == [root.id, one.id])
        store.setFocusMembership(one.id, member: false)
        #expect(store.visibleWorkspaces.map(\.id) == [root.id])
    }

    @Test func theLastNamedWorkspaceIsRemovedAndARootSessionTakesTheSelection() throws {
        let store = rooted("one")
        let root = try #require(store.rootWorkspace)
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        let inner = try #require(store.addSession(toWorkspace: store.namedWorkspaces[0].id, cwd: "/one"))
        _ = store.selectSession(inner.id)
        #expect(store.canRemoveWorkspace)
        #expect(store.canCloseWorkspace)

        store.removeWorkspace(store.namedWorkspaces[0].id)

        #expect(store.namedWorkspaces.isEmpty)
        #expect(store.selectedSessionID == top.id)
        #expect(!store.canRemoveWorkspace)
    }

    @Test func theLastNamedWorkspaceSoftClosesIntoAnEmptyWindow() throws {
        let store = rooted("one")
        let inner = try #require(store.addSession(toWorkspace: store.namedWorkspaces[0].id, cwd: "/one"))
        _ = store.selectSession(inner.id)

        #expect(store.softRemoveWorkspace(store.namedWorkspaces[0].id))

        #expect(store.namedWorkspaces.isEmpty)
        #expect(store.selectedSessionID == nil)
    }

    @Test func theRootTargetNamesTheRootAndOtherTargetsResolveAsBefore() throws {
        let store = rooted("one")
        let root = try #require(store.rootWorkspace)

        #expect(store.resolveWorkspaceTarget("root") == .resolved(root.id))
        #expect(store.resolveWorkspaceTarget("active") == .resolved(store.namedWorkspaces[0].id))
        #expect(store.resolveWorkspaceTarget(root.id.uuidString) == .resolved(root.id))
        #expect(makeStore().resolveWorkspaceTarget("root") == .notFound)
    }

    @Test func theRootJoinsTheFocusSetAndSurvivesRestorePruning() throws {
        let store = rooted("one")
        let root = try #require(store.rootWorkspace)
        store.setFocusedWorkspace(root.id)
        #expect(store.focusedWorkspaceIDs == [root.id])
        #expect(store.focusEnabled)

        store.restoreFocus(ids: [root.id, UUID()], enabled: true)
        #expect(store.focusedWorkspaceIDs == [root.id])
        #expect(store.focusEnabled)

        store.setFocusMembership(root.id, member: false)
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)
    }

    @Test func selectingANamedSessionOutsideAFocusedRootTurnsTheFilterOff() throws {
        let store = rooted("one")
        let root = try #require(store.rootWorkspace)
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        let inner = try #require(store.addSession(toWorkspace: store.namedWorkspaces[0].id, cwd: "/one"))
        _ = store.selectSession(top.id)
        store.setFocusedWorkspace(root.id)

        _ = store.selectSession(inner.id)

        #expect(!store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [root.id])
    }

    @Test func workspaceNavigationFromARootSessionEntersTheNamedWorkspaces() throws {
        let store = rooted("one", "two")
        let root = try #require(store.rootWorkspace)
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        _ = store.selectSession(top.id)
        #expect(store.navigateWorkspace(.next)?.workspaceID == store.namedWorkspaces[0].id)

        _ = store.selectSession(top.id)
        #expect(store.navigateWorkspace(.previous)?.workspaceID == store.namedWorkspaces[1].id)
    }

    @Test func workspaceNavigationGoesNowhereWithNoVisibleNamedWorkspace() throws {
        let store = rooted("one")
        let root = try #require(store.rootWorkspace)
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        _ = store.selectSession(top.id)
        store.setFocusedWorkspace(root.id)

        #expect(!store.canStepWorkspaces)
        #expect(store.navigateWorkspace(.next) == nil)
    }

    @Test func workspaceNavigationStepsNamedWorkspacesOnly() throws {
        let store = rooted("one", "two")
        let root = try #require(store.rootWorkspace)
        _ = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        let one = try #require(store.addSession(toWorkspace: store.namedWorkspaces[0].id, cwd: "/one"))
        let two = try #require(store.addSession(toWorkspace: store.namedWorkspaces[1].id, cwd: "/two"))
        _ = store.selectSession(two.id)
        #expect(store.navigateWorkspace(.next)?.workspaceID == store.namedWorkspaces[0].id)
        #expect(store.selectedSessionID == one.id)
        #expect(store.navigateWorkspace(.previous)?.workspaceID == store.namedWorkspaces[1].id)
    }

    @Test func theTreeMarksTheRootInStoredOrderWithItsFocusAndActiveState() throws {
        let store = rooted("one")
        let root = try #require(store.rootWorkspace)
        let top = try #require(store.addSession(toWorkspace: root.id, cwd: "/top"))
        _ = store.selectSession(top.id)
        store.setFocusMembership(root.id, member: true)

        let nodes = store.controlTree().workspaces

        #expect(nodes.map(\.root) == [nil, true])
        let node = try #require(nodes.last)
        #expect(node.id == root.id.uuidString)
        #expect(node.name.isEmpty)
        #expect(node.active)
        #expect(node.focused == true)
        #expect(node.sessions.map(\.id) == [top.id.uuidString])
        let named = try #require(String(data: try JSONEncoder().encode(nodes[0]), encoding: .utf8))
        #expect(!named.contains("\"root\""))
    }

    @Test func reopeningAClosedWorkspacePlacesItBeforeTheRoot() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        store.addWorkspace(name: "one")
        let two = store.addWorkspace(name: "two")
        store.ensureRoot()
        store.removeWorkspace(two.id)
        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == two.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.workspaces.map(\.name) == ["one", "two", ""])
    }

    @Test func undoingAWorkspaceRemovalPlacesItBeforeTheRoot() throws {
        let store = rooted("one", "two")
        let two = store.namedWorkspaces[1]
        #expect(store.softRemoveWorkspace(two.id, grace: 60))
        defer { store.finalizeAllPendingCloses() }
        #expect(store.undoPendingClose())
        #expect(store.workspaces.map(\.name) == ["one", "two", ""])
    }

    @Test func aRemoteWorkspaceStepCountsNamedWorkspacesOnly() throws {
        let store = rooted("one", "two", "three")
        let first = try #require(store.namedWorkspaces.first)

        #expect(store.workspaceStep(moving: first.id, to: 2) == "bottom")
        #expect(store.workspaceStep(moving: first.id, to: 1) == "down")
        #expect(store.workspaceStep(moving: first.id, to: 0) == nil)
        #expect(store.workspaceStep(moving: try #require(store.rootWorkspace).id, to: 0) == nil)
    }
}
