import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreSessionStateTests {
    private final class RecordingSink: PresentationSink {
        var frames: [PresentationFrame] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}

        var contexts: [String?] {
            frames.compactMap { if case .context(let context) = $0.body { return .some(context) } else { return nil } }
        }
    }

    private func mirroredStore(context: String? = nil) throws -> (AppStore, Session, RecordingSink) {
        let store = makeStore()
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.setContext(context, forSession: session.id)
        let sink = RecordingSink()
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: [], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: session.id) }
        return (store, session, sink)
    }

    @Test func aContextChangeReachesTheHubAndAClearTravelsAsNone() throws {
        let (store, session, sink) = try mirroredStore()

        store.setContext("PR #517", forSession: session.id)
        store.setContext(nil, forSession: session.id)

        #expect(sink.contexts == ["PR #517", nil])
    }

    @Test func anUnchangedContextPublishesNothing() throws {
        let (store, session, sink) = try mirroredStore(context: "PR #517")

        store.setContext("PR #517", forSession: session.id)

        #expect(sink.contexts.isEmpty)
    }

    private func flagStore() throws -> (store: AppStore, target: (id: UUID, sessions: [Session]), other: Session) {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "target")
        let sessions = try ["/a", "/b", "/c"].map { try #require(store.addSession(toWorkspace: workspace.id, cwd: $0)) }
        let otherWorkspace = store.addWorkspace(name: "other")
        let other = try #require(store.addSession(toWorkspace: otherWorkspace.id, cwd: "/other"))
        return (store, (workspace.id, sessions), other)
    }

    @Test(arguments: [
        (initial: [false, false, false], mode: ControlToggleMode.on, want: true),
        (initial: [true, false, true], mode: .on, want: true),
        (initial: [true, true, true], mode: .off, want: false),
        (initial: [true, false, true], mode: .off, want: false),
        (initial: [false, false, false], mode: .toggle, want: true),
        (initial: [true, false, true], mode: .toggle, want: true),
        (initial: [true, true, true], mode: .toggle, want: false),
    ])
    func workspaceFlagSetsEverySessionToOneValue(initial: [Bool], mode: ControlToggleMode, want: Bool) throws {
        let (store, target, other) = try flagStore()
        for (session, flagged) in zip(target.sessions, initial) { store.setFlag(flagged, forSession: session.id) }
        store.setFlag(true, forSession: other.id)

        store.applyWorkspaceFlag(mode, to: target.id)

        #expect(target.sessions.map(\.flagged) == [want, want, want])
        #expect(store.allSessionsFlagged(inWorkspace: target.id) == want)
        #expect(other.flagged, "another workspace's sessions are not touched")
    }

    @Test func workspaceFlagOnAnEmptyOrUnknownWorkspaceChangesNothing() throws {
        let (store, _, other) = try flagStore()
        let empty = store.addWorkspace(name: "empty")

        store.applyWorkspaceFlag(.on, to: empty.id)
        store.applyWorkspaceFlag(.on, to: UUID())

        #expect(!store.allSessionsFlagged(inWorkspace: empty.id))
        #expect(!other.flagged)
    }

    @Test func workspaceFlagFlagsSessionsTheFlaggedViewHides() throws {
        let (store, target, _) = try flagStore()
        let visible = try #require(target.sessions.first)
        store.setFlag(true, forSession: visible.id)
        store.setSidebarMode(.flagged)

        store.applyWorkspaceFlag(.toggle, to: target.id)

        #expect(store.flaggedSessions.map(\.id) == target.sessions.map(\.id))
    }

    @Test func workspaceUnflagInFlaggedModeReselectsAVisibleSession() throws {
        let (store, target, other) = try flagStore()
        store.applyWorkspaceFlag(.on, to: target.id)
        store.setFlag(true, forSession: other.id)
        let active = try #require(target.sessions.last)
        store.selectSession(active.id)
        store.setSidebarMode(.flagged)

        store.applyWorkspaceFlag(.toggle, to: target.id)

        #expect(store.selectedSessionID == other.id)
    }

    @Test func aLateSubscribersSnapshotCarriesTheContext() throws {
        let (_, _, sink) = try mirroredStore(context: "PR #517")

        let snapshots = sink.frames.compactMap { if case .snapshot(let snapshot) = $0.body { return snapshot } else { return nil } }
        #expect(snapshots.map(\.context) == ["PR #517"])
    }
}
