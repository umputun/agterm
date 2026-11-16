import Foundation
import Testing
@testable import agtermCore

@MainActor
struct CatalogProjectionTests {
    private let projection = CatalogProjection(endpoint: ControlZmxEndpoint(executable: "/bin/zmx", socketDirectory: "/tmp/zmx"),
                                               mail: { _ in nil })
    private let store = makeStore()
    private let origin = OriginCatalogProjection()

    private func workspace(_ name: String = "work") -> Workspace { store.addWorkspace(name: name) }

    private func terminal(in workspace: Workspace, split: Bool = false, shown: Bool = true) throws -> Session {
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/w"))
        if split {
            session.hasSplit = true
            session.isSplit = shown
            session.splitPaneIdentity = UUID()
        }
        return session
    }

    private func rows() -> [CatalogSession] { origin.workspaces(of: store, projection: projection).flatMap(\.sessions) }

    private func row(_ session: Session) -> CatalogSession? { rows().first { $0.id == session.id } }

    private func held(_ row: CatalogSession?) -> [Bool] { row?.panes.map { $0.held == true } ?? [] }

    @Test func aSessionCarriesEveryPaneInOrderWithItsScratch() throws {
        let session = try terminal(in: workspace(), split: true)
        let scratch = UUID()

        let row = projection.session(session, scratch: Session.ScratchDaemon(identity: scratch, shown: true))

        #expect(row.panes.map(\.identity) == [session.paneIdentity, session.splitPaneIdentity])
        #expect(row.panes.map(\.daemon) == [ZmxSupport.daemonName(for: session.paneIdentity),
                                             ZmxSupport.daemonName(for: try #require(session.splitPaneIdentity))])
        #expect(row.panes.allSatisfy { $0.held == nil })
        #expect(row.fields.scratch?.pane.identity == scratch)
        #expect(row.fields.scratch?.shown == true)
        #expect(row.fields.lifecycle == .live)
        #expect(row.fields.axis == session.splitAxis.rawValue)
    }

    @Test func evidenceRunsOnlyClaimedRunningPanes() throws {
        let window = UUID()
        let running = UUID(), stopped = UUID(), orphan = UUID()
        let claims = [running, stopped].map {
            ZmxPaneClaim(paneIdentity: $0, pane: .left, pendingClose: false, windowID: window, windowName: "w",
                         windowState: .open, workspaceID: nil, workspaceName: nil, sessionID: UUID(), sessionName: nil)
        }
        let observed = [ZmxSessionRecord(name: ZmxSupport.daemonName(for: running), clients: 1),
                        ZmxSessionRecord(name: ZmxSupport.daemonName(for: orphan), clients: 0)]

        let evidence = CatalogPaneEvidence(inventory: ZmxInventory.join(observed: observed, claims: claims, inventoryComplete: true))

        #expect(evidence.running == [running])
        #expect(evidence.runs(running))
        #expect(!evidence.runs(stopped))
        #expect(!evidence.runs(orphan))
    }

    @Test func aRowWhosePrimaryHasNotStartedIsLeftOut() throws {
        let session = try terminal(in: workspace())

        #expect(row(session) == nil)
    }

    @Test func aRowIsListedOnceItsPrimaryRuns() throws {
        let session = try terminal(in: workspace())
        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity])

        let listed = try #require(row(session))

        #expect(listed.fields.lifecycle == .live)
        #expect(listed.panes.map(\.identity) == [session.paneIdentity])
        #expect(held(listed) == [false])
    }

    @Test func aRestartingPaneStaysListedAndRunning() throws {
        let session = try terminal(in: workspace())
        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity])
        _ = rows()

        origin.evidence = CatalogPaneEvidence(restarting: [session.paneIdentity])

        let listed = try #require(row(session))
        #expect(listed.fields.lifecycle == .live)
        #expect(held(listed) == [false])
    }

    @Test func aHeldPrimaryBesideARunningSplitKeepsBothInOriginOrder() throws {
        let session = try terminal(in: workspace(), split: true)
        let split = try #require(session.splitPaneIdentity)
        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity, split])
        _ = rows()

        origin.evidence = CatalogPaneEvidence(running: [split])

        let listed = try #require(row(session))
        #expect(listed.fields.lifecycle == .live)
        #expect(listed.fields.primary == session.paneIdentity)
        #expect(listed.panes.map(\.identity) == [session.paneIdentity, split])
        #expect(held(listed) == [true, false])
    }

    @Test func aHeldSplitBesideARunningPrimaryStaysListedAsHeld() throws {
        let session = try terminal(in: workspace(), split: true)
        let split = try #require(session.splitPaneIdentity)
        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity])

        let listed = try #require(row(session))

        #expect(listed.fields.lifecycle == .live)
        #expect(listed.panes.map(\.identity) == [session.paneIdentity, split])
        #expect(held(listed) == [false, true])
    }

    @Test func aRowWhosePanesAreAllHeldIsEndedWithBothPanes() throws {
        let session = try terminal(in: workspace(), split: true)
        let split = try #require(session.splitPaneIdentity)
        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity, split])
        _ = rows()

        origin.evidence = CatalogPaneEvidence()

        let listed = try #require(row(session))
        #expect(listed.fields.lifecycle == .ended)
        #expect(listed.panes.map(\.identity) == [session.paneIdentity, split])
        #expect(held(listed) == [true, true])
    }

    @Test func aRowThatLeftTheStoreWaitsForItsDaemonWhenItComesBack() throws {
        let work = workspace()
        let session = try terminal(in: work)
        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity])
        _ = rows()
        let index = try #require(store.workspaces.firstIndex { $0.id == work.id })
        store.workspaces[index].sessions.removeAll { $0.id == session.id }
        _ = rows()

        store.workspaces[index].sessions.append(session)
        origin.evidence = CatalogPaneEvidence()

        #expect(row(session) == nil)
    }

    @Test func aHiddenSplitWhoseDaemonRunsIsListedWithoutALocalAttach() throws {
        let session = try terminal(in: workspace(), split: true, shown: false)
        let split = try #require(session.splitPaneIdentity)
        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity, split])

        let listed = try #require(row(session))

        #expect(listed.fields.shown == false)
        #expect(held(listed) == [false, false])
    }

    @Test func aRunningScratchIsListedAndAStoppedOneIsNot() throws {
        let session = try terminal(in: workspace())
        let scratch = UUID()
        session.scratchDaemon = Session.ScratchDaemon(identity: scratch, shown: false)
        session.scratchActive = true
        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity, scratch])

        #expect(row(session)?.fields.scratch == CatalogScratch(pane: projection.pane(scratch), shown: true))

        origin.evidence = CatalogPaneEvidence(running: [session.paneIdentity])
        #expect(row(session)?.fields.scratch == nil)
    }

    @Test func aRowAttachedFromAnotherHostIsLeftOut() throws {
        let work = workspace()
        let attached = try #require(store.addSession(toWorkspace: work.id, cwd: "/r", remoteHost: "box", remoteSessionID: "s1"))
        origin.evidence = CatalogPaneEvidence(running: [attached.paneIdentity])

        #expect(row(attached) == nil)
    }

    @Test func aPageRowIsListedWithItsPageAndNoPane() throws {
        let work = workspace()
        let page = try addPageRow(to: store, workspace: work.id,
                                  overlay: HtmlOverlay(source: .url(try #require(URL(string: "http://localhost:8080")))))

        let listed = try #require(row(page))

        #expect(listed.panes.isEmpty)
        #expect(listed.fields.page?.kind == "url")
        #expect(listed.fields.lifecycle == .live)
    }

    @Test func aCompanionIsListedOnlyWithItsParent() throws {
        let work = workspace()
        let parent = try terminal(in: work)
        let companion = try store.addCompanion(to: parent.id, options: CompanionOptions(cwd: "/c")).get()
        origin.evidence = CatalogPaneEvidence(running: [companion.paneIdentity])

        #expect(row(companion) == nil)

        origin.evidence = CatalogPaneEvidence(running: [companion.paneIdentity, parent.paneIdentity])
        #expect(rows().map(\.id) == [parent.id, companion.id])
    }

    @Test func anEmptyWorkspaceAndAWorkspaceOfStartingRowsAreKept() throws {
        let empty = workspace("empty")
        let starting = workspace("starting")
        _ = try terminal(in: starting)

        let workspaces = origin.workspaces(of: store, projection: projection)

        #expect(workspaces.map(\.id) == [empty.id, starting.id])
        #expect(workspaces.map(\.sessions.count) == [0, 0])
    }

    @Test func anEmptyWindowHasNoWorkspaces() {
        #expect(origin.workspaces(of: store, projection: projection).isEmpty)
    }
}
