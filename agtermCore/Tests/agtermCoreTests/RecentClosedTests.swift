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

    /// Reopen Closed Item rebuilds the session from its snapshot through `session(from:)`, which defaults
    /// to arming nothing: the persisted pin comes back (so `tree` reads it and the next launch fires it),
    /// but no payload is pending, so reopening cannot execute a sticky override mid-process.
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
        #expect(reopened !== session) // rebuilt from the snapshot, not the original object
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
