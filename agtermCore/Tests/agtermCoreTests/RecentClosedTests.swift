import Foundation
import Testing
@testable import agtermCore

final class RecentClosedTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("recent-closed.json") }

    // MARK: - remote sessions are never written to disk

    @MainActor
    @Test func closingARemoteSessionRecordsNothingToReopen() {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let ws = store.addWorkspace(name: "work")
        let remote = store.addSession(toWorkspace: ws.id, cwd: "/a", remoteHost: "buildbox")!

        store.closeSession(remote.id)

        #expect(recentClosed.load().isEmpty)
    }

    @MainActor
    @Test func closingAWorkspaceRecordsOnlyItsLocalSessionsAndCountsThem() {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        store.addWorkspace(name: "keep")
        let ws = store.addWorkspace(name: "mixed")
        let local = store.addSession(toWorkspace: ws.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: ws.id, cwd: "/b", remoteHost: "buildbox")

        store.removeWorkspace(ws.id)

        let item = try? #require(recentClosed.load().first { $0.kind == .workspace })
        #expect(item?.workspace?.snapshot.sessions.map(\.id) == [local.id])
        #expect(item?.subtitle == "1 session", "the count describes what Reopen will restore")
    }

    @MainActor
    @Test func aWorkspaceSelectionPointingAtARemoteSessionIsNotRestored() {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        store.addWorkspace(name: "keep")
        let ws = store.addWorkspace(name: "mixed")
        store.addSession(toWorkspace: ws.id, cwd: "/a")!
        let remote = store.addSession(toWorkspace: ws.id, cwd: "/b", remoteHost: "buildbox")!
        store.selectSession(remote.id)

        store.removeWorkspace(ws.id)

        let item = try? #require(recentClosed.load().first { $0.kind == .workspace })
        #expect(item?.workspace?.selectedSessionID == nil,
                "restoring a selection the snapshot no longer contains selects nothing")
    }

    @Test func diskRoundTripPreservesNewestFirstItems() {
        let store = RecentClosedStore(directory: directory)
        let first = sessionItem(title: "first")
        let second = workspaceItem(title: "workspace")

        store.record(first)
        store.record(second)

        let loaded = RecentClosedStore(directory: directory).load()
        #expect(loaded.map(\.id) == [second.id, first.id])
        #expect(loaded[0].workspace?.snapshot.name == "workspace")
        #expect(loaded[1].session?.snapshot.customName == "first")
    }

    @Test func recordDedupesSessionsAndWorkspacesBySnapshotID() {
        let store = RecentClosedStore(directory: directory)
        let sessionID = UUID()
        let workspaceID = UUID()

        store.record(sessionItem(id: UUID(), snapshotID: sessionID, title: "old session"))
        store.record(sessionItem(id: UUID(), snapshotID: sessionID, title: "new session"))
        store.record(workspaceItem(id: UUID(), snapshotID: workspaceID, title: "old workspace"))
        store.record(workspaceItem(id: UUID(), snapshotID: workspaceID, title: "new workspace"))

        let loaded = store.load()
        #expect(loaded.map(\.title) == ["new workspace", "new session"])
        #expect(loaded.compactMap { $0.session?.snapshot.id } == [sessionID])
        #expect(loaded.compactMap { $0.workspace?.snapshot.id } == [workspaceID])
    }

    @Test func defaultLimitKeepsTwentyNewestItems() {
        let store = RecentClosedStore(directory: directory)

        for index in 0..<25 {
            store.record(sessionItem(title: "session \(index)"))
        }

        let loaded = store.load()
        #expect(loaded.count == 20)
        #expect(loaded.first?.title == "session 24")
        #expect(loaded.last?.title == "session 5")
    }

    @Test func versionMismatchLoadsAsEmpty() throws {
        let item = sessionItem(title: "stale")
        let data = try JSONEncoder().encode(RecentClosedState(version: RecentClosedState.currentVersion + 1,
                                                              items: [item]))
        try data.write(to: fileURL)

        #expect(RecentClosedStore(directory: directory).load().isEmpty)
    }

    @Test func workspaceEntryWithoutFocusFieldsStillDecodes() throws {
        // `focusMember` is PERSISTED, and `load()` maps any decode failure onto an EMPTY list — so a
        // required key would wipe the user's whole recent list on the first launch after the upgrade.
        let data = try JSONEncoder().encode(RecentClosedState(items: [workspaceItem(title: "work")]))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("focusMember")) // the legacy shape verbatim
        try data.write(to: fileURL)

        let loaded = RecentClosedStore(directory: directory).load()
        #expect(loaded.count == 1)
        #expect(loaded[0].workspace?.focusMember == nil)
    }

    @Test func workspaceEntryWithALegacyFocusEnabledKeyStillDecodes() throws {
        // the other direction of the same rule: a DROPPED key must not fail the decode either.
        // `focusEnabled` was one — the reopen leg marks only, so nothing reads a stored filter flag.
        let encoded = try JSONEncoder().encode(RecentClosedState(items: [workspaceItem(title: "work")]))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var items = try #require(object["items"] as? [[String: Any]])
        var workspace = try #require(items[0]["workspace"] as? [String: Any])
        workspace["focusMember"] = true
        workspace["focusEnabled"] = true // the retired key, as an older build wrote it
        items[0]["workspace"] = workspace
        object["items"] = items
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        let loaded = RecentClosedStore(directory: directory).load()
        #expect(loaded.count == 1) // not the empty list a decode failure would produce
        #expect(loaded[0].workspace?.focusMember == true)
    }

    // the persisted pin comes back, but nothing is armed — a reopen cannot execute a sticky override
    // mid-process.
    @MainActor
    @Test func reopeningAClosedSessionRestoresThePinWithoutArmingIt() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        store.setRestoreCommand("claude --resume abc", pane: .left, forSession: session.id)
        store.closeSession(session.id)

        let item = try #require(recentClosed.load().first { $0.session?.snapshot.id == session.id })
        #expect(store.restoreRecentClosed(item))

        let reopened = try #require(store.session(withID: session.id))
        #expect(reopened !== session)
        #expect(reopened.restoreCommand == "claude --resume abc")
        #expect(reopened.pendingRestoreCommand == nil)
        #expect(reopened.pendingSplitRestoreCommand == nil)
    }

    private func sessionItem(id: UUID = UUID(), snapshotID: UUID = UUID(), title: String) -> RecentClosedItem {
        RecentClosedItem(
            id: id,
            kind: .session,
            title: title,
            subtitle: "work",
            session: RecentClosedSession(
                workspaceID: UUID(),
                workspaceName: "work",
                workspaceIndex: 0,
                sessionIndex: 0,
                snapshot: SessionSnapshot(id: snapshotID, customName: title, cwd: "/tmp")
            )
        )
    }

    private func workspaceItem(id: UUID = UUID(), snapshotID: UUID = UUID(), title: String) -> RecentClosedItem {
        RecentClosedItem(
            id: id,
            kind: .workspace,
            title: title,
            subtitle: "1 session",
            workspace: RecentClosedWorkspace(
                snapshot: WorkspaceSnapshot(
                    id: snapshotID,
                    name: title,
                    sessions: [SessionSnapshot(id: UUID(), customName: "api", cwd: "/tmp")]
                ),
                selectedSessionID: nil
            )
        )
    }
}
