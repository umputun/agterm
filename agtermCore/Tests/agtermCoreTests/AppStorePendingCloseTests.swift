import Foundation
import Testing
@testable import agtermCore

/// Soft close retains daemon claims for undo but cancels pending asks immediately.
@MainActor
struct AppStorePendingCloseTests {
    @Test(arguments: ["session", "batch", "workspace"])
    func softCloseCancelsAsksImmediatelyAndUndoDoesNotRestoreThem(path: String) {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")
        let workspaceID = store.workspaces[0].id
        store.workspaces.append(Workspace(name: "staying", sessions: []))
        let sessions = [first, second]
        let windowID = UUID()
        let registry = AskRegistry.shared
        let asks = sessions.map { session in
            let ask = PendingAsk(id: UUID().uuidString, title: "Continue?", buttons: [ControlAskButton(id: "yes", label: "Yes")])
            #expect(session.openAsk(ask))
            #expect(registry.register(id: ask.id, owner: .session(session.id, window: windowID)))
            return ask
        }
        defer {
            for (session, ask) in zip(sessions, asks) { session.cancelAsk(id: ask.id) }
            store.finalizeAllPendingCloses()
        }

        switch path {
        case "session": #expect(store.softCloseSession(first.id, grace: 60))
        case "batch": #expect(store.softCloseSessions(sessions.map(\.id), grace: 60))
        default: #expect(store.softRemoveWorkspace(workspaceID, grace: 60))
        }

        let removedCount = path == "session" ? 1 : 2
        for index in 0..<removedCount {
            #expect(store.session(withID: sessions[index].id) == nil)
            #expect(sessions[index].askPending == nil)
            #expect(registry.result(for: asks[index].id)?.result == ControlAskResult(result: .cancelled))
            #expect(registry.result(for: asks[index].id)?.windowID == windowID)
        }
        if path == "session" { #expect(second.askPending == asks[1]) }
        #expect(store.undoPendingClose())
        for index in 0..<removedCount {
            #expect(store.session(withID: sessions[index].id) === sessions[index])
            #expect(sessions[index].askPending == nil)
            #expect(registry.result(for: asks[index].id)?.result.result == .cancelled)
        }
    }

    private final class DropLog {
        var identities: [UUID] = []
    }

    private let drops = DropLog()

    private func store() -> AppStore {
        let log = drops
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir), paneFinalizer: nil,
                             launchPaneDrop: { log.identities += $0 })
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
    /// A soft close leaves the deck before its grace expires, so the pacer hears about it at the close, not
    /// at finalization; undo brings the session back as a key outside the armed order.
    @Test func softClosingASessionDropsBothItsPanesAtTheClose() throws {
        let store = store()
        let session = addSession(store, name: "build", split: true)
        let split = try #require(session.splitPaneIdentity)

        #expect(store.softCloseSession(session.id))

        #expect(Set(drops.identities) == [session.paneIdentity, split])
    }

    @Test func batchSoftCloseDropsEveryMembersPanes() {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")

        #expect(store.softCloseSessions([first.id, second.id]))

        #expect(Set(drops.identities) == [first.paneIdentity, second.paneIdentity])
    }

    @Test func softRemovingAWorkspaceDropsItsSessionsPanes() {
        let store = store()
        let session = addSession(store, name: "build")
        store.workspaces.append(Workspace(name: "workspace 2", sessions: []))

        #expect(store.softRemoveWorkspace(store.workspaces[0].id))

        #expect(drops.identities == [session.paneIdentity])
    }
}
