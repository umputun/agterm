import Foundation
import Testing
@testable import agtermCore

/// Covers only the soft-close accessor the zmx claim walk reads: a hidden session still owns its daemon,
/// so it must stay claimed for the whole grace window.
@MainActor
struct AppStorePendingCloseTests {
    private func store() -> AppStore {
        let store = makeStore()
        store.workspaces = [Workspace(name: "workspace 1", sessions: [])]
        return store
    }

    @discardableResult
    private func addSession(_ store: AppStore, name: String, split: Bool = false) -> Session {
        let session = Session(initialCwd: "/tmp", customName: name)
        if split {
            session.hasSplit = true
            session.splitPaneIdentity = UUID()
        }
        store.workspaces[0].sessions.append(session)
        return session
    }

    @Test func softClosedSessionStaysClaimedWithBothItsPanes() {
        let store = store()
        let session = addSession(store, name: "build", split: true)

        #expect(store.softCloseSession(session.id))
        #expect(store.workspaces[0].sessions.isEmpty)

        let members = store.pendingCloseMembers()
        #expect(members.map(\.session.id) == [session.id])
        #expect(members.first?.workspaceID == store.workspaces[0].id)
        #expect(members.first?.workspaceName == "workspace 1")
        #expect(members.first?.session.splitPaneIdentity == session.splitPaneIdentity)
    }

    @Test func batchSoftCloseKeepsEveryMember() {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")

        #expect(store.softCloseSessions([first.id, second.id]))
        #expect(Set(store.pendingCloseMembers().map(\.session.id)) == [first.id, second.id])
    }

    @Test func softClosedWorkspaceContributesEverySessionItHeld() {
        let store = store()
        let session = addSession(store, name: "build")
        store.workspaces.append(Workspace(name: "workspace 2", sessions: []))
        let target = store.workspaces[0].id

        #expect(store.softRemoveWorkspace(target))
        let members = store.pendingCloseMembers()
        #expect(members.map(\.session.id) == [session.id])
        #expect(members.first?.workspaceID == target)
        #expect(members.first?.workspaceName == "workspace 1")
    }

    @Test func finalizingTheGraceDropsTheClaim() {
        let store = store()
        let session = addSession(store, name: "build")

        #expect(store.softCloseSession(session.id))
        store.finalizeAllPendingCloses()
        #expect(store.pendingCloseMembers().isEmpty)
    }

    @Test func undoingTheCloseReturnsTheSessionToTheTree() {
        let store = store()
        let session = addSession(store, name: "build")

        #expect(store.softCloseSession(session.id))
        #expect(store.undoPendingClose())
        #expect(store.pendingCloseMembers().isEmpty)
        #expect(store.workspaces[0].sessions.map(\.id) == [session.id])
    }
}
