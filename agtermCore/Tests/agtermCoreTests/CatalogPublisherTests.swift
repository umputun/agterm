import Foundation
import Testing
@testable import agtermCore

@MainActor
final class CatalogPublisherTests {
    private let store = makeStore()
    private let origin = OriginCatalogProjection()
    private let projection = CatalogProjection(endpoint: CatalogFixture.endpoint, mail: { _ in nil })
    private var queued: [@MainActor () -> Void] = []
    private var recent: [ControlRecentItem] = []
    private lazy var hub = CatalogHub(epoch: "e1", staleTimeout: 30) { [unowned self] in
        CatalogSnapshot(epoch: "", rev: 0, catalogID: CatalogFixture.catalog, versions: CatalogFixture.versions,
                        workspaces: origin.workspaces(of: store, projection: projection), recent: recent)
    }
    private lazy var publisher = CatalogPublisher(hub: hub) { [unowned self] work in queued.append(work) }
    private let session: Session

    init() throws {
        let workspace = store.addWorkspace(name: "work")
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/w"))
        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity])
        publisher.publish()
    }

    private func settle() async {
        for _ in 0..<200 where queued.isEmpty { await Task.yield() }
    }

    private func flush() {
        let work = queued
        queued.removeAll()
        for item in work { item() }
    }

    private func publishes(_ change: () -> Void) async -> Bool {
        let before = hub.rev
        change()
        await settle()
        flush()
        return hub.rev > before
    }

    @Test func aRenamedSessionPublishes() async {
        #expect(await publishes { store.renameSession(session.id, to: "renamed") })
    }

    @Test func aRenamedWorkspacePublishes() async throws {
        let workspace = try #require(store.workspaces.first)
        #expect(await publishes { store.renameWorkspace(workspace.id, to: "dev") })
    }

    @Test func aNewSessionPublishesOnceItsPaneRuns() async throws {
        let workspace = try #require(store.workspaces.first)
        let added = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/n", select: false))
        await settle()
        flush()

        #expect(await publishes { origin.evidence.running.insert(added.paneIdentity) })
    }

    @Test func aCwdChangePublishes() async {
        #expect(await publishes { session.currentCwd = "/elsewhere" })
    }

    @Test func aTerminalTitlePublishes() async {
        #expect(await publishes { session.oscTitle = "vim" })
    }

    @Test func aSplitLayoutChangePublishes() async throws {
        let split = UUID()
        origin.evidence.running.insert(split)
        #expect(await publishes {
            session.splitPaneIdentity = split
            session.hasSplit = true
            session.isSplit = true
        })
        #expect(await publishes { store.setSplitVisibility(session.id, shown: false) })
        #expect(await publishes { session.splitAxis = session.splitAxis == .leftRight ? .topBottom : .leftRight })
    }

    @Test func aScratchTogglePublishes() async {
        let scratch = UUID()
        session.scratchDaemon = Session.ScratchDaemon(identity: scratch, shown: false)
        origin.evidence.running.insert(scratch)
        await settle()
        flush()

        #expect(await publishes { session.scratchActive.toggle() })
    }

    @Test func aStoppedPanePublishesItHeld() async {
        #expect(await publishes { origin.evidence = CatalogPaneEvidence() })
        #expect(hub.snapshot().workspaces.first?.sessions.first?.panes.first?.held == true)
    }

    @Test func aMarkPublishesWhatObservationCannotSee() async {
        recent = [ControlRecentItem(id: UUID().uuidString, kind: "session", title: "gone", subtitle: nil, closedAt: 1,
                                    workspaceID: UUID().uuidString, sessionIDs: [])]
        #expect(await publishes { publisher.markDirty() })
    }

    @Test func changesInOneTurnPublishOnce() async {
        session.currentCwd = "/a"
        session.oscTitle = "b"
        publisher.markDirty()
        await settle()

        #expect(queued.count == 1)
    }

    @Test func aChangeTheCatalogDoesNotShowSchedulesNothing() async {
        session.unseenCount += 1
        for _ in 0..<50 { await Task.yield() }

        #expect(queued.isEmpty)
    }
}
