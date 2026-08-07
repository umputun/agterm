import Foundation
import Testing
@testable import agtermCore

/// `AppStore` nesting operations: create-child placement, `sessionSubtreeIDs`, `reparentSession`,
/// `setSessionExpanded`, subtree-aware `moveSession`, and cascade close (hard `closeSession` and the
/// grace-timer `softCloseSession`/`softCloseSessions`).
@MainActor
struct AppStoreNestingTests {
    @Test func addSessionWithParentInsertsAtLastChildSlotPreservingContiguity() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, b.id])

        let c = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c", parentID: a.id))
        #expect(c.parentID == a.id)
        // c is a's only child so far: it lands immediately after a, ahead of the unrelated top-level b.
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, c.id, b.id])

        let d = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d", parentID: a.id))
        #expect(d.parentID == a.id)
        // d joins as a's LAST child: after c (a's existing child), still ahead of b.
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, c.id, d.id, b.id])
    }

    @Test func addSessionWithParentNestsAGrandchildAtTheGrandparentSlot() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let c = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c", parentID: a.id))
        let d = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d", parentID: a.id))

        let e = try #require(store.addSession(toWorkspace: ws.id, cwd: "/e", parentID: c.id))
        #expect(e.parentID == c.id)
        // e nests under c (a's first child), landing right after it — ahead of a's other child d.
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, c.id, e.id, d.id])
        #expect(store.sessionSubtreeIDs(a.id) == [a.id, c.id, e.id, d.id])
    }

    @Test func addSessionWithUnknownParentIgnoresItAndAppendsTopLevel() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b", parentID: UUID()))
        #expect(b.parentID == nil)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, b.id])
    }

    @Test func addSessionWithCrossWorkspaceParentIgnoresItAndAppendsTopLevel() throws {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let b = try #require(store.addSession(toWorkspace: ws2.id, cwd: "/b", parentID: a.id))
        #expect(b.parentID == nil)
        #expect(store.workspaces[1].sessions.map(\.id) == [b.id])
    }

    @Test func sessionSubtreeIDsReturnsTreeOrder() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let a2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a2", parentID: a1.id))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))

        #expect(store.sessionSubtreeIDs(a.id) == [a.id, a1.id, a2.id])
        #expect(store.sessionSubtreeIDs(a1.id) == [a1.id, a2.id])
        #expect(store.sessionSubtreeIDs(a2.id) == [a2.id])
    }

    @Test func sessionSubtreeIDsUnknownIDIsEmpty() {
        let store = makeStore()
        #expect(store.sessionSubtreeIDs(UUID()) == [])
    }

    @Test func reparentSessionMovesSubtreeBlockAndRepairsPreorder() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let a2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a2", parentID: a1.id))
        let b = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, a1.id, a2.id, b.id])

        store.reparentSession(a1.id, to: b.id)
        #expect(a1.parentID == b.id)
        #expect(a2.parentID == a1.id) // descendant untouched
        // a1's whole subtree (a1, a2) relocates under b, preorder-repaired: a keeps its now-childless slot.
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, b.id, a1.id, a2.id])
    }

    @Test func reparentSessionToNilMovesSubtreeToTopLevel() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))

        store.reparentSession(a1.id, to: nil)
        #expect(a1.parentID == nil)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, a1.id])
    }

    @Test func reparentSessionCycleUnderItsOwnDescendantIsNoOp() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let a2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a2", parentID: a1.id))
        let order = store.workspaces[0].sessions.map(\.id)

        store.reparentSession(a.id, to: a2.id) // a2 is a's own grandchild
        #expect(a.parentID == nil)
        #expect(store.workspaces[0].sessions.map(\.id) == order)

        store.reparentSession(a.id, to: a.id) // self-parent, also a cycle
        #expect(a.parentID == nil)
    }

    @Test func reparentSessionAcrossWorkspacesIsNoOp() throws {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let b = try #require(store.addSession(toWorkspace: ws2.id, cwd: "/b"))

        store.reparentSession(a.id, to: b.id)
        #expect(a.parentID == nil)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
        #expect(store.workspaces[1].sessions.map(\.id) == [b.id])
    }

    @Test func reparentSessionUnknownIDIsNoOp() {
        let store = makeStore()
        store.addWorkspace(name: "work")
        store.reparentSession(UUID(), to: nil) // must not crash
        #expect(store.workspaces[0].sessions.isEmpty)
    }

    @Test func reparentingIntoACollapsedParentRevealsIt() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let p = try #require(store.addSession(toWorkspace: ws.id, cwd: "/p"))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c", parentID: p.id))
        store.setSessionExpanded(p.id, expanded: false)
        #expect(p.isExpanded == false)

        let d = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        store.reparentSession(d.id, to: p.id) // drop d onto the collapsed parent p
        #expect(d.parentID == p.id)
        #expect(p.isExpanded == true, "nesting a child into p must reveal p so the child is visible")
    }

    @Test func moveSessionCarriesSubtreeAsOneContiguousBlock() throws {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/a1", parentID: a.id))
        let a2 = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/a2", parentID: a.id))
        let b = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/b"))

        store.moveSession(a.id, toWorkspace: ws2.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id]) // source keeps only the unrelated session
        #expect(store.workspaces[1].sessions.map(\.id) == [a.id, a1.id, a2.id]) // whole block, inner order kept
    }

    @Test func moveSessionCrossWorkspaceNilsMovedRootParentIDButKeepsDescendants() throws {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let p = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/p"))
        let a = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/a", parentID: p.id))
        let a1 = try #require(store.addSession(toWorkspace: ws1.id, cwd: "/a1", parentID: a.id))
        #expect(a.parentID == p.id)

        store.moveSession(a.id, toWorkspace: ws2.id)
        #expect(a.parentID == nil) // a subtree can't straddle workspaces: the moved root becomes top-level
        #expect(a1.parentID == a.id) // the descendant rides along, parentID untouched
        #expect(store.workspaces[0].sessions.map(\.id) == [p.id])
        #expect(store.workspaces[1].sessions.map(\.id) == [a.id, a1.id])
    }

    @Test func moveSessionWithinWorkspaceKeepsChildlessFastPathIdentical() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let c = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))

        store.moveSession(a.id, toWorkspace: ws.id, at: 2)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func setSessionExpandedFlipsAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        #expect(a.isExpanded)

        store.setSessionExpanded(a.id, expanded: false)
        #expect(!a.isExpanded)
        let loaded = persistence.load()
        #expect(loaded.workspaces[0].sessions[0].collapsed == true)
    }

    @Test func setSessionExpandedUnknownOrUnchangedIsNoOp() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.setSessionExpanded(UUID(), expanded: false) // unknown id
        #expect(a.isExpanded)
        store.setSessionExpanded(a.id, expanded: true) // already expanded
        #expect(a.isExpanded)
    }

    @Test func closeSessionCascadesWholeSubtree() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let a2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a2", parentID: a1.id))
        let z = try #require(store.addSession(toWorkspace: ws.id, cwd: "/z"))

        store.closeSession(a.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [z.id])
        #expect(store.session(withID: a.id) == nil)
        #expect(store.session(withID: a1.id) == nil) // children torn down, not orphaned
        #expect(store.session(withID: a2.id) == nil)
    }

    @Test func closeSessionChildlessBehavesExactlyAsBefore() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        store.selectSession(b.id)

        store.closeSession(b.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id])
        #expect(store.selectedSessionID == a.id) // unchanged reselection behavior
    }

    @Test func closeSessionCascadeRecordsOneGroupedRecentClosedItem() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let a2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a2", parentID: a1.id))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/z"))

        store.closeSession(a.id)

        let items = recentClosed.load()
        #expect(items.count == 1) // ONE record for the whole subtree, not three
        #expect(items[0].kind == .sessionGroup)
        #expect(items[0].sessionGroup?.snapshots.map(\.id) == [a.id, a1.id, a2.id]) // tree order preserved
        #expect(items[0].sessionGroup?.snapshots[1].parentID == a.id)
        #expect(items[0].sessionGroup?.snapshots[2].parentID == a1.id)
        #expect(items[0].sessionGroup?.selectedSessionID == a.id)
        #expect(items[0].subtitle == "3 sessions")
    }

    @Test func closeSessionCascadeReopenRestoresWholeSubtreeWithContiguityAndSelection() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let a2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a2", parentID: a1.id))
        let z = try #require(store.addSession(toWorkspace: ws.id, cwd: "/z"))
        store.selectSession(z.id)

        store.closeSession(a.id)
        let item = try #require(recentClosed.load().first { $0.kind == .sessionGroup })

        #expect(store.restoreRecentClosed(item))
        // one Reopen restores the whole subtree, contiguous and in its original relative order.
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, a1.id, a2.id, z.id])
        let restoredA1 = try #require(store.session(withID: a1.id))
        let restoredA2 = try #require(store.session(withID: a2.id))
        #expect(restoredA1.parentID == a.id)
        #expect(restoredA2.parentID == a1.id)
        #expect(store.selectedSessionID == a.id) // reselects the root the user closed
    }

    @Test func closeSessionChildlessStillRecordsTheLegacySingleSessionItem() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))

        store.closeSession(a.id)

        let items = recentClosed.load()
        #expect(items.count == 1)
        #expect(items[0].kind == .session) // not wrapped in the new grouped kind
        #expect(items[0].session?.snapshot.id == a.id)
        #expect(items[0].sessionGroup == nil)
    }

    @Test func softCloseSessionCascadesWholeSubtreeUnderOneUndo() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let a2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a2", parentID: a1.id))
        let z = try #require(store.addSession(toWorkspace: ws.id, cwd: "/z"))

        let closed = store.softCloseSession(a.id, grace: 999)
        #expect(closed)
        #expect(store.workspaces[0].sessions.map(\.id) == [z.id])
        #expect(store.pendingCloseSummary?.kind == .sessions)
        #expect(store.pendingCloseSummary?.title == "3 sessions")

        let undone = store.undoPendingClose()
        #expect(undone)
        // one undo restores the whole subtree, in its original contiguous order.
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, a1.id, a2.id, z.id])
        #expect(store.pendingCloseSummary == nil)
    }

    @Test func softCloseSessionChildlessStaysASingleSessionRecord() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))

        #expect(store.softCloseSession(a.id, grace: 999))
        #expect(store.pendingCloseSummary?.kind == .session)
        #expect(store.pendingCloseSummary?.title == a.displayName)
    }

    @Test func softCloseSessionsExpandsAnyParentInTheBatchToItsSubtree() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let b = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))

        #expect(store.softCloseSessions([a.id, b.id], grace: 999))
        #expect(store.workspaces[0].sessions.isEmpty)
        #expect(store.pendingCloseSummary?.kind == .sessions)
        #expect(store.pendingCloseSummary?.title == "3 sessions") // a, a1 (expanded in), b

        #expect(store.undoPendingClose())
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, a1.id, b.id])
    }

    // --to on a NESTED session reorders it within its sibling group carrying its subtree, never breaking
    // the contiguity invariant (a flat index move would strand the moved row inside a neighbour's subtree).
    @Test func reorderSessionOnNestedSessionKeepsTreeContiguous() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let a1x = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1x", parentID: a1.id))
        let a2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a2", parentID: a.id))
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, a1.id, a1x.id, a2.id])

        // move a2 UP past its sibling a1 (which carries grandchild a1x): the whole a1 subtree stays contiguous.
        store.reorderSession(a2.id, .up)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, a2.id, a1.id, a1x.id])
        #expect(a2.parentID == a.id) // still a's child, only reordered among siblings
        #expect(store.sessionSubtreeIDs(a.id) == [a.id, a2.id, a1.id, a1x.id]) // preorder == array order

        // a child can't escape its parent: moving a2 to the TOP of its sibling group is the furthest it goes.
        store.reorderSession(a1.id, .bottom)
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, a2.id, a1.id, a1x.id]) // a1 already last child, no-op
    }

    @Test func controlTreeReportsParentIDAndCollapsed() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))

        var nodes = store.controlTree().workspaces[0].sessions
        let parentNode = try #require(nodes.first { $0.id == a.id.uuidString })
        let childNode = try #require(nodes.first { $0.id == a1.id.uuidString })
        #expect(parentNode.parentID == nil) // top-level session omits parentID
        #expect(childNode.parentID == a.id.uuidString)
        #expect(parentNode.collapsed == nil) // expanded by default, omitted

        store.setSessionExpanded(a.id, expanded: false)
        nodes = store.controlTree().workspaces[0].sessions
        #expect(try #require(nodes.first { $0.id == a.id.uuidString }).collapsed == true)
    }

    // Regression: `session.move --after` an anchor that ALREADY shares the target's parent AND has its own
    // subtree used to leave a non-contiguous tree — the flat splice split the anchor's subtree and
    // reparentSession's parent-unchanged no-op never repaired it. repairContiguity now restores preorder.
    @Test func placeAfterSiblingWithSubtreeKeepsContiguity() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let p = try #require(store.addSession(toWorkspace: ws.id, cwd: "/p"))
        let c1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c1", parentID: p.id))
        let c1x = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c1x", parentID: c1.id))
        let c2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c2", parentID: p.id))
        #expect(store.workspaces[0].sessions.map(\.id) == [p.id, c1.id, c1x.id, c2.id])

        placeSessionHostFree(store, move: c2.id, relativeTo: c1.id, after: true)
        #expect(store.workspaces[0].sessions.map(\.id) == [p.id, c1.id, c1x.id, c2.id]) // c2 after c1's subtree
        #expect(c2.parentID == p.id)
        #expect(SessionTree.subtreeRange(of: c1.id, in: store.sessionNodes(inWorkspace: ws.id)) == 1..<3) // c1 + c1x
    }

    @Test func placeBeforeSiblingWithSubtreeKeepsContiguity() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let p = try #require(store.addSession(toWorkspace: ws.id, cwd: "/p"))
        let c1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c1", parentID: p.id))
        let c1x = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c1x", parentID: c1.id))
        let c2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c2", parentID: p.id))

        placeSessionHostFree(store, move: c2.id, relativeTo: c1.id, after: false)
        #expect(store.workspaces[0].sessions.map(\.id) == [p.id, c2.id, c1.id, c1x.id]) // c2 before c1's subtree
        #expect(c2.parentID == p.id)
        #expect(SessionTree.subtreeRange(of: c1.id, in: store.sessionNodes(inWorkspace: ws.id)) == 2..<4) // c1 + c1x
    }

    // The create counterpart: `session.new --after` a subtree-bearing anchor inserts a childless session
    // between the anchor and its children; repairContiguity lands it after the anchor's whole subtree.
    @Test func createAfterSiblingWithSubtreeKeepsContiguity() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let p = try #require(store.addSession(toWorkspace: ws.id, cwd: "/p"))
        let c1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c1", parentID: p.id))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c1x", parentID: c1.id))
        let loc = try #require(store.sessionLocation(ofSession: c1.id))

        let new = try #require(store.addSession(toWorkspace: ws.id, cwd: "/new",
                                                at: loc.index + 1, parentID: store.session(withID: c1.id)?.parentID))
        store.repairContiguity(inWorkspace: ws.id)
        #expect(store.workspaces[0].sessions.map(\.id).last == new.id) // lands after c1's whole subtree
        #expect(new.parentID == p.id)
        #expect(SessionTree.subtreeRange(of: c1.id, in: store.sessionNodes(inWorkspace: ws.id)) == 1..<3)
    }

    @Test func reparentSessionAtPositionNestsAtAGivenChildSlot() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let p = try #require(store.addSession(toWorkspace: ws.id, cwd: "/p"))
        let c1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c1", parentID: p.id))
        let c2 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c2", parentID: p.id))
        let d = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        #expect(store.workspaces[0].sessions.map(\.id) == [p.id, c1.id, c2.id, d.id])

        store.reparentSession(d.id, to: p.id, at: 1) // between c1 and c2
        #expect(d.parentID == p.id)
        #expect(store.workspaces[0].sessions.map(\.id) == [p.id, c1.id, d.id, c2.id])
    }

    @Test func reparentSessionAtPositionReordersTopLevelCarryingSubtree() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let b = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        #expect(store.workspaces[0].sessions.map(\.id) == [a.id, a1.id, b.id])

        // move top-level `a` (with child a1) to the last top-level slot; parentID stays nil, subtree rides.
        store.reparentSession(a.id, to: nil, at: 1)
        #expect(a.parentID == nil)
        #expect(store.workspaces[0].sessions.map(\.id) == [b.id, a.id, a1.id])
    }

    @Test func reparentSessionAtPositionFirstChildLandsRightAfterParent() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let p = try #require(store.addSession(toWorkspace: ws.id, cwd: "/p"))
        let c1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c1", parentID: p.id))
        let d = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))

        store.reparentSession(d.id, to: p.id, at: 0) // become p's FIRST child
        #expect(store.workspaces[0].sessions.map(\.id) == [p.id, d.id, c1.id])
    }

    @Test func reparentSessionAtPositionCycleIsNoOp() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let a1 = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a1", parentID: a.id))
        let order = store.workspaces[0].sessions.map(\.id)

        store.reparentSession(a.id, to: a1.id, at: 0) // parent under its own child
        #expect(a.parentID == nil)
        #expect(store.workspaces[0].sessions.map(\.id) == order)
    }

    // The CONTIGUITY invariant (a parent immediately followed by its whole subtree, depth-first preorder)
    // must survive EVERY structural op. It holds iff the flat array already equals its own preorder.
    @Test func contiguityInvariantSurvivesEveryStructuralOp() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let a = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let b = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let c = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c", parentID: a.id))
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d", parentID: c.id))
        assertContiguous(store, ws.id, "create-child + grandchild")

        store.reparentSession(b.id, to: a.id)
        assertContiguous(store, ws.id, "reparent (last child)")
        store.reparentSession(c.id, to: nil, at: 0) // promote c (carrying d) to top-level, positioned
        assertContiguous(store, ws.id, "positioned reparent to top-level")
        store.reorderSession(a.id, .bottom)
        assertContiguous(store, ws.id, "sibling reorder")
        store.moveSession(c.id, toWorkspace: other.id)
        assertContiguous(store, ws.id, "source after cross-workspace move")
        assertContiguous(store, other.id, "destination after cross-workspace move")
        _ = store.closeSessionSubtree(a.id)
        assertContiguous(store, ws.id, "cascade close")
    }

    /// Asserts a workspace's flat session array already equals its own depth-first preorder — the contiguity
    /// invariant. Any op that split a subtree would leave the array out of preorder.
    private func assertContiguous(_ store: AppStore, _ workspaceID: UUID, _ note: String) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let nodes = workspace.sessions.map { SessionTree.Node(id: $0.id, parentID: $0.parentID) }
        #expect(workspace.sessions.map(\.id) == SessionTree.preorder(nodes), "contiguity broken after \(note)")
    }

    /// The host-free core of `ControlServer.placeSession`: the drop math + positional move, parent adoption,
    /// then the UNCONDITIONAL contiguity repair. Mirrors the app arm so the invariant is proven without a host.
    private func placeSessionHostFree(_ store: AppStore, move sessionID: UUID, relativeTo anchorID: UUID, after: Bool) {
        guard let source = store.sessionLocation(ofSession: sessionID),
              let anchor = store.sessionLocation(ofSession: anchorID) else { return }
        let anchorParent = store.session(withID: anchorID)?.parentID
        if let resolution = SidebarDrop.resolveRelative(
            source: (workspace: source.workspace, index: source.index),
            anchor: (workspace: anchor.workspace, index: anchor.index, count: anchor.count),
            placeAfter: after) {
            store.moveSession(sessionID, toWorkspace: resolution.workspace, at: resolution.destination)
        }
        store.reparentSession(sessionID, to: anchorParent)
        store.repairContiguity(inWorkspace: anchor.workspace)
    }
}
