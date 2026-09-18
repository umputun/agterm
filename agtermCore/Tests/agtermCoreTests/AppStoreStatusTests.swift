import Foundation
import Testing
@testable import agtermCore

@MainActor
private final class DraftCollector {
    var kinds: [ControlEventKind] = []
}

/// The `tree` projection of the agent-status change time, and the pane-precedence rule over a blocked
/// status. The stamping itself is covered by `AppStoreTests`' `setAgentIndicator` cases; these cover what
/// a control client reads back.
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

    @Test func controlTreeReportsStatusChangedAtWhenIdle() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        #expect(store.controlTree().workspaces[0].sessions[0].statusChangedAt == nil)
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: session.id)
        #expect(store.controlTree().workspaces[0].sessions[0].statusChangedAt != nil)

        session.statusChangedAt = Date(timeIntervalSince1970: 0)
        let before = Date().timeIntervalSince1970
        store.setAgentIndicator(AgentIndicator(status: .idle), forSession: session.id)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.status == nil)
        let stamp = try #require(node.statusChangedAt)
        #expect(stamp == session.statusChangedAt?.timeIntervalSince1970)
        #expect(stamp >= before)
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

    // MARK: - pane precedence over a blocked status

    /// A split session whose LEFT pane holds a blocked status — the two-agent shape the rule exists for.
    private func blockedLeftSplitSession() -> (AppStore, Session) {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        store.toggleSplit(session.id)
        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)
        return (store, session)
    }

    @Test(arguments: [AgentStatus.active, .completed, .idle])
    func rightPaneCannotReplaceTheLeftPanesBlock(_ status: AgentStatus) {
        let (store, session) = blockedLeftSplitSession()
        let stamp = session.statusChangedAt

        let result = store.applyControlStatus(AgentIndicator(status: status, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .refused(owner: .left))
        #expect(session.agentIndicator.status == .blocked)
        #expect(session.agentIndicator.statusPane == .left)
        #expect(session.statusChangedAt == stamp)
    }

    @Test(arguments: [AgentStatus.active, .completed, .idle])
    func theOwningPaneChangesItsOwnBlock(_ status: AgentStatus) {
        let (store, session) = blockedLeftSplitSession()

        let result = store.applyControlStatus(AgentIndicator(status: status, statusPane: .left),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == status)
    }

    @Test func anUntaggedWriterCountsAsTheLeftPane() {
        let (store, session) = blockedLeftSplitSession()

        #expect(store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id) == .applied)
        #expect(session.agentIndicator.status == .active)
    }

    @Test func theOtherPanesOwnBlockReplacesTheStandingOne() {
        let (store, session) = blockedLeftSplitSession()

        let result = store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.statusPane == .right)
    }

    // the bundled hooks emit `idle` unprompted from their own pane — Codex's `session-start` and the shell
    // integration's `precmd` — so an exempt cross-pane idle would let starting an agent wipe the sibling's block.
    @Test func theOwningPaneStillClearsItsBlockWithIdle() {
        let (store, session) = blockedLeftSplitSession()

        let result = store.applyControlStatus(AgentIndicator(status: .idle, statusPane: .left),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == .idle)
    }

    // a raw pane comparison rejects this: the writer's `.right` is what a promoted survivor's shell keeps
    // baked, and the setter stores it as `.left` — the pane it is now.
    @Test func aStaleRightTagOnASplitlessSessionOwnsTheBlockItSet() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        #expect(session.agentIndicator.statusPane == .left)

        let result = store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right),
                                              forSession: session.id)

        #expect(result == .applied)
        #expect(session.agentIndicator.status == .active)
    }

    @Test func aRefusedWriteEmitsNoStatusEvent() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let drafts = DraftCollector()
        let store = AppStore(persistence: PersistenceStore(directory: dir),
                             controlEventSink: { drafts.kinds.append($0.kind) })
        let ws = store.addWorkspace(name: "work")
        let session = store.addSession(toWorkspace: ws.id, cwd: "/repo")!
        store.toggleSplit(session.id)
        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)
        // an accepted write must reach this sink, or the refusal below proves nothing about the refusal.
        #expect(drafts.kinds.contains(.status))
        drafts.kinds.removeAll()

        store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right), forSession: session.id)

        #expect(drafts.kinds.isEmpty)
    }

    @MainActor
    private final class RecordingSink: PresentationSink {
        var frames: [PresentationFrame] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}

        var statuses: [PresentationStatus?] {
            frames.compactMap { if case .status(let status) = $0.body { return .some(status) } else { return nil } }
        }
    }

    private func mirroredStore() throws -> (AppStore, Session, RecordingSink) {
        let store = makeStore()
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.toggleSplit(session.id)
        let sink = RecordingSink()
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: [], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: session.id) }
        return (store, session, sink)
    }

    @Test func aStatusWriteReachesTheHubAsFullStateWithItsOwnerPaneAndGlyphOverrides() throws {
        let (store, session, sink) = try mirroredStore()
        let split = try #require(session.splitPaneIdentity)

        store.applyControlStatus(AgentIndicator(status: .blocked, blink: true, color: "#ff8800", shape: .star,
                                                statusPane: .right), forSession: session.id)

        let status = try #require(sink.statuses.last ?? nil)
        #expect(status.status == .blocked)
        #expect(status.blink)
        #expect(status.color == "#ff8800")
        #expect(status.shape == .star)
        #expect(status.pane == .identity(split))
        #expect(status.changedAt == session.statusChangedAt?.timeIntervalSince1970)
    }

    @Test(arguments: [StatusPane.left, .scratch, nil])
    func theOwnerPaneTravelsAsAnIdentityOrScratch(_ pane: StatusPane?) throws {
        let (store, session, sink) = try mirroredStore()

        store.applyControlStatus(AgentIndicator(status: .active, statusPane: pane), forSession: session.id)

        let expected: PresentationPane = pane == .scratch ? .scratch : .identity(session.paneIdentity)
        #expect((sink.statuses.last ?? nil)?.pane == expected)
    }

    @Test func idleReachesTheHubAsAnAbsentStatus() throws {
        let (store, session, sink) = try mirroredStore()
        store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id)

        store.applyControlStatus(AgentIndicator(status: .idle), forSession: session.id)

        #expect(sink.statuses.count == 2)
        #expect(sink.statuses.last == .some(nil))
    }

    @Test func aRefusedWritePublishesNothing() throws {
        let (store, session, sink) = try mirroredStore()
        store.applyControlStatus(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)

        store.applyControlStatus(AgentIndicator(status: .active, statusPane: .right), forSession: session.id)

        #expect(sink.statuses.count == 1)
    }

    @Test func aRepeatedIdenticalWriteRepublishesTheRestampedState() throws {
        let (store, session, sink) = try mirroredStore()

        store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id)
        session.statusChangedAt = Date(timeIntervalSince1970: 1)
        store.applyControlStatus(AgentIndicator(status: .active), forSession: session.id)

        #expect(sink.statuses.count == 2)
        #expect((sink.statuses.last ?? nil)?.changedAt == session.statusChangedAt?.timeIntervalSince1970)
        #expect((sink.statuses.last ?? nil)?.changedAt != 1)
    }

    @Test func theSnapshotOfAnIdleSessionHasNoStatus() throws {
        let (store, session, _) = try mirroredStore()

        #expect(store.presentationSnapshot(forSession: session.id).status == nil)
    }
}
