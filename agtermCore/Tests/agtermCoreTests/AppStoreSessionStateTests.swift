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

    @Test func aLateSubscribersSnapshotCarriesTheContext() throws {
        let (_, _, sink) = try mirroredStore(context: "PR #517")

        let snapshots = sink.frames.compactMap { if case .snapshot(let snapshot) = $0.body { return snapshot } else { return nil } }
        #expect(snapshots.map(\.context) == ["PR #517"])
    }
}
