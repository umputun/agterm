import Foundation
import Testing
@testable import agtermCore

@MainActor
final class RemoteCatalogMirrorDetachTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-detach-\(UUID().uuidString)")
    private let store: AppStore
    private let effects = Effects()
    private var mirror: RemoteCatalogMirror
    private static let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")
    private static let versions = CatalogVersions(server: "1.2.3", protocolVersion: 1, catalog: 1)
    private let catalogID = UUID()
    private let workspaceID = UUID()
    private let otherWorkspaceID = UUID()

    init() {
        store = AppStore(persistence: PersistenceStore(directory: directory), paneFinalizer: nil)
        mirror = RemoteCatalogMirror(host: "box", store: store, effects: effects, viewState: RemoteWindowViewState())
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private final class Effects: RemoteCatalogEffects {
        var added: [UUID] = []
        var removed: [UUID] = []
        var removedWhileListed: [UUID] = []
        var store: AppStore?
        var saves = 0

        func attachCommand(host: String, pane: CatalogPane) -> String { "attach \(host) \(pane.daemon)" }
        func catalogRowAdded(_ session: Session) { added.append(session.id) }
        func catalogRowRemoved(_ sessionID: UUID) {
            removed.append(sessionID)
            if store?.session(withID: sessionID) != nil { removedWhileListed.append(sessionID) }
        }
        func catalogRowEnded(_: UUID) {}
        func catalogPaneNeedsAttach(_: UUID, session _: UUID) {}
        func catalogBound(_: UUID) -> Bool { true }
        func catalogStateChanged(_: RemoteCatalogMirror.State) {}
        func catalogViewStateChanged() { saves += 1 }
    }

    private func session(_ id: UUID = UUID(), name: String = "s", parent: UUID? = nil, ended: Bool = false) -> CatalogSession {
        let pane = CatalogPane(identity: UUID(), daemon: "agterm-\(id.uuidString)", endpoint: Self.endpoint)
        return CatalogSession(fields: CatalogSessionFields(id: id, name: name, parent: parent, cwd: "/srv", primary: pane.identity,
                                                           axis: nil, shown: false, lifecycle: ended ? .ended : .live),
                              panes: ended ? [] : [pane])
    }

    private final class Surface: TerminalSurface {
        var isRealized = true
        var paneToken = UUID().uuidString
        var tornDown = false
        func teardown() { tornDown = true }
        func promoteToPrimaryPane() {}
    }

    private func open(_ sessions: [CatalogSession], other: [CatalogSession] = []) {
        let snapshot = CatalogSnapshot(epoch: "e1", rev: 0, catalogID: catalogID, versions: Self.versions,
                                       workspaces: [CatalogWorkspace(id: workspaceID, name: "w", sessions: sessions),
                                                    CatalogWorkspace(id: otherWorkspaceID, name: "other", sessions: other)])
        _ = mirror.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: Self.versions)))
        _ = mirror.receive(.snapshot(snapshot))
    }

    private func delta(_ rev: Int, _ change: CatalogChange) {
        _ = mirror.receive(.delta(epoch: "e1", rev: rev, change: change))
    }

    private var rows: Set<UUID> { Set(store.workspaces.flatMap(\.sessions).map(\.id)) }

    @Test func detachingEndsTheScratchAttachAndReattachingAttachesItAgain() throws {
        var entry = session()
        let scratch = UUID()
        let pane = CatalogPane(identity: scratch, daemon: ZmxSupport.scratchDaemonName(for: scratch), endpoint: Self.endpoint)
        entry.fields.scratch = CatalogScratch(pane: pane, shown: true)
        open([entry])
        let surface = Surface()
        try #require(store.session(withID: entry.id)).scratchSurface = surface

        mirror.detach(sessions: [entry.id])

        #expect(surface.tornDown)
        #expect(mirror.catalog?.session(entry.id)?.fields.scratch?.pane.identity == scratch)

        #expect(mirror.reattach(session: entry.id) == nil)

        let row = try #require(store.session(withID: entry.id))
        #expect(row.scratchActive)
        #expect(row.scratchCommand == "attach box \(pane.daemon)")
    }

    @Test func aDetachedRowLeavesThisMacAndStaysDetached() {
        let first = session(), second = session()
        open([first, second])

        mirror.detach(sessions: [first.id])

        #expect(rows == [second.id])
        #expect(effects.removed == [first.id])
        #expect(store.catalogDetachedSessions == [first.id])
        #expect(effects.saves == 1)
    }

    @Test func aDetachedRowsStreamStopsBeforeTheRowIsTornDown() {
        let row = session()
        open([row])
        effects.store = store

        mirror.detach(sessions: [row.id])

        #expect(effects.removedWhileListed == [row.id])
    }

    @Test func aDetachedParentHidesItsCompanionsAndOnesMadeLater() {
        let parent = session(), companion = session(parent: parent.id)
        open([parent, companion])

        mirror.detach(sessions: [parent.id])
        delta(1, .sessionAdded(session(parent: parent.id), workspace: workspaceID, index: 2))

        #expect(rows.isEmpty)
        #expect(mirror.detachedItems.map(\.id) == [parent.id])
    }

    @Test func aDetachedRowStaysHiddenOnceEndedAndIsListedAsEnded() {
        let first = session()
        open([first, session()])
        mirror.detach(sessions: [first.id])

        delta(1, .sessionChanged(session(first.id, ended: true).fields))

        #expect(!rows.contains(first.id))
        #expect(mirror.detachedItems == [RemoteDetachedItem(kind: .session, id: first.id, name: "s", ended: true)])
    }

    @Test func aDetachedIdIsForgottenOnlyWhenItsRecordGoes() {
        let first = session()
        open([first, session()])
        mirror.detach(sessions: [first.id])
        let saves = effects.saves

        delta(1, .sessionRemoved(first.id))

        #expect(store.catalogDetachedSessions.isEmpty)
        #expect(effects.saves == saves + 1)
    }

    @Test func aReattachedRowComesBackWithItsView() throws {
        let first = session()
        open([first, session()])
        try #require(store.session(withID: first.id)).fontSize = 17
        mirror.detach(sessions: [first.id])

        let refusal = mirror.reattach(session: first.id)

        #expect(refusal == nil)
        #expect(store.session(withID: first.id)?.fontSize == 17)
        #expect(effects.added.filter { $0 == first.id }.count == 2)
    }

    @Test func aDetachedWorkspaceHidesEveryRowAndAnEmptyOneToo() {
        let inside = session()
        open([session()], other: [inside])

        mirror.detach(workspace: otherWorkspaceID)
        let hidden = store.workspaces.map(\.id)
        mirror.detach(workspace: workspaceID)

        #expect(hidden == [workspaceID])
        #expect(store.workspaces.isEmpty)
        #expect(!store.canCloseWorkspace)
        #expect(mirror.detachedItems.map(\.kind) == [.workspace, .workspace])
        #expect(mirror.reattach(workspace: otherWorkspaceID) == nil)
        #expect(rows == [inside.id])
    }

    @Test func aChildDetachedBeforeItsParentComesBackOnItsOwn() {
        let parent = session(), companion = session(parent: parent.id)
        open([parent, companion])

        mirror.detach(sessions: [companion.id])
        mirror.detach(sessions: [parent.id])
        let listed = mirror.detachedItems.map(\.id)
        let refused = mirror.reattach(session: companion.id)
        _ = mirror.reattach(session: parent.id)

        #expect(listed == [parent.id])
        #expect(refused == "its parent is detached; reattach the parent")
        #expect(rows == [parent.id])
        #expect(mirror.detachedItems.map(\.id) == [companion.id])
    }

    @Test func aSessionUnderADetachedWorkspaceIsNotListedAndRefusesReattach() {
        let inside = session()
        open([session()], other: [inside])

        mirror.detach(sessions: [inside.id])
        mirror.detach(workspace: otherWorkspaceID)

        #expect(mirror.detachedItems.map(\.id) == [otherWorkspaceID])
        #expect(mirror.reattach(session: inside.id) == "its workspace is detached; reattach the workspace")
    }

    @Test func detachingWhileDisconnectedHidesTheRow() {
        let first = session()
        open([first, session()])
        mirror.connectionLost("gone")

        mirror.detach(sessions: [first.id])

        #expect(!rows.contains(first.id))
    }

    @Test func detachedStateAndHiddenViewsOutliveTheWindow() throws {
        let first = session()
        open([first, session()])
        try #require(store.session(withID: first.id)).fontSize = 19
        mirror.detach(sessions: [first.id])

        let saved = RemoteWindowViewState.capture(from: store)
        let restored = try JSONDecoder().decode(RemoteWindowViewState.self, from: JSONEncoder().encode(saved))
        let relaunched = AppStore(persistence: PersistenceStore(directory: directory), paneFinalizer: nil)
        mirror = RemoteCatalogMirror(host: "box", store: relaunched, effects: effects, viewState: restored)
        let snapshot = CatalogSnapshot(epoch: "e2", rev: 0, catalogID: catalogID, versions: Self.versions,
                                       workspaces: [CatalogWorkspace(id: workspaceID, name: "w", sessions: [first, session()])])
        _ = mirror.receive(.snapshot(snapshot))
        let hiddenAfterRelaunch = relaunched.session(withID: first.id) == nil
        _ = mirror.reattach(session: first.id)

        #expect(saved.detachedSessions == [first.id])
        #expect(saved.sessions[first.id]?.fontSize == 19)
        #expect(hiddenAfterRelaunch)
        #expect(relaunched.session(withID: first.id)?.fontSize == 19)
    }

    @Test func anOlderViewStateFileDecodesWithNothingDetached() throws {
        let json = #"{"collapsedWorkspaces":[],"sessions":[]}"#

        let state = try JSONDecoder().decode(RemoteWindowViewState.self, from: Data(json.utf8))

        #expect(state.detachedSessions.isEmpty)
        #expect(state.detachedWorkspaces.isEmpty)
    }

    @Test func anEndedRowWithARunningScratchCountsAsLive() {
        var ended = session(ended: true)
        let scratch = UUID()
        ended.fields.scratch = CatalogScratch(pane: CatalogPane(identity: scratch, daemon: ZmxSupport.scratchDaemonName(for: scratch),
                                                                endpoint: Self.endpoint), shown: false)
        open([ended])

        #expect(mirror.closeScope(session: ended.id) == RemoteCloseScope(sessions: [ended.id], live: true))
    }

    @Test func closingAParentReachesItsCompanionsAndCountsThemAsLive() {
        let parent = session(ended: true), companion = session(parent: parent.id)
        let inert = session(ended: true)
        open([parent, companion, inert])

        #expect(mirror.closeScope(session: parent.id) == RemoteCloseScope(sessions: [parent.id, companion.id], live: true))
        #expect(mirror.closeScope(session: inert.id) == RemoteCloseScope(sessions: [inert.id], live: false))
        #expect(mirror.closeScope(session: companion.id) == RemoteCloseScope(sessions: [companion.id], live: true))
    }

    @Test func aRemoteWindowCanCloseItsLastShownWorkspaceAndTerminatesOnlyWithAnotherOnTheServer() {
        open([session()], other: [session()])
        mirror.detach(workspace: otherWorkspaceID)

        let lastShown = store.canCloseWorkspace
        let withDetachedSibling = mirror.canTerminateWorkspace
        let local = AppStore(persistence: PersistenceStore(directory: directory), paneFinalizer: nil)
        local.addWorkspace(name: "only")

        #expect(store.workspaces.count == 1)
        #expect(lastShown)
        #expect(withDetachedSibling)
        #expect(!local.canCloseWorkspace)
    }

    @Test func theServersOnlyWorkspaceCannotBeTerminated() {
        let snapshot = CatalogSnapshot(epoch: "e1", rev: 0, catalogID: catalogID, versions: Self.versions,
                                       workspaces: [CatalogWorkspace(id: workspaceID, name: "w", sessions: [session()])])
        _ = mirror.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: Self.versions)))
        _ = mirror.receive(.snapshot(snapshot))

        #expect(store.canCloseWorkspace)
        #expect(!mirror.canTerminateWorkspace)
    }

    @Test func aRowResetToDefaultsBeforeDetachComesBackAtTheDefaults() throws {
        let first = session()
        var saved = RemoteWindowViewState()
        saved.sessions[first.id] = RemoteWindowViewState.SessionView(fontSize: 21)
        mirror = RemoteCatalogMirror(host: "box", store: store, effects: effects, viewState: saved)
        open([first, session()])
        let row = try #require(store.session(withID: first.id))
        let restored = row.fontSize
        row.fontSize = nil

        mirror.detach(sessions: [first.id])
        _ = mirror.reattach(session: first.id)

        #expect(restored == 21)
        #expect(store.session(withID: first.id)?.fontSize == nil)
    }

    @Test func aDetachedWorkspaceKeepsItsCollapseThroughARelaunch() {
        open([session()], other: [session()])
        store.setWorkspaceExpanded(otherWorkspaceID, expanded: false)

        mirror.detach(workspace: otherWorkspaceID)
        let saved = RemoteWindowViewState.capture(from: store)
        let relaunched = AppStore(persistence: PersistenceStore(directory: directory), paneFinalizer: nil)
        mirror = RemoteCatalogMirror(host: "box", store: relaunched, effects: effects, viewState: saved)
        open([session()], other: [session()])
        _ = mirror.reattach(workspace: otherWorkspaceID)

        #expect(saved.collapsedWorkspaces == [otherWorkspaceID])
        #expect(relaunched.workspaces.first { $0.id == otherWorkspaceID }?.isExpanded == false)
    }

    @Test func aWorkspaceExpandedBeforeDetachComesBackExpanded() {
        mirror = RemoteCatalogMirror(host: "box", store: store, effects: effects,
                                     viewState: RemoteWindowViewState(collapsedWorkspaces: [otherWorkspaceID]))
        open([session()], other: [session()])
        store.setWorkspaceExpanded(otherWorkspaceID, expanded: true)

        mirror.detach(workspace: otherWorkspaceID)
        _ = mirror.reattach(workspace: otherWorkspaceID)

        #expect(store.workspaces.first { $0.id == otherWorkspaceID }?.isExpanded == true)
    }

    @Test func anEndedSessionIsNotReattachedButPointedAtCleanup() {
        let first = session()
        open([first, session()])
        mirror.detach(sessions: [first.id])
        delta(1, .sessionChanged(session(first.id, ended: true).fields))

        #expect(mirror.reattach(session: first.id) == "the session has ended; session.close removes its record")
        #expect(!rows.contains(first.id))
        #expect(store.catalogDetachedSessions == [first.id])
    }
}
