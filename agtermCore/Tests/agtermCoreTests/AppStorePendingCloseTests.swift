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

    @Test(arguments: ["session", "batch", "workspace"])
    func softCloseDropsATimedInfoLineAndUndoKeepsAnUntimedOne(path: String) throws {
        let store = store()
        let timed = addSession(store, name: "timed")
        let untimed = addSession(store, name: "untimed")
        let workspaceID = store.workspaces[0].id
        store.workspaces.append(Workspace(name: "staying", sessions: []))
        store.setInfo(try SessionInfo.make(source: "brief", markdown: false, hideAfter: 30).get(), forSession: timed.id)
        store.setInfo(try SessionInfo.make(source: "kept", markdown: false, hideAfter: 0).get(), forSession: untimed.id)
        defer { store.finalizeAllPendingCloses() }

        switch path {
        case "session":
            #expect(store.softCloseSession(timed.id, grace: 60))
            #expect(store.softCloseSession(untimed.id, grace: 60))
        case "batch": #expect(store.softCloseSessions([timed.id, untimed.id], grace: 60))
        default: #expect(store.softRemoveWorkspace(workspaceID, grace: 60))
        }
        #expect(timed.info == nil)
        #expect(untimed.info?.source == "kept")

        while store.undoPendingClose() {}
        #expect(store.session(withID: timed.id)?.info == nil)
        #expect(store.session(withID: untimed.id)?.info?.source == "kept")
    }

    @Test(arguments: [false, true])
    func pendingRecentIDNamesTheEntryTheSoftCloseWrote(withCompanion: Bool) throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let workspace = store.addWorkspace(name: "w")
        let root = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/a"))
        if withCompanion { _ = try store.addCompanion(to: root.id, options: CompanionOptions(cwd: "/c")).get() }
        defer { store.finalizeAllPendingCloses() }

        #expect(store.softCloseSession(root.id, grace: 60))

        let entries = recentClosed.load()
        #expect(entries.count == 1)
        #expect(store.pendingRecentID(ofClosedSession: root.id) == entries.first?.id)
        #expect(store.pendingRecentID(ofClosedSession: UUID()) == nil)
    }

    @Test func pendingRecentIDIsNilWithoutARecentStore() {
        let store = store()
        let session = addSession(store, name: "one")
        defer { store.finalizeAllPendingCloses() }

        #expect(store.softCloseSession(session.id, grace: 60))

        #expect(store.pendingRecentID(ofClosedSession: session.id) == nil)
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

    private final class KillLog {
        var endedAtKill: [Bool] = []
    }

    private func finalizingStore(watching id: @escaping () -> UUID?, log: KillLog) -> AppStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir), paneFinalizer: { _ in
            log.endedAtKill.append(id().map(PresentationEnds.shared.contains) ?? false)
        }, launchPaneDrop: nil)
        store.workspaces = [Workspace(name: "workspace 1", sessions: [])]
        return store
    }

    @Test(arguments: ["hard close", "hard workspace", "grace session", "grace member", "grace workspace"])
    func finalRemovalRecordsTheSessionEndedBeforeItsDaemonsAreKilled(path: String) {
        var watched: UUID?
        let log = KillLog()
        let store = finalizingStore(watching: { watched }, log: log)
        let session = addSession(store, name: "build")
        let mate = addSession(store, name: "mate")
        watched = session.id
        let workspaceID = store.workspaces[0].id
        store.workspaces.append(Workspace(name: "staying", sessions: [Session(initialCwd: "/tmp")]))

        switch path {
        case "hard close": store.closeSession(session.id)
        case "hard workspace": store.removeWorkspace(workspaceID)
        case "grace session":
            #expect(store.softCloseSession(session.id, grace: 60))
            #expect(!PresentationEnds.shared.contains(session.id))
            store.finalizeAllPendingCloses()
        case "grace member":
            #expect(store.softCloseSessions([session.id, mate.id], grace: 60))
            #expect(store.finalizePendingClose(ofSession: session.id))
        default:
            #expect(store.softRemoveWorkspace(workspaceID, grace: 60))
            #expect(!PresentationEnds.shared.contains(session.id))
            store.finalizeAllPendingCloses()
        }

        #expect(PresentationEnds.shared.contains(session.id))
        #expect(log.endedAtKill.first == true)
        store.finalizeAllPendingCloses()
    }

    @Test func undoAndPaneCloseNeverRecordASessionEnded() {
        let store = store()
        let session = addSession(store, name: "build", split: true)

        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(store.undoPendingClose())
        store.closeSplit(session.id)

        #expect(store.session(withID: session.id) != nil)
        #expect(!PresentationEnds.shared.contains(session.id))
    }

    @Test func finalRemovalEndsTheSessionsLiveStreams() throws {
        let store = store()
        let session = addSession(store, name: "build")
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let viewer = PresentationHubTests.Sink()
        let hello = PresentationHello(version: 1, kinds: [PresentationHub.endedKind], mode: .mirror)
        try hub.subscribe(session: session.id, hello: hello, sink: viewer) { PresentationSnapshot(status: nil, hud: nil) }

        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(viewer.finished == nil)
        store.finalizeAllPendingCloses()

        #expect(viewer.finished?.body == .ended)
        #expect(hub.subscriberCount(session: session.id) == 0)
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

    @Test func batchCloseStampsTheActiveSessionLeftWhenUndoSelectsABatchMate() throws {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")
        _ = addSession(store, name: "three")
        store.selectedSessionID = first.id
        first.lastSelectedAt = Date(timeIntervalSince1970: 1)
        defer { store.finalizeAllPendingCloses() }

        let before = Date()
        #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        let after = Date()
        #expect(store.undoPendingClose(selecting: second.id))

        #expect(store.selectedSessionID == second.id)
        let stamp = try #require(first.lastSelectedAt)
        #expect((before...after).contains(stamp))
    }

    @Test func finalizingOnePendingSessionKeepsItsBatchMatesAndOtherRecordsUndoable() {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")
        let third = addSession(store, name: "three")
        #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        #expect(store.softCloseSession(third.id, grace: 60))

        #expect(store.finalizePendingClose(ofSession: first.id))

        #expect(Set(store.pendingCloseMembers().map(\.session.id)) == [second.id, third.id])
        #expect(store.undoPendingClose())
        #expect(store.undoPendingClose())
        #expect(store.session(withID: second.id) != nil)
        #expect(store.session(withID: third.id) != nil)
        #expect(store.session(withID: first.id) == nil)
    }

    @Test func undoAfterFinalizingAnEarlierBatchMateRestoresTheSurvivorInItsPlace() {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")
        let third = addSession(store, name: "three")
        let before = store.workspaces[0].sessions.map(\.id).filter { $0 != first.id }
        #expect(store.softCloseSessions([first.id, second.id], grace: 60))

        #expect(store.finalizePendingClose(ofSession: first.id))
        #expect(store.undoPendingClose())

        #expect(store.workspaces[0].sessions.map(\.id) == before)
        #expect(store.workspaces[0].sessions.map(\.id).firstIndex(of: second.id)! < store.workspaces[0].sessions.map(\.id).firstIndex(of: third.id)!)
    }

    @Test func eachPendingSessionNamesTheRecordAnUndoTakes() throws {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")
        let third = addSession(store, name: "three")
        let other = Session(initialCwd: "/tmp", customName: "other")
        store.workspaces.append(Workspace(name: "workspace 2", sessions: [other]))
        defer { store.finalizeAllPendingCloses() }
        #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        let batch = try #require(store.pendingCloseSummary)
        #expect(store.softRemoveWorkspace(store.workspaces[0].id, grace: 60))
        let workspace = try #require(store.pendingCloseSummary)

        #expect(store.pendingCloseID(ofSession: first.id) == batch.id)
        #expect(store.pendingCloseID(ofSession: second.id) == batch.id)
        #expect(store.pendingCloseID(ofSession: third.id) == workspace.id)
        #expect(store.pendingCloseID(ofSession: other.id) == nil)
    }

    @Test func aBatchKeepsItsCloseTimeWhenAMemberFinalizes() throws {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")
        let third = addSession(store, name: "three")
        defer { store.finalizeAllPendingCloses() }
        #expect(store.softCloseSessions([first.id, second.id, third.id], grace: 60))
        let closedAt = try #require(store.pendingCloseSummary?.closedAt)

        #expect(store.finalizePendingClose(ofSession: first.id))

        #expect(store.pendingCloseSummary?.closedAt == closedAt)
    }

    @Test func aDiscardedSessionLeavesNoRecentEntry() {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        store.workspaces = [Workspace(name: "workspace 1", sessions: [])]
        let discarded = addSession(store, name: "failed")
        let closed = addSession(store, name: "closed")

        store.discardSession(discarded.id)
        _ = store.closeSession(closed.id)

        #expect(store.session(withID: discarded.id) == nil)
        #expect(recentClosed.load().map(\.title) == ["closed"])
    }

    @Test func finalizingTheOnlyPendingSessionDropsItsRecord() {
        let store = store()
        let only = addSession(store, name: "one")
        #expect(store.softCloseSession(only.id, grace: 60))

        #expect(store.finalizePendingClose(ofSession: only.id))

        #expect(store.pendingCloseMembers().isEmpty)
        #expect(!store.undoPendingClose())
        #expect(!store.finalizePendingClose(ofSession: only.id))
    }

    @Test func finalizingOneSessionOfAPendingWorkspaceKeepsTheRest() {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")
        store.workspaces.append(Workspace(name: "workspace 2", sessions: []))
        #expect(store.softRemoveWorkspace(store.workspaces[0].id, grace: 60))

        #expect(store.finalizePendingClose(ofSession: first.id))

        #expect(store.pendingCloseMembers().map(\.session.id).contains(second.id))
        #expect(!store.pendingCloseMembers().map(\.session.id).contains(first.id))
        #expect(store.undoPendingClose())
        #expect(store.session(withID: second.id) != nil)
        #expect(store.session(withID: first.id) == nil)
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

    @Test(arguments: ["session", "batch", "workspace"])
    func aPendingCloseSessionIsFoundOnlyUntilUndoOrFinalize(path: String) {
        let store = store()
        let first = addSession(store, name: "one")
        let second = addSession(store, name: "two")
        store.workspaces.append(Workspace(name: "staying", sessions: []))
        #expect(store.pendingCloseSession(withID: first.id) == nil, "a visible row is not pending")

        switch path {
        case "session": #expect(store.softCloseSession(first.id, grace: 60))
        case "batch": #expect(store.softCloseSessions([first.id, second.id], grace: 60))
        default: #expect(store.softRemoveWorkspace(store.workspaces[0].id, grace: 60))
        }
        #expect(store.pendingCloseSession(withID: first.id) === first)
        #expect(store.undoPendingClose())
        #expect(store.pendingCloseSession(withID: first.id) == nil)

        #expect(store.softCloseSession(first.id, grace: 60))
        store.finalizeAllPendingCloses()
        #expect(store.pendingCloseSession(withID: first.id) == nil)
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

    @Test func aRemoteRowReportsLeavingOnSoftCloseAndReturningOnUndo() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        var edges: [Bool] = []
        store.onRemoteRowVisibility = { _, shown in edges.append(shown) }
        let remote = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", remoteHost: "buildbox"))
        let local = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp"))
        #expect(edges == [true])

        #expect(store.softCloseSession(remote.id))
        #expect(edges == [true, false])
        #expect(store.undoPendingClose())
        #expect(edges == [true, false, true])

        #expect(store.softCloseSession(local.id))
        #expect(edges == [true, false, true], "a local row is none of the presentation client's business")
    }

    @Test func aRemoteRowReportsReturningWhenItsWorkspaceIsRestored() throws {
        let store = makeStore()
        _ = store.addWorkspace(name: "keep")
        let ws = store.addWorkspace(name: "work")
        var edges: [Bool] = []
        store.onRemoteRowVisibility = { _, shown in edges.append(shown) }
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/tmp", remoteHost: "buildbox"))

        #expect(store.softRemoveWorkspace(ws.id))
        #expect(edges == [true, false])
        #expect(store.undoPendingClose())

        #expect(edges == [true, false, true])
    }
}
