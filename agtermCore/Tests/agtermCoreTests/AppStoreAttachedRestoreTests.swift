import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreAttachedRestoreTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private func relaunched(_ store: AppStore) -> AppStore {
        let restored = makeStore()
        restored.restore(from: store.snapshot(), launchRestore: true)
        return restored
    }

    @Test func aSnapshotKeepsAttachedRowsApartFromLocalSessions() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/first"))
        let row = try addAttachedRow(to: store, workspace: work.id)
        row.customName = "remote"
        row.flagged = true
        row.context = "deploy"
        let last = try #require(store.addSession(toWorkspace: work.id, cwd: "/last"))

        let saved = try #require(store.snapshot().workspaces.first)
        #expect(saved.sessions.map(\.id) == [first.id, last.id])
        let attached = try #require(saved.attached?.first)
        #expect(saved.attached?.count == 1)
        #expect(attached.index == 1)
        #expect(attached.session.id == row.id)
        #expect(attached.session.cwd == home)
        #expect(attached.session.customName == "remote")
        #expect(attached.session.flagged == true)
        #expect(attached.session.context == "deploy")
        #expect(attached.session.initialCommand == nil)
        #expect(attached.session.restoreCommand == nil)
        #expect(attached.origin.host == "box")
        #expect(attached.origin.sessionID == "o1")
        #expect(attached.origin.endpoint == attachedEndpoint)
        #expect(attached.origin.panes.map(\.pane) == [row.paneIdentity])
        #expect(attached.origin.page == nil)
    }

    @Test func aRelaunchPutsAnAttachedRowBackInPlaceAttachingWithoutTheLead() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/first"))
        let row = try addAttachedRow(to: store, workspace: work.id, split: true)
        let last = try #require(store.addSession(toWorkspace: work.id, cwd: "/last"))

        let restored = relaunched(store)

        #expect(restored.workspaces[0].sessions.map(\.id) == [first.id, row.id, last.id])
        let back = try #require(restored.session(withID: row.id))
        #expect(back.remoteHost == "box")
        #expect(back.remoteSessionID == "o1")
        #expect(back.remotePresentation?.binding == row.remotePresentation?.binding)
        #expect(back.awaitsOriginCheck)
        #expect(!back.ended)
        #expect(back.commandWait)
        #expect(back.initialCommand != nil)
        #expect(back.initialCommand != RemoteSession.endedCommand(host: "box"))
        #expect(back.hasSplit)
        #expect(back.splitPaneIdentity == row.splitPaneIdentity)
        #expect(back.splitInitialCommand != nil)
        #expect(ZmxLeadBook.shared.states[back.paneIdentity]?.attachment.claim == false)
        #expect(ZmxLeadBook.shared.states[try #require(back.splitPaneIdentity)]?.attachment.claim == false)
    }

    @Test func aRelaunchReclaimsTheLeadOnlyWhereThePaneLedWhenSaved() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, split: true)
        let split = try #require(row.splitPaneIdentity)
        let led = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(led, pane: row.paneIdentity)
        _ = ZmxLeadBook.shared.apply(try #require(ZmxLeadNotice(title: "zmx-role;\(led.nonce):leader:1")), pane: row.paneIdentity)
        let followed = ZmxLeadAttachment(claim: true)
        ZmxLeadBook.shared.begin(followed, pane: split)
        _ = ZmxLeadBook.shared.apply(try #require(ZmxLeadNotice(title: "zmx-role;\(followed.nonce):follower:1")), pane: split)

        let restored = relaunched(store)

        let back = try #require(restored.session(withID: row.id))
        let primary = try #require(ZmxLeadBook.shared.states[back.paneIdentity]?.attachment)
        #expect(!primary.claim)
        #expect(primary.reclaim == led.nonce)
        #expect(back.initialCommand?.contains("\(ZmxLeadAttachment.reclaimVariable)=\(led.nonce)") == true)
        let right = try #require(ZmxLeadBook.shared.states[split]?.attachment)
        #expect(!right.claim)
        #expect(right.reclaim == nil)
        #expect(back.splitInitialCommand?.contains(ZmxLeadAttachment.reclaimVariable) == false)
    }

    @Test func aSplitWhoseDaemonIsNotInTheBindingIsDropped() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, split: true)
        var snapshot = store.snapshot()
        snapshot.workspaces[0].attached?[0].origin.panes.removeAll { $0.pane == row.splitPaneIdentity }

        let restored = makeStore()
        restored.restore(from: snapshot, launchRestore: true)

        let back = try #require(restored.session(withID: row.id))
        #expect(!back.hasSplit)
        #expect(back.splitPaneIdentity == nil)
        #expect(back.splitInitialCommand == nil)
    }

    @Test func aRowSavedEndedIsNotRestoredAndItsCompanionComesBackOnItsOwn() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, origin: "o1")
        let companion = try addAttachedRow(to: store, workspace: work.id, origin: "o2")
        companion.parentID = row.id
        row.ended = true

        let restored = relaunched(store)

        #expect(restored.session(withID: row.id) == nil)
        let back = try #require(restored.session(withID: companion.id))
        #expect(back.parentID == nil)
        #expect(back.awaitsOriginCheck)
    }

    @Test func aHeadlessRowThatLostItsDaemonStillRestoresEnded() throws {
        let (store, session) = makeHeadlessSession(split: false)
        store.markSessionEnded(session.id)

        let restored = makeStore()
        restored.restore(from: store.snapshot(), launchRestore: true)

        #expect(restored.session(withID: session.id)?.ended == true)
    }

    @Test func aPageRowRestoresWaitingForItsPage() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, page: true)
        #expect(store.snapshot().workspaces[0].attached?.first?.origin.page == true)

        let back = try #require(relaunched(store).session(withID: row.id))

        #expect(back.content == .page)
        #expect(!back.overlayActive)
        #expect(back.initialCommand == nil)
        #expect(back.awaitsOriginCheck)
        #expect(back.remotePresentation?.connection == .connecting)
    }

    @Test func anAttachedGroupWithAPageCompanionComesBackGrouped() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let parent = try addAttachedRow(to: store, workspace: work.id, origin: "o1")
        let page = try addAttachedRow(to: store, workspace: work.id, origin: "o2", page: true)
        page.parentID = parent.id
        let after = try #require(store.addSession(toWorkspace: work.id, cwd: "/after"))

        let restored = relaunched(store)

        #expect(restored.workspaces[0].sessions.map(\.id) == [parent.id, page.id, after.id])
        #expect(restored.session(withID: page.id)?.parentID == parent.id)
        #expect(restored.session(withID: page.id)?.content == .page)
        #expect(restored.companions(of: parent.id).map(\.id) == [page.id])
    }

    @Test func anAttachedRowIsOnDiskOnceItIsBound() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-attached-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(persistence: PersistenceStore(directory: directory))
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id)
        let page = try addAttachedRow(to: store, workspace: work.id, origin: "o2", page: true)

        let saved = PersistenceStore(directory: directory).load().workspaces.flatMap { $0.attached ?? [] }

        #expect(saved.map(\.session.id) == [row.id, page.id])
    }

    @Test func aServerWindowRowIsNotSaved() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, catalogOwned: true)

        let saved = try #require(store.snapshot().workspaces.first)

        #expect(saved.attached == nil)
        #expect(!saved.sessions.contains { $0.id == row.id })
    }

    @Test func closingAnEndedAttachedRowLeavesItsCompanionAndNoRecentClosedEntry() throws {
        let (store, recent, _) = makeStoreWithRecentClosed()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id, origin: "o1", split: true)
        let companion = try addAttachedRow(to: store, workspace: work.id, origin: "o2")
        companion.parentID = row.id

        store.closeEndedAttachedRow(row.id)

        #expect(store.session(withID: row.id) == nil)
        #expect(store.session(withID: companion.id)?.parentID == nil)
        #expect(recent.loadRemote().isEmpty)
        store.closeSession(companion.id)
        #expect(recent.loadRemote().count == 1)
    }

    @Test func closingALocalRowAsEndedDoesNothing() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))

        store.closeEndedAttachedRow(local.id)

        #expect(store.session(withID: local.id) != nil)
    }

    @Test func aRelaunchKeepsTheFollowedCompanionsAndTellsAnEmptyBaselineFromNone() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let followed = try addAttachedRow(to: store, workspace: work.id)
        let empty = try addAttachedRow(to: store, workspace: work.id, origin: "o2")
        let unbaselined = try addAttachedRow(to: store, workspace: work.id, origin: "o3")
        let child = UUID()
        store.baselineCompanions([child.uuidString], forSession: followed.id)
        store.baselineCompanions([], forSession: empty.id)

        let restored = relaunched(store)

        let back = try #require(restored.session(withID: followed.id))
        #expect(back.companionsBaselined)
        #expect(back.followedCompanions == [child.uuidString])
        #expect(try #require(restored.session(withID: empty.id)).companionsBaselined)
        #expect(try #require(restored.session(withID: empty.id)).followedCompanions.isEmpty)
        #expect(try #require(restored.session(withID: unbaselined.id)).companionsBaselined == false)
    }

    @Test func aRowSavedWithoutTheFollowKeysRestoresEmptyAndNotBaselined() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let row = try addAttachedRow(to: store, workspace: work.id)
        store.baselineCompanions([UUID().uuidString], forSession: row.id)
        var snapshot = store.snapshot()
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.workspaces[0])) as? [String: Any])
        var attached = try #require(object["attached"] as? [[String: Any]])
        #expect(attached[0]["followedCompanions"] != nil)
        attached[0]["followedCompanions"] = nil
        attached[0]["companionsBaselined"] = nil
        object["attached"] = attached
        snapshot.workspaces[0] = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        let restored = makeStore()
        restored.restore(from: snapshot, launchRestore: true)

        let back = try #require(restored.session(withID: row.id))
        #expect(back.followedCompanions.isEmpty)
        #expect(!back.companionsBaselined)
    }

    @Test func aBuildThatPredatesAttachedRowsReadsOnlyTheLocalSessions() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try addAttachedRow(to: store, workspace: work.id)
        let data = try JSONEncoder().encode(store.snapshot().workspaces[0])

        let legacy = try JSONDecoder().decode(LegacyWorkspace.self, from: data)

        #expect(legacy.sessions.map(\.id) == [local.id])
    }

    @Test func aFileWithoutAttachedRowsOrWithAnUnreadableListStillRestoresItsSessions() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let local = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        _ = try addAttachedRow(to: store, workspace: work.id)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.snapshot().workspaces[0]))
            as? [String: Any])

        object["attached"] = nil
        let old = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        object["attached"] = "garbage"
        let broken = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(old.attached == nil)
        #expect(old.sessions.map(\.id) == [local.id])
        #expect(broken.attached == nil)
        #expect(broken.sessions.map(\.id) == [local.id])
    }
}

private struct LegacyWorkspace: Decodable {
    let id: UUID
    let name: String
    let sessions: [SessionSnapshot]
}
