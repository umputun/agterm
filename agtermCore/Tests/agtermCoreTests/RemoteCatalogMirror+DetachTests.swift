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

        func attachCommand(host: String, pane: CatalogPane, claim _: Bool) -> String { "attach \(host) \(pane.daemon)" }
        func catalogRowAdded(_ session: Session) { added.append(session.id) }
        func catalogRowRemoved(_ sessionID: UUID) {
            removed.append(sessionID)
            if store?.session(withID: sessionID) != nil { removedWhileListed.append(sessionID) }
        }
        func catalogRowEnded(_: UUID) {}
        var needsAttach: [UUID] = []
        func catalogPaneNeedsAttach(_ identity: UUID, session _: UUID) { needsAttach.append(identity) }
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

    @discardableResult
    private func open(_ sessions: [CatalogSession], other: [CatalogSession] = [], tint: String? = nil) -> CatalogSnapshot {
        let snapshot = CatalogSnapshot(epoch: "e1", rev: 0, catalogID: catalogID, versions: Self.versions,
                                       workspaces: [CatalogWorkspace(id: workspaceID, name: "w", tint: tint, sessions: sessions),
                                                    CatalogWorkspace(id: otherWorkspaceID, name: "other", tint: tint, sessions: other)])
        _ = mirror.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: Self.versions)))
        _ = mirror.receive(.snapshot(snapshot))
        return snapshot
    }

    private func reopen(_ snapshot: CatalogSnapshot) -> AppStore {
        let saved = RemoteWindowViewState.capture(from: store)
        let reopened = AppStore(persistence: PersistenceStore(directory: directory.appendingPathComponent(UUID().uuidString)),
                                paneFinalizer: nil)
        mirror = RemoteCatalogMirror(host: "box", store: reopened, effects: effects, viewState: saved)
        _ = mirror.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: Self.versions)))
        _ = mirror.receive(.snapshot(snapshot))
        return reopened
    }

    private func flagged() -> CatalogSession {
        var entry = session()
        entry.fields.flagged = true
        return entry
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

    @Test func aDetachedParentRespawnedOnTheServerStaysHiddenWithItsCompanionThroughEveryFrame() throws {
        let parent = session(), companion = session(parent: parent.id)
        open([parent, companion])
        mirror.detach(sessions: [parent.id])
        let added = effects.added
        let before = CatalogSnapshot(epoch: "e1", rev: 0, catalogID: catalogID, versions: Self.versions,
                                     workspaces: [CatalogWorkspace(id: workspaceID, name: "w", sessions: [parent, companion]),
                                                  CatalogWorkspace(id: otherWorkspaceID, name: "other", sessions: [])])
        var after = before
        var respawned = parent
        respawned.fields.cwd = "/home/agterm"
        after.workspaces[0].sessions[0] = respawned
        let changes = before.changes(to: after)
        try #require(!changes.isEmpty)

        var shownAfterFrame: [Set<UUID>] = []
        for (index, change) in changes.enumerated() {
            delta(index + 1, change)
            shownAfterFrame.append(rows)
        }
        after.rev = changes.count + 1
        _ = mirror.receive(.snapshot(after))
        shownAfterFrame.append(rows)

        #expect(shownAfterFrame == Array(repeating: [], count: changes.count + 1))
        #expect(effects.added == added)
        #expect(effects.needsAttach.isEmpty)
        #expect(mirror.detachedItems == [RemoteDetachedItem(kind: .session, id: parent.id, name: "s", ended: false)])
    }

    @Test func aDetachedSplitPromotedOnTheServerStaysHiddenThroughEveryFrame() {
        let left = CatalogPane(identity: UUID(), daemon: "agterm-\(UUID().uuidString)", endpoint: Self.endpoint)
        let right = CatalogPane(identity: UUID(), daemon: "agterm-\(UUID().uuidString)", endpoint: Self.endpoint)
        var entry = session()
        entry.fields.primary = left.identity
        entry.fields.axis = "vertical"
        entry.fields.shown = true
        entry.panes = [left, right]
        open([entry, session()])
        mirror.detach(sessions: [entry.id])
        let added = effects.added
        var promoted = entry.fields
        promoted.primary = right.identity
        promoted.axis = nil
        promoted.shown = false

        var hiddenAfterFrame: [Bool] = []
        delta(1, .paneRemoved(left.identity, session: entry.id))
        hiddenAfterFrame.append(!rows.contains(entry.id))
        delta(2, .sessionChanged(promoted))
        hiddenAfterFrame.append(!rows.contains(entry.id))

        #expect(hiddenAfterFrame == [true, true])
        #expect(effects.added == added)
        #expect(effects.needsAttach.isEmpty)
        #expect(mirror.detachedItems.map(\.id) == [entry.id])
    }

    @Test func aDetachedParentWhoseDaemonIsLostLeavesItsLiveCompanionHiddenUnderAnEndedItem() {
        let parent = session(), companion = session(parent: parent.id)
        open([parent, companion])
        mirror.detach(sessions: [parent.id])
        let added = effects.added

        var shownAfterFrame: [Set<UUID>] = []
        delta(1, .paneRemoved(parent.fields.primary, session: parent.id))
        shownAfterFrame.append(rows)
        delta(2, .sessionChanged(session(parent.id, ended: true).fields))
        shownAfterFrame.append(rows)

        #expect(shownAfterFrame == [[], []])
        #expect(effects.added == added)
        #expect(mirror.detachedItems == [RemoteDetachedItem(kind: .session, id: parent.id, name: "s", ended: true)])
        #expect(mirror.closeScope(session: parent.id)?.live == true)
    }

    @Test func aCompanionThatExitsUnderADetachedParentLeavesTheRestOfTheGroupHidden() {
        let parent = session(), exiting = session(parent: parent.id), staying = session(parent: parent.id)
        open([parent, exiting, staying, session()])
        mirror.detach(sessions: [parent.id])
        let added = effects.added

        delta(1, .sessionRemoved(exiting.id))

        #expect(rows.isDisjoint(with: [parent.id, exiting.id, staying.id]))
        #expect(rows.count == 1)
        #expect(effects.added == added)
        #expect(mirror.detachedItems.map(\.id) == [parent.id])
        #expect(mirror.closeScope(session: parent.id)?.sessions == [parent.id, staying.id])
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

    @Test func aReattachedRowKeepsItsBackgroundFoldAndContext() throws {
        let first = session()
        open([first, session()])
        let row = try #require(store.session(withID: first.id))
        let mark = BackgroundWatermark(kind: .text, text: "PROD"), left = BackgroundWatermark(kind: .text, text: "L")
        row.backgroundWatermark = mark
        row.paneBackgrounds = PaneBackgrounds(left: left)
        row.isExpanded = false
        row.context = "deploy"
        mirror.detach(sessions: [first.id])

        #expect(mirror.reattach(session: first.id) == nil)

        let back = try #require(store.session(withID: first.id))
        #expect(back.backgroundWatermark == mark)
        #expect(back.paneBackgrounds == PaneBackgrounds(left: left))
        #expect(!back.isExpanded)
        #expect(back.context == "deploy")
    }

    @Test func theServersFlagsCountTheRowsThisWindowDetached() {
        var shown = session(), plain = session(), parked = session()
        shown.fields.flagged = true
        plain.fields.flagged = false
        parked.fields.flagged = true
        let snapshot = CatalogSnapshot(epoch: "e1", rev: 0, catalogID: catalogID, versions: Self.versions,
                                       workspaces: [CatalogWorkspace(id: workspaceID, name: "w", tint: "", sessions: [shown, plain, parked])])
        _ = mirror.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: Self.versions)))
        _ = mirror.receive(.snapshot(snapshot))
        let actions = RemoteCatalogActions(mirror: mirror, runner: { _ in (0, "") })
        store.remoteActions = actions

        mirror.detach(sessions: [plain.id, parked.id])

        #expect(store.allSessionsFlagged(inWorkspace: workspaceID))
        #expect(!store.workspaceAllFlagged(workspaceID))
        #expect(store.flaggedSessions.count == 1)
        #expect(store.clearableFlagCount == 2)
        #expect(store.marksOnServer)
    }

    @Test func anOlderServersFlagsAreThisWindowsOwn() {
        open([session(), session()])
        let actions = RemoteCatalogActions(mirror: mirror, runner: { _ in (0, "") })
        store.remoteActions = actions
        for row in store.workspaces[0].sessions { store.setFlag(true, forSession: row.id) }

        #expect(!store.marksOnServer)
        #expect(store.workspaceAllFlagged(workspaceID))
        #expect(store.clearableFlagCount == 2)
    }

    @Test func aDetachedWorkspaceKeepsItsFocusMembershipThroughReopenAndReattach() {
        let snapshot = open([session()], other: [session()])
        store.restoreFocus(ids: [workspaceID, otherWorkspaceID], enabled: true)

        mirror.detach(workspace: otherWorkspaceID)
        let detached = (store.focusedWorkspaceIDs, store.focusEnabled)
        let reopened = reopen(snapshot)
        let afterReopen = (reopened.focusedWorkspaceIDs, reopened.focusEnabled)
        #expect(mirror.reattach(workspace: otherWorkspaceID) == nil)

        #expect(detached == ([workspaceID], true))
        #expect(afterReopen == ([workspaceID], true))
        #expect(reopened.focusedWorkspaceIDs == [workspaceID, otherWorkspaceID])
        #expect(reopened.focusEnabled)
    }

    @Test func detachingTheSoleFocusedWorkspaceTurnsTheFilterOffAndReattachKeepsItOff() {
        open([session()], other: [session()])
        store.restoreFocus(ids: [otherWorkspaceID], enabled: true)

        mirror.detach(workspace: otherWorkspaceID)
        let detached = (store.focusedWorkspaceIDs, store.focusEnabled)
        #expect(mirror.reattach(workspace: otherWorkspaceID) == nil)

        #expect(detached == ([], false))
        #expect(store.focusedWorkspaceIDs == [otherWorkspaceID])
        #expect(!store.focusEnabled)
    }

    @Test func aFilterTurnedOffWhileAMemberIsDetachedStaysOffOnReattach() {
        open([session()], other: [session()])
        store.restoreFocus(ids: [workspaceID, otherWorkspaceID], enabled: true)
        mirror.detach(workspace: otherWorkspaceID)

        store.setFocusEnabled(false)
        #expect(mirror.reattach(workspace: otherWorkspaceID) == nil)

        #expect(store.focusedWorkspaceIDs == [workspaceID, otherWorkspaceID])
        #expect(!store.focusEnabled)
    }

    @Test func aReattachedFlaggedRowReturnsToItsSlotAlsoAcrossReopen() {
        let first = flagged(), middle = flagged(), last = flagged()
        let snapshot = open([first, middle, last])
        let order = [first.fields.id, middle.fields.id, last.fields.id]

        mirror.detach(sessions: [middle.fields.id])
        let detached = store.orderedFlaggedSessions.map(\.id)
        #expect(mirror.reattach(session: middle.fields.id) == nil)
        let reattached = store.orderedFlaggedSessions.map(\.id)
        mirror.detach(sessions: [middle.fields.id])
        let reopened = reopen(snapshot)
        #expect(mirror.reattach(session: middle.fields.id) == nil)

        #expect(detached == [first.fields.id, last.fields.id])
        #expect(reattached == order)
        #expect(reopened.orderedFlaggedSessions.map(\.id) == order)
    }

    @Test func aSelectionOutsideTheRestoredFocusMovesIntoItOnReopen() {
        let inside = session(), outside = session()
        let snapshot = open([inside], other: [outside])
        store.restoreFocus(ids: [workspaceID], enabled: true)
        store.selectSession(inside.id)
        store.setFocusEnabled(false)
        store.selectSession(outside.id)
        let saved = RemoteWindowViewState.capture(from: store)
        let reopened = AppStore(persistence: PersistenceStore(directory: directory.appendingPathComponent("reopened")), paneFinalizer: nil)
        var view = saved
        view.workspaceFilter = true
        mirror = RemoteCatalogMirror(host: "box", store: reopened, effects: effects, viewState: view)

        _ = mirror.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: Self.versions)))
        _ = mirror.receive(.snapshot(snapshot))

        #expect(reopened.focusEnabled)
        #expect(reopened.selectedSessionID == inside.id)
    }

    @Test func flagAllCountsTheServersRowsThisWindowDetached() {
        let rows = [session(), session()]
        open(rows, tint: "")
        let actions = RemoteCatalogActions(mirror: mirror, runner: { _ in (0, "") })
        store.remoteActions = actions

        mirror.detach(sessions: rows.map(\.id))

        #expect(store.workspaces.first { $0.id == workspaceID }?.sessions.isEmpty == true)
        #expect(store.workspaceHasSessions(workspaceID))
        #expect(!store.workspaceHasSessions(otherWorkspaceID))
    }

    private func split(_ id: UUID, panes: [UUID]) -> CatalogSession {
        let catalogPanes = panes.map { CatalogPane(identity: $0, daemon: "agterm-\($0.uuidString)", endpoint: Self.endpoint) }
        return CatalogSession(fields: CatalogSessionFields(id: id, name: "s", parent: nil, cwd: "/srv", primary: panes[0],
                                                           axis: panes.count > 1 ? "vertical" : nil, shown: panes.count > 1,
                                                           lifecycle: .live),
                              panes: catalogPanes)
    }

    private func snapshot(_ sessions: [CatalogSession], rev: Int) -> CatalogSnapshot {
        CatalogSnapshot(epoch: "e1", rev: rev, catalogID: catalogID, versions: Self.versions,
                        workspaces: [CatalogWorkspace(id: workspaceID, name: "w", sessions: sessions),
                                     CatalogWorkspace(id: otherWorkspaceID, name: "other", sessions: [])])
    }

    @Test(arguments: ["swap", "promote", "replace"], [false, true])
    func eachPaneBackgroundFollowsItsTerminalThroughAServerChangeWhileDetached(_ change: String, _ reopened: Bool) throws {
        let id = UUID(), left = UUID(), right = UUID()
        let leftMark = BackgroundWatermark(kind: .text, text: "L"), rightMark = BackgroundWatermark(kind: .text, text: "R")
        let first = open([split(id, panes: [left, right]), session()])
        try #require(store.session(withID: id)).paneBackgrounds = PaneBackgrounds(left: leftMark, right: rightMark)
        mirror.detach(sessions: [id])
        let shown = reopened ? reopen(first) : store
        let panes = switch change {
        case "swap": [right, left]
        case "promote": [right]
        default: [left, UUID()]
        }

        _ = mirror.receive(.snapshot(snapshot([split(id, panes: panes), first.workspaces[0].sessions[1]], rev: 1)))
        #expect(mirror.reattach(session: id) == nil)

        let expected = switch change {
        case "swap": PaneBackgrounds(left: rightMark, right: leftMark)
        case "promote": PaneBackgrounds(left: rightMark)
        default: PaneBackgrounds(left: leftMark)
        }
        #expect(shown.session(withID: id)?.paneBackgrounds == expected)
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
