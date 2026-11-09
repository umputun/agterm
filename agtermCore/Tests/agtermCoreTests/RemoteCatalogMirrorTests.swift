import Foundation
import Testing
@testable import agtermCore

@MainActor
final class RemoteCatalogMirrorTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-mirror-\(UUID().uuidString)")
    private let store: AppStore
    private let effects = Effects()
    private let mirror: RemoteCatalogMirror
    private static let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")
    private static let versions = CatalogVersions(server: "1.2.3", protocolVersion: 1, catalog: 1)
    private let catalogID = UUID()
    private let workspaceID = UUID()
    private let finalized = Finalized()

    private let events = Events()

    final class Finalized: @unchecked Sendable {
        var ids: [UUID] = []
    }

    final class Events: @unchecked Sendable {
        var drafts: [ControlEventDraft] = []
    }

    init() {
        let finalized = finalized
        let events = events
        store = AppStore(persistence: PersistenceStore(directory: directory), controlEventSink: { events.drafts.append($0) },
                         paneFinalizer: { finalized.ids += $0 })
        mirror = RemoteCatalogMirror(host: "box", store: store, effects: effects, viewState: RemoteWindowViewState())
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private final class Effects: RemoteCatalogEffects {
        var added: [UUID] = []
        var removed: [UUID] = []
        var ended: [UUID] = []
        var needsAttach: [UUID] = []
        var states: [RemoteCatalogMirror.State] = []
        var bindOK = true

        func attachCommand(host: String, pane: CatalogPane) -> String { "attach \(host) \(pane.daemon)" }
        func catalogRowAdded(_ session: Session) { added.append(session.id) }
        func catalogRowRemoved(_ sessionID: UUID) { removed.append(sessionID) }
        func catalogRowEnded(_ sessionID: UUID) { ended.append(sessionID) }
        func catalogPaneNeedsAttach(_ identity: UUID, session _: UUID) { needsAttach.append(identity) }
        func catalogBound(_: UUID) -> Bool { bindOK }
        func catalogStateChanged(_ state: RemoteCatalogMirror.State) { states.append(state) }
    }

    private final class Surface: TerminalSurface {
        var isRealized = true
        var paneToken = UUID().uuidString
        var tornDown = false
        func teardown() { tornDown = true }
        func promoteToPrimaryPane() {}
    }

    private func pane(_ id: UUID = UUID()) -> CatalogPane {
        CatalogPane(identity: id, daemon: "agterm-\(id.uuidString)", endpoint: Self.endpoint)
    }

    private func session(_ id: UUID = UUID(), name: String = "s", panes: [CatalogPane], shown: Bool = true,
                         ended: Bool = false) -> CatalogSession {
        CatalogSession(fields: CatalogSessionFields(id: id, name: name, parent: nil, cwd: "/srv", primary: panes.first?.identity ?? UUID(),
                                                    axis: panes.count > 1 ? "vertical" : nil, shown: panes.count > 1 && shown,
                                                    lifecycle: ended ? .ended : .live),
                       panes: panes)
    }

    private func snapshot(_ sessions: [CatalogSession], epoch: String = "e1", rev: Int = 0) -> CatalogSnapshot {
        CatalogSnapshot(epoch: epoch, rev: rev, catalogID: catalogID, versions: Self.versions,
                        workspaces: [CatalogWorkspace(id: workspaceID, name: "w", sessions: sessions)])
    }

    private func open(_ sessions: [CatalogSession]) -> CatalogSnapshot {
        let first = snapshot(sessions)
        _ = mirror.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: Self.versions)))
        _ = mirror.receive(.snapshot(first))
        return first
    }

    private func delta(_ rev: Int, _ change: CatalogChange, epoch: String = "e1") {
        _ = mirror.receive(.delta(epoch: epoch, rev: rev, change: change))
    }

    @Test func theSnapshotBuildsEveryRowWithItsCatalogIdentitiesAndAttaches() throws {
        let left = pane(), right = pane()
        let split = session(name: "build", panes: [left, right])
        let single = session(panes: [pane()])

        _ = open([split, single])

        let row = try #require(store.session(withID: split.id))
        #expect(store.workspaces.map(\.id) == [workspaceID])
        #expect(store.workspaces[0].sessions.map(\.id) == [split.id, single.id])
        #expect(row.paneIdentity == left.identity)
        #expect(row.splitPaneIdentity == right.identity)
        #expect(row.hasSplit && row.isSplit)
        #expect(row.initialCommand == "attach box \(left.daemon)")
        #expect(row.splitInitialCommand == "attach box \(right.daemon)")
        #expect(row.commandWait && row.splitCommandWait)
        #expect(row.remoteHost == "box")
        #expect(row.customName == "build")
        #expect(row.remotePresentation?.binding.catalogOwned == true)
        #expect(row.remotePresentation?.binding.originHeadless == true)
        #expect(effects.added == [split.id, single.id])
        #expect(mirror.state == .connected)
    }

    @Test func aCatalogRowReportsItsServerSessionIDFromCreation() throws {
        let entry = session(panes: [pane()])
        _ = open([entry])

        let node = try #require(store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == entry.id.uuidString })
        #expect(node.remoteHost == "box")
        #expect(node.remoteSessionID == entry.id.uuidString)
        delta(1, .sessionRemoved(entry.id))

        let edges = events.drafts.filter { $0.kind == .remoteOpened || $0.kind == .remoteClosed }
        #expect(edges.map(\.kind) == [.remoteOpened, .remoteClosed])
        #expect(edges.allSatisfy { $0.session == entry.id.uuidString && $0.payload.remoteSessionID == entry.id.uuidString })
    }

    @Test func aRemovedSessionLosesItsRowAndAnAddedOneGainsOne() {
        let first = session(panes: [pane()])
        let second = session(panes: [pane()])
        _ = open([first])

        delta(1, .sessionAdded(second, workspace: workspaceID, index: 0))
        delta(2, .sessionRemoved(first.id))

        #expect(store.workspaces[0].sessions.map(\.id) == [second.id])
        #expect(effects.removed == [first.id])
    }

    @Test func aRenameAndAReorderMoveTheRowsInPlace() throws {
        let first = session(name: "a", panes: [pane()])
        let second = session(name: "b", panes: [pane()])
        _ = open([first, second])
        let row = try #require(store.session(withID: first.id))
        var renamed = first.fields
        renamed.name = "renamed"

        delta(1, .sessionChanged(renamed))
        delta(2, .sessionOrder([second.id, first.id], workspace: workspaceID))

        #expect(store.workspaces[0].sessions.map(\.id) == [second.id, first.id])
        #expect(store.session(withID: first.id) === row)
        #expect(row.customName == "renamed")
    }

    @Test func aLostDaemonKeepsTheRowAndItsScreenAndMarksItEnded() throws {
        let only = pane()
        let entry = session(panes: [only])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        let surface = Surface()
        row.surface = surface
        var ended = entry.fields
        ended.lifecycle = .ended

        delta(1, .paneRemoved(only.identity, session: entry.id))
        let afterRemoval = (row.ended, store.session(withID: entry.id) != nil)
        delta(2, .sessionChanged(ended))

        #expect(afterRemoval == (false, true))
        #expect(store.session(withID: entry.id) === row)
        #expect(row.ended)
        #expect(row.surface === surface)
        #expect(!surface.tornDown)
        #expect(effects.removed.isEmpty)
    }

    @Test func anEndedSessionThisMacNeverShowedGetsTheEndedLineInsteadOfAShell() throws {
        let entry = session(panes: [], ended: true)

        _ = open([entry])

        let row = try #require(store.session(withID: entry.id))
        #expect(row.ended)
        #expect(row.initialCommand == RemoteSession.endedCommand(host: "box"))
        #expect(row.initialCommand?.contains("Ended on") == true)
        #expect(row.commandWait)
        #expect(effects.added.isEmpty)
        #expect(row.remoteRowNotice == "Ended on box")
    }

    @Test func aSplitRowEndingBeforeEitherAttachStartedRunsTheEndedLineInBothPanes() throws {
        let entry = session(panes: [pane(), pane()])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        var ended = entry.fields
        ended.lifecycle = .ended

        delta(1, .sessionChanged(ended))

        #expect(row.ended)
        #expect(row.initialCommand == RemoteSession.endedCommand(host: "box"))
        #expect(row.splitInitialCommand == RemoteSession.endedCommand(host: "box"))
        #expect(effects.ended == [entry.id])
    }

    @Test func anEndingRowWithdrawsWhatItsStreamShowedAndKeepsItsTerminal() throws {
        let entry = session(panes: [pane()])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        let surface = Surface()
        row.surface = surface
        store.applyRemoteInfo(PresentationInfo(source: "3 agents", markdown: false, hideAfter: 0), forSession: entry.id)
        store.applyRemoteContext("deploying", forSession: entry.id)
        var ended = entry.fields
        ended.lifecycle = .ended

        delta(1, .sessionChanged(ended))

        #expect(row.effectiveInfo == nil)
        #expect(row.effectiveContext == nil)
        #expect(row.surface === surface)
        #expect(!surface.tornDown)
    }

    @Test func anEndingRowKeepsTheCommandsOfPanesAlreadyRunning() throws {
        let left = pane(), right = pane()
        let entry = session(panes: [left, right])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        row.surface = Surface()
        var ended = entry.fields
        ended.lifecycle = .ended

        delta(1, .sessionChanged(ended))

        #expect(row.initialCommand == "attach box \(left.daemon)")
        #expect(row.splitInitialCommand == RemoteSession.endedCommand(host: "box"))
    }

    @Test func aPaneTheCatalogDropsGivesItsChannelBack() async {
        let pool = SshConnectionPool(host: "box", root: "/tmp/agterm-ssh-501", key: "w") { _ in 0 }
        let pooled = RemoteCatalogMirror(host: "box", store: store, effects: effects, viewState: RemoteWindowViewState(),
                                         pool: pool)
        let kept = session(panes: [pane()])
        let dropped = session(panes: [pane()])
        for entry in [kept, dropped] { pool.lease("pane:\(entry.panes[0].identity)") }
        _ = pooled.receive(.snapshot(snapshot([kept, dropped])))

        _ = pooled.receive(.delta(epoch: "e1", rev: 1, change: .sessionRemoved(dropped.id)))

        #expect(pool.load == [1])
        #expect(pool.lease("pane:\(kept.panes[0].identity)") == pool.lease("pane:\(UUID())"))
    }

    @Test func theStoreCarriesTheConnectionTheWindowShows() {
        let initial = store.catalogState

        _ = open([])
        let connected = store.catalogState
        mirror.connectionLost("exit 255")

        #expect(initial == .connecting)
        #expect(connected == .connected)
        #expect(store.catalogState == .disconnected("exit 255"))
    }

    @Test func aKilledPrimaryPromotesASplitWhoseAttachHasNotStarted() throws {
        let left = pane(), right = pane()
        let entry = session(panes: [left, right])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        let primary = Surface()
        row.surface = primary
        var promoted = entry.fields
        promoted.primary = right.identity
        promoted.axis = nil
        promoted.shown = false

        delta(1, .paneRemoved(left.identity, session: entry.id))
        delta(2, .sessionChanged(promoted))

        #expect(store.session(withID: entry.id) === row)
        #expect(row.paneIdentity == right.identity)
        #expect(!row.hasSplit)
        #expect(row.initialCommand == "attach box \(right.daemon)")
        #expect(primary.tornDown)
        #expect(effects.needsAttach == [right.identity])
    }

    @Test func aSwapTheServerMadeSwapsTheSlotsEvenWhileAnAttachIsStarting() throws {
        let left = pane(), right = pane()
        let entry = session(panes: [left, right])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        var swapped = entry.fields
        swapped.primary = right.identity

        delta(1, .sessionChanged(swapped))

        #expect(row.paneIdentity == right.identity)
        #expect(row.splitPaneIdentity == left.identity)
        #expect(row.initialCommand == "attach box \(right.daemon)")
        #expect(row.splitInitialCommand == "attach box \(left.daemon)")
    }

    @Test func aSplitAddedAndClosedOnTheServerOpensAndClosesHere() throws {
        let left = pane(), right = pane()
        let entry = session(panes: [left])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        var withSplit = entry.fields
        withSplit.axis = "horizontal"
        withSplit.shown = true

        delta(1, .paneAdded(right, session: entry.id))
        delta(2, .sessionChanged(withSplit))
        let opened = (row.hasSplit, row.isSplit, row.splitPaneIdentity, row.splitAxis)
        delta(3, .paneRemoved(right.identity, session: entry.id))
        delta(4, .sessionChanged(entry.fields))

        #expect(opened == (true, true, right.identity, .topBottom))
        #expect(!row.hasSplit)
        #expect(row.splitPaneIdentity == nil)
        #expect(row.paneIdentity == left.identity)
    }

    @Test func aSessionMovedOutOfARemovedWorkspaceKeepsItsRow() throws {
        let entry = session(panes: [pane()])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        let other = UUID()
        let next = CatalogSnapshot(epoch: "e1", rev: 1, catalogID: catalogID, versions: Self.versions,
                                   workspaces: [CatalogWorkspace(id: other, name: "ops", sessions: [entry])])

        _ = mirror.receive(.snapshot(next))

        #expect(store.workspaces.map(\.id) == [other])
        #expect(store.session(withID: entry.id) === row)
        #expect(effects.removed.isEmpty)
    }

    @Test func aSessionTheServerMovesIntoANewWorkspaceKeepsItsRowThroughEveryFrame() throws {
        let entry = session(panes: [pane()])
        let current = open([entry])
        let row = try #require(store.session(withID: entry.id))
        let surface = Surface()
        row.surface = surface
        let target = UUID()
        let next = CatalogSnapshot(epoch: "e1", rev: 0, catalogID: catalogID, versions: Self.versions,
                                   workspaces: [CatalogWorkspace(id: target, name: "ops", sessions: [entry])])

        let changes = current.changes(to: next)
        for (offset, change) in changes.enumerated() { delta(offset + 1, change) }

        #expect(changes.map(\.kind) == ["workspace.added", "session.moved", "workspace.removed"])
        #expect(store.workspaces.map(\.id) == [target])
        #expect(store.session(withID: entry.id) === row)
        #expect(row.surface === surface)
        #expect(!surface.tornDown)
        #expect(effects.removed.isEmpty)
    }

    @Test func removingAParentLeavesItsCompanionUntilItsOwnRemoval() throws {
        let parent = session(panes: [pane()])
        var companion = session(panes: [pane()])
        companion.fields.parent = parent.id
        _ = open([parent, companion])
        let child = try #require(store.session(withID: companion.id))
        let surface = Surface()
        child.surface = surface

        delta(1, .sessionRemoved(parent.id))
        let afterParent = (store.session(withID: companion.id) === child, surface.tornDown, effects.removed)
        delta(2, .sessionRemoved(companion.id))

        #expect(afterParent.0)
        #expect(!afterParent.1)
        #expect(afterParent.2 == [parent.id])
        #expect(effects.removed == [parent.id, companion.id])
        #expect(surface.tornDown)
    }

    @Test func anEndpointChangeReattachesARunningPaneAndRetargetsOneNotStarted() throws {
        let left = pane(), right = pane()
        let entry = session(panes: [left, right])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        row.surface = Surface()
        let moved = ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/run/new")

        delta(1, .paneChanged(CatalogPane(identity: left.identity, daemon: left.daemon, endpoint: moved), session: entry.id))
        delta(2, .paneChanged(CatalogPane(identity: right.identity, daemon: "agterm-renamed", endpoint: moved), session: entry.id))

        #expect(effects.needsAttach.contains(left.identity))
        #expect(!effects.needsAttach.contains(right.identity))
        #expect(row.splitInitialCommand == "attach box agterm-renamed")
        #expect(row.remotePresentation?.binding.origin?.endpoint == moved)
    }

    @Test func aFreshWindowSelectsItsFirstRow() {
        let first = session(panes: [pane()])
        _ = open([first, session(panes: [pane()])])

        #expect(store.selectedSessionID == first.id)
    }

    @Test func anEmptyCatalogSelectsItsFirstRowWhenOneArrivesAndKeepsIt() {
        let first = session(panes: [pane()])
        let second = session(panes: [pane()])
        _ = open([])

        delta(1, .sessionAdded(first, workspace: workspaceID, index: 0))
        let afterFirst = store.selectedSessionID
        delta(2, .sessionAdded(second, workspace: workspaceID, index: 0))

        #expect(afterFirst == first.id)
        #expect(store.selectedSessionID == first.id)
    }

    @Test func aSavedSelectionTheServerRemovedFallsBackToTheFirstRow() {
        let only = session(panes: [pane()])
        let viewed = RemoteCatalogMirror(host: "box", store: store, effects: effects,
                                         viewState: RemoteWindowViewState(selectedSessionID: UUID()))

        _ = viewed.receive(.snapshot(snapshot([only])))

        #expect(store.selectedSessionID == only.id)
    }

    @Test func aGapOrAnotherEpochAsksForASnapshotAndAppliesNothing() {
        let entry = session(panes: [pane()])
        _ = open([entry])

        delta(2, .sessionRemoved(entry.id))
        let afterGap = mirror.needsSnapshot
        mirror.subscribing()
        _ = mirror.receive(.snapshot(snapshot([entry])))
        delta(1, .sessionRemoved(entry.id), epoch: "e2")

        #expect(afterGap)
        #expect(mirror.needsSnapshot)
        #expect(store.session(withID: entry.id) != nil)
    }

    @Test func anUnknownChangeAdvancesTheCursorSoTheNextOneApplies() {
        let entry = session(panes: [pane()])
        _ = open([entry])

        _ = mirror.receive(.unknown(kind: "session.teleported", epoch: "e1", rev: 1))
        delta(2, .sessionRemoved(entry.id))

        #expect(!mirror.needsSnapshot)
        #expect(store.session(withID: entry.id) == nil)
    }

    @Test func aChunkedSnapshotAppliesOnlyAtItsCommit() throws {
        let entry = session(panes: [pane()])
        let data = try JSONEncoder().encode(snapshot([entry]))
        let half = data.count / 2

        _ = mirror.receive(.chunk(index: 0, data: data[..<half].base64EncodedString()))
        _ = mirror.receive(.chunk(index: 1, data: data[half...].base64EncodedString()))
        let beforeCommit = store.session(withID: entry.id)
        _ = mirror.receive(.commit(epoch: "e1", rev: 0, chunks: 2))

        #expect(beforeCommit == nil)
        #expect(store.session(withID: entry.id) != nil)
    }

    @Test func aPingIsAnsweredWithAnAck() {
        #expect(mirror.receive(.ping) == .ack)
    }

    @Test func anOriginWithoutACatalogVersionIsRefusedForGood() {
        let refused = mirror.checkVersions(nil, app: AppIdentity(version: "0.49.0"))
        _ = mirror.receive(.snapshot(snapshot([session(panes: [pane()])])))
        mirror.subscribing()

        #expect(!refused)
        #expect(mirror.state == .refused("box runs agterm 0.49.0 without a catalog, a Mac app rather than agterm-server; a remote window needs agterm-server"))
        #expect(store.workspaces.isEmpty)
    }

    @Test func aNewerCatalogVersionIsRefusedNamingBoth() {
        #expect(RemoteCatalogMirror.versionRefusal(host: "box", versions: CatalogVersions(server: "9", protocolVersion: 1, catalog: 2), app: nil)
            == "box speaks catalog 2, this Mac speaks catalog 1")
        #expect(RemoteCatalogMirror.versionRefusal(host: "box", versions: Self.versions, app: nil) == nil)
    }

    @Test func aCatalogAnotherWindowShowsStopsTheMirror() {
        effects.bindOK = false

        _ = open([session(panes: [pane()])])

        #expect(store.workspaces.isEmpty)
        if case .refused = mirror.state {} else { Issue.record("expected refused, got \(mirror.state)") }
    }

    @Test func aLostConnectionKeepsTheRowsAndShowsDisconnected() {
        let entry = session(panes: [pane()])
        _ = open([entry])

        mirror.connectionLost("ssh exited")

        #expect(mirror.state == .disconnected("ssh exited"))
        #expect(store.session(withID: entry.id) != nil)
    }

    @Test func presentationLayoutNeverMovesACatalogRow() throws {
        let left = pane(), right = pane()
        let entry = session(panes: [left, right])
        _ = open([entry])
        let row = try #require(store.session(withID: entry.id))
        let layout = PresentationLayout(panes: [right.identity], primary: right.identity, axis: nil, shown: false)

        let closable = store.applyRemoteLayout(layout, forSession: entry.id)

        #expect(closable.isEmpty)
        #expect(row.paneIdentity == left.identity)
        #expect(row.isSplit)
        #expect(!store.canCloseRemovedRemotePane(left.identity, forSession: entry.id))
    }

    @Test func savedViewStateIsAppliedToTheRowsItNames() throws {
        let left = pane(), right = pane()
        let entry = session(panes: [left, right])
        var view = RemoteWindowViewState(selectedSessionID: entry.id)
        view.sessions[entry.id] = .init(focusedPane: left.identity, fontSize: 15, splitRatio: 0.3)
        let viewed = RemoteCatalogMirror(host: "box", store: store, effects: effects, viewState: view)

        _ = viewed.receive(.snapshot(snapshot([entry])))

        let row = try #require(store.session(withID: entry.id))
        #expect(row.fontSize == 15)
        #expect(row.splitRatio == 0.3)
        #expect(!row.splitFocused)
        #expect(store.selectedSessionID == entry.id)
    }

    @Test func aCreatedRowIsSelectedWhenTheCatalogBringsIt() {
        let existing = session(panes: [pane()])
        _ = open([existing])
        store.selectSession(existing.id)
        let created = session(panes: [pane()])

        mirror.selectWhenShown(created.id, from: existing.id)
        let before = store.selectedSessionID
        delta(1, .sessionAdded(created, workspace: workspaceID, index: 1))

        #expect(before == existing.id)
        #expect(store.selectedSessionID == created.id)
    }

    @Test func aCreatedRowThatArrivedFirstIsSelectedWhenTheSelectionStayed() {
        let existing = session(panes: [pane()])
        _ = open([existing])
        store.selectSession(existing.id)
        let created = session(panes: [pane()])
        delta(1, .sessionAdded(created, workspace: workspaceID, index: 1))

        mirror.selectWhenShown(created.id, from: existing.id)

        #expect(store.selectedSessionID == created.id)
    }

    @Test func aCreatedRowThatArrivedFirstIsNotSelectedOnceTheUserMovedOn() {
        let existing = session(panes: [pane()])
        let other = session(panes: [pane()])
        _ = open([existing, other])
        store.selectSession(other.id)
        let created = session(panes: [pane()])
        delta(1, .sessionAdded(created, workspace: workspaceID, index: 2))

        mirror.selectWhenShown(created.id, from: existing.id)

        #expect(store.selectedSessionID == other.id)
    }

    @Test func aCreatedRowIsNotSelectedOnceTheUserMovedOn() throws {
        let existing = session(panes: [pane()])
        let other = session(panes: [pane()])
        _ = open([existing, other])
        store.selectSession(existing.id)
        let created = session(panes: [pane()])

        mirror.selectWhenShown(created.id, from: existing.id)
        store.selectSession(other.id)
        delta(1, .sessionAdded(created, workspace: workspaceID, index: 2))

        #expect(store.selectedSessionID == other.id)
    }

    private func scratchPane(_ id: UUID = UUID()) -> CatalogPane {
        CatalogPane(identity: id, daemon: ZmxSupport.scratchDaemonName(for: id), endpoint: Self.endpoint)
    }

    private func withScratch(_ entry: CatalogSession, _ scratch: CatalogPane?, shown: Bool = true, ended: Bool = false) -> CatalogSessionFields {
        var fields = entry.fields
        fields.scratch = scratch.map { CatalogScratch(pane: $0, shown: shown) }
        if ended { fields.lifecycle = .ended }
        return fields
    }

    @Test func aShownServerScratchAttachesItsDaemonOnTheRow() throws {
        let scratch = scratchPane()
        var entry = session(panes: [pane()])
        entry.fields = withScratch(entry, scratch)

        _ = open([entry])

        let row = try #require(store.session(withID: entry.id))
        #expect(row.scratchDaemon == Session.ScratchDaemon(identity: scratch.identity, shown: true))
        #expect(row.scratchActive)
        #expect(row.scratchCommand == "attach box \(scratch.daemon)")
        #expect(store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == entry.id.uuidString }?.scratchBacked == true)
    }

    @Test func aHiddenServerScratchKeepsItsSurfaceAndAGoneOneClosesIt() throws {
        let scratch = scratchPane()
        let entry = session(panes: [pane()])
        _ = open([entry])
        delta(1, .sessionChanged(withScratch(entry, scratch)))
        let row = try #require(store.session(withID: entry.id))
        let surface = Surface()
        row.scratchSurface = surface

        delta(2, .sessionChanged(withScratch(entry, scratch, shown: false)))

        #expect(!row.scratchActive)
        #expect(!surface.tornDown)
        #expect(row.scratchDaemon?.shown == false)

        delta(3, .sessionChanged(withScratch(entry, nil)))

        #expect(surface.tornDown)
        #expect(row.scratchSurface == nil)
        #expect(row.scratchDaemon == nil)
        #expect(store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == entry.id.uuidString }?.scratchBacked == nil)
    }

    @Test func aReplacedServerScratchClosesTheOldSurfaceAndAttachesTheNewDaemon() throws {
        let old = scratchPane(), new = scratchPane()
        let entry = session(panes: [pane()])
        _ = open([entry])
        delta(1, .sessionChanged(withScratch(entry, old)))
        let row = try #require(store.session(withID: entry.id))
        let surface = Surface()
        row.scratchSurface = surface
        row.scratchCommand = nil

        delta(2, .sessionChanged(withScratch(entry, new)))

        #expect(surface.tornDown)
        #expect(row.scratchActive)
        #expect(row.scratchCommand == "attach box \(new.daemon)")
        #expect(row.scratchDaemon?.identity == new.identity)
    }

    @Test func anEndedRowKeepsItsPresentationWhileItsScratchRuns() throws {
        let scratch = scratchPane()
        let entry = session(panes: [pane()])
        _ = open([entry])
        delta(1, .sessionChanged(withScratch(entry, scratch)))

        delta(2, .sessionChanged(withScratch(entry, scratch, ended: true)))

        #expect(store.session(withID: entry.id)?.ended == true)
        #expect(effects.ended.isEmpty)

        delta(3, .sessionChanged(withScratch(entry, nil, ended: true)))

        #expect(effects.ended == [entry.id])
    }

    @Test func anEndedRowWithAScratchStartsItsPresentationWhenItArrives() {
        var entry = session(panes: [], ended: true)
        entry.fields = withScratch(entry, scratchPane(), ended: true)

        _ = open([entry])

        #expect(effects.added == [entry.id])
    }

    @Test(arguments: [true, false])
    func aServerScratchStatusLandsOnTheScratch(byIdentity: Bool) throws {
        let scratch = scratchPane()
        var entry = session(panes: [pane()])
        entry.fields = withScratch(entry, scratch)
        _ = open([entry])
        let pane: PresentationPane = byIdentity ? .identity(scratch.identity) : .scratch

        store.applyRemoteStatus(PresentationStatus(status: .blocked, blink: false, color: nil, shape: nil, pane: pane, changedAt: nil),
                                forSession: entry.id)

        let row = try #require(store.session(withID: entry.id))
        #expect(row.agentIndicator.statusPane == .scratch)
        #expect(row.remotePresentation?.statusOwnerResolved == true)
    }

    @Test func closingARowNeverEndsItsServerScratchHere() throws {
        let scratch = scratchPane()
        var entry = session(panes: [pane()])
        entry.fields = withScratch(entry, scratch)
        _ = open([entry])

        store.closeSession(entry.id)

        #expect(!finalized.ids.contains(scratch.identity))
    }

    @Test func anEndedRowKeepsItsScratchStatusAndLosesItWithTheScratch() throws {
        let scratch = scratchPane()
        let entry = session(panes: [pane()])
        _ = open([entry])
        delta(1, .sessionChanged(withScratch(entry, scratch)))
        store.applyRemoteStatus(PresentationStatus(status: .blocked, blink: false, color: nil, shape: nil, pane: .scratch, changedAt: nil),
                                forSession: entry.id)
        let row = try #require(store.session(withID: entry.id))

        delta(2, .sessionChanged(withScratch(entry, scratch, ended: true)))

        #expect(row.agentIndicator.status == .blocked)

        delta(3, .sessionChanged(withScratch(entry, nil, ended: true)))

        #expect(row.agentIndicator.status == .idle)
        #expect(effects.ended == [entry.id])
    }

    @Test func aStoppedScratchAttachKeepsItsScreenAndStatusAndIsReplacedOnce() throws {
        let scratch = scratchPane()
        let entry = session(panes: [pane()])
        _ = open([entry])
        delta(1, .sessionChanged(withScratch(entry, scratch)))
        let row = try #require(store.session(withID: entry.id))
        let stopped = Surface()
        row.scratchSurface = stopped
        row.scratchCommand = nil
        store.applyRemoteStatus(PresentationStatus(status: .blocked, blink: false, color: nil, shape: nil, pane: .scratch, changedAt: nil),
                                forSession: entry.id)
        let generation = row.scratchGeneration

        #expect(mirror.scratchAttachmentStopped(of: entry.id) == scratch.identity)
        #expect(!stopped.tornDown)
        #expect(row.scratchActive)

        #expect(mirror.replaceScratchAttachment(of: entry.id, identity: scratch.identity))

        #expect(stopped.tornDown)
        #expect(row.scratchSurface == nil)
        #expect(row.scratchActive)
        #expect(row.scratchCommand == "attach box \(scratch.daemon)")
        #expect(row.scratchGeneration == generation + 1)
        #expect(row.agentIndicator.status == .blocked)
        #expect(!mirror.replaceScratchAttachment(of: entry.id, identity: scratch.identity))

        delta(2, .sessionChanged(withScratch(entry, nil)))

        #expect(!row.scratchActive)
        #expect(row.scratchDaemon == nil)
        #expect(row.agentIndicator.status == .idle)
    }

    @Test func aHiddenStoppedScratchIsReplacedHiddenAndAttachesWhenShown() throws {
        let scratch = scratchPane()
        let entry = session(panes: [pane()])
        _ = open([entry])
        delta(1, .sessionChanged(withScratch(entry, scratch, shown: false)))
        let row = try #require(store.session(withID: entry.id))
        row.scratchSurface = Surface()

        _ = mirror.scratchAttachmentStopped(of: entry.id)
        #expect(mirror.replaceScratchAttachment(of: entry.id, identity: scratch.identity))
        #expect(!row.scratchActive)

        delta(2, .sessionChanged(withScratch(entry, scratch)))

        #expect(row.scratchActive)
        #expect(row.scratchCommand == "attach box \(scratch.daemon)")
    }

    @Test func aStoppedScratchIsNotReplacedOnceItsScratchChangedOrClosed() throws {
        let old = scratchPane(), new = scratchPane()
        let entry = session(panes: [pane()])
        _ = open([entry])
        delta(1, .sessionChanged(withScratch(entry, old)))
        let row = try #require(store.session(withID: entry.id))
        row.scratchSurface = Surface()
        _ = mirror.scratchAttachmentStopped(of: entry.id)

        store.closeScratch(row.id)

        #expect(!mirror.replaceScratchAttachment(of: entry.id, identity: old.identity))

        row.scratchSurface = Surface()
        _ = mirror.scratchAttachmentStopped(of: entry.id)
        delta(2, .sessionChanged(withScratch(entry, new)))

        #expect(!mirror.replaceScratchAttachment(of: entry.id, identity: old.identity))
        #expect(mirror.scratchAttachmentStopped(of: UUID()) == nil)
    }
}
