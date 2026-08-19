import Foundation
import Testing
@testable import agtermCore

/// The `tree` projection of the agent-status change time. The stamping itself is covered by
/// `AppStoreTests`' `setAgentIndicator` cases; these cover what a control client reads back.
@MainActor
struct AppStoreStatusTests {
    @Test func controlTreeReportsStatusChangedAtAsEpochSeconds() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.statusChangedAt == session.statusChangedAt?.timeIntervalSince1970)
        // pinned against the wall clock, not only against the source: the field ships for comparison with
        // `ControlEvent.ts`, so a monotonic stamp would satisfy the equality above and still be unusable.
        let now = Date().timeIntervalSince1970
        let stamp = try #require(node.statusChangedAt)
        #expect(stamp > now - 60 && stamp <= now)
    }

    @Test func controlTreeNilsStatusChangedAtWhenIdle() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        #expect(store.controlTree().workspaces[0].sessions[0].statusChangedAt != nil)

        store.setAgentIndicator(AgentIndicator(status: .idle), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.status == nil)
        #expect(node.statusChangedAt == nil)
    }

    @Test func controlTreeRefreshesStatusChangedAtOnARePushOfTheSameStatus() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        session.statusChangedAt = Date(timeIntervalSince1970: 0) // pretend the glyph went stale
        let stale = try #require(store.controlTree().workspaces[0].sessions.first?.statusChangedAt)

        // an unchanged status is what the hooks re-push on every tool event; the age must still reset
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)

        let fresh = try #require(store.controlTree().workspaces[0].sessions.first?.statusChangedAt)
        #expect(fresh > stale)
    }
}
