import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreHiddenSplitExitTests {
    private final class Probes {
        var states: [UUID: DaemonProbe] = [:]
        var finalized: [UUID] = []
    }

    private struct Fixture {
        let store: AppStore
        let session: Session
        let split: UUID
    }

    private func fixture(_ probes: Probes?) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir), paneFinalizer: { probes?.finalized += $0 },
                             daemonProbe: probes.map { probes in { probes.states[$0] ?? .absent } })
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        session.surface = SpySurface(paneToken: session.paneIdentity.uuidString, backedByZmx: true)
        store.setSplitVisibility(session.id, shown: true)
        store.setSplitVisibility(session.id, shown: false)
        let split = try #require(session.splitPaneIdentity)
        session.initialSplitCwd = "/split"
        session.pendingForegroundCommand = ["top"]
        session.pendingSplitForegroundCommand = ["vim", "notes"]
        return Fixture(store: store, session: session, split: split)
    }

    @Test func aSurfacelessSplitWhoseDaemonRunsTakesThePrimarySlot() throws {
        let probes = Probes()
        let f = try fixture(probes)
        probes.states[f.split] = .running(leader: 100)

        #expect(f.store.closePrimaryPane(f.session.id) == .promoted)

        #expect(f.store.session(withID: f.session.id) === f.session)
        #expect(f.session.paneIdentity == f.split)
        #expect(f.session.surface == nil)
        #expect(f.session.hasSplit == false)
        #expect(f.session.splitPaneIdentity == nil)
        #expect(f.session.currentCwd == "/split")
        #expect(f.session.initialCwd == "/split")
        #expect(f.session.pendingForegroundCommand == ["vim", "notes"])
        #expect(f.session.pendingSplitForegroundCommand == nil)
        #expect(!probes.finalized.contains(f.split))
    }

    @Test(arguments: [(DaemonProbe?.some(.unknown), PrimaryPaneExit.promoted), (.some(.absent), .closed), (nil, .closed)])
    func aSurfacelessSplitIsKeptUnlessItsDaemonIsKnownGone(probe: DaemonProbe?, outcome: PrimaryPaneExit) throws {
        let probes = Probes()
        let f = try fixture(probe == nil ? nil : probes)
        if let probe { probes.states[f.split] = probe }

        #expect(f.store.closePrimaryPane(f.session.id) == outcome)
        #expect(!probes.finalized.contains(f.split) || outcome == .closed)
    }

    @Test func mailQueuedForTheHiddenSplitFollowsItIntoThePrimarySlot() throws {
        let probes = Probes()
        let f = try fixture(probes)
        probes.states[f.split] = .running(leader: 100)
        let recipient = try #require(f.store.messageRecipient(session: f.session.id, pane: .role(.right)))
        _ = try MessageBus.shared.send("hi", from: nil, to: [recipient], now: 1)

        #expect(f.store.closePrimaryPane(f.session.id) == .promoted)

        #expect(f.store.messageRecipient(session: f.session.id, pane: .role(.left))?.pane == f.split)
        #expect(MessageBus.shared.pending(for: f.split) == 1)
        MessageBus.shared.dispose(pane: f.split)
    }
}
