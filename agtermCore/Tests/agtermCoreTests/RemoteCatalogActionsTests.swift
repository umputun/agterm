import Foundation
import Testing
@testable import agtermCore

@MainActor
final class RemoteCatalogActionsTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-actions-\(UUID().uuidString)")
    private let store: AppStore
    private let effects = Effects()
    private let mirror: RemoteCatalogMirror
    private let script = Script()
    private var actions: RemoteCatalogActions!
    private static let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")
    private static let versions = CatalogVersions(server: "1.2.3", protocolVersion: 1, catalog: 1)
    private let catalogID = UUID()
    private let workspaceID = UUID()
    private let sessionID = UUID()
    private let panes = [UUID(), UUID()]

    init() {
        store = AppStore(persistence: PersistenceStore(directory: directory), paneFinalizer: nil)
        mirror = RemoteCatalogMirror(host: "box", store: store, effects: effects, viewState: RemoteWindowViewState())
        let script = script
        actions = RemoteCatalogActions(mirror: mirror, runner: { argv in await script.answer(argv) })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private final class Effects: RemoteCatalogEffects {
        func attachCommand(host: String, pane: CatalogPane) -> String { "attach \(host) \(pane.daemon)" }
        func catalogRowAdded(_: Session) {}
        func catalogRowRemoved(_: UUID) {}
        func catalogRowEnded(_: UUID) {}
        func catalogPaneNeedsAttach(_: UUID, session _: UUID) {}
        func catalogBound(_: UUID) -> Bool { true }
        func catalogStateChanged(_: RemoteCatalogMirror.State) {}
    }

    @MainActor
    private final class Script {
        var commands: [(String) -> String] = []
        var lookups: [(String) -> String] = []
        var calls: [[String]] = []
        var lookupGate: CheckedContinuation<Void, Never>?
        var gateNextLookup = false

        func answer(_ argv: [String]) async -> (status: Int32, stdout: String) {
            calls.append(argv)
            let line = Self.plain(argv)
            let opID = Self.opID(line)
            guard line.contains(" catalog op ") else { return (0, commands.isEmpty ? "" : commands.removeFirst()(opID)) }
            if gateNextLookup {
                gateNextLookup = false
                await withCheckedContinuation { lookupGate = $0 }
            }
            return (0, lookups.isEmpty ? "" : lookups.removeFirst()(opID))
        }

        func openGate() {
            lookupGate?.resume()
            lookupGate = nil
        }

        static func plain(_ argv: [String]) -> String {
            (argv.last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
        }

        static func opID(_ line: String) -> String {
            let marker = line.range(of: "--op-id ") ?? line.range(of: " catalog op ")
            return marker.map { String(line[$0.upperBound...].prefix(36)) } ?? ""
        }

        var lookupCalls: [String] { calls.map(Self.plain).filter { $0.contains(" catalog op ") } }
        var commandCalls: [String] { calls.map(Self.plain).filter { !$0.contains(" catalog op ") } }
    }

    private func reply(_ outcome: CatalogReceipt.Outcome, epoch: String = "e1", rev: Int? = nil, ok: Bool = true,
                       id: String? = nil) -> (String) -> String {
        { opID in
            var result = ControlResult()
            result.receipt = CatalogReceipt(opID: opID, epoch: epoch, outcome: outcome, rev: rev,
                                            error: outcome == .refused ? "refused here" : nil)
            result.id = id
            let response = ControlResponse(ok: ok && (outcome == .applied || outcome == .noop), result: result,
                                           error: outcome == .refused ? "refused here" : nil)
            return String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self)
        }
    }

    private func queue(_ build: @escaping (String) -> String, before: (() -> Void)? = nil) {
        script.commands.append { opID in
            before?()
            return build(opID)
        }
    }

    private func queueLookup(_ build: @escaping (String) -> String) {
        script.lookups.append(build)
    }

    private func session(_ id: UUID, panes: [UUID]) -> CatalogSession {
        let catalogPanes = panes.map { CatalogPane(identity: $0, daemon: "agterm-\($0.uuidString)", endpoint: Self.endpoint) }
        return CatalogSession(fields: CatalogSessionFields(id: id, name: "s", parent: nil, cwd: "/srv", primary: panes.first ?? UUID(),
                                                           axis: panes.count > 1 ? "vertical" : nil, shown: panes.count > 1,
                                                           lifecycle: panes.isEmpty ? .ended : .live),
                              panes: catalogPanes)
    }

    private func snapshot(epoch: String = "e1", rev: Int = 0, sessions: [CatalogSession]? = nil) -> CatalogSnapshot {
        CatalogSnapshot(epoch: epoch, rev: rev, catalogID: catalogID, versions: Self.versions,
                        workspaces: [CatalogWorkspace(id: workspaceID, name: "w", sessions: sessions ?? [session(sessionID, panes: panes)])])
    }

    private func install(_ snapshot: CatalogSnapshot) {
        _ = mirror.receive(.hello(CatalogHello(version: 1, epoch: snapshot.epoch, versions: Self.versions)))
        _ = mirror.receive(.snapshot(snapshot))
    }

    private func advance(to rev: Int, epoch: String = "e1") {
        _ = mirror.receive(.unknown(kind: "future", epoch: epoch, rev: rev))
    }

    private func settleLookups() async {
        await actions.lookupTask?.value
    }

    private var rename: RemoteOperation { .renameSession(sessionID, name: "build") }

    private func send(_ operation: RemoteOperation) async -> ControlResponse {
        switch actions.prepare(operation) {
        case .ready(let prepared): await actions.send(prepared)
        case .refused(let refusal): refusal
        }
    }

    @Test func anAppliedOperationStaysPendingUntilTheMirrorReachesItsRevision() async {
        install(snapshot())
        queue(reply(.applied, rev: 2))

        let response = await send(rename)
        let pending = actions.marks
        advance(to: 1)
        let afterUnrelated = actions.marks
        advance(to: 2)

        #expect(response.ok)
        #expect(pending.map(\.unknown) == [false])
        #expect(pending.first?.target == .session(sessionID))
        #expect(afterUnrelated.count == 1)
        #expect(actions.marks.isEmpty)
    }

    @Test func aDeltaThatArrivedBeforeTheReplyClearsItAtOnce() async {
        install(snapshot())
        queue(reply(.applied, rev: 1)) { [weak self] in self?.advance(to: 1) }

        _ = await send(rename)

        #expect(actions.marks.isEmpty)
    }

    @Test(arguments: [CatalogReceipt.Outcome.noop, .refused, .fenced])
    func anOperationThatChangedNothingClearsAtOnce(_ outcome: CatalogReceipt.Outcome) async {
        install(snapshot())
        queue(reply(outcome))

        let response = await send(rename)

        #expect(response.ok == (outcome == .noop))
        #expect(actions.marks.isEmpty)
    }

    @Test func theSameActionOnTheSameRowIsHeldWhilePending() async {
        install(snapshot())
        queue(reply(.applied, rev: 5))
        queue(reply(.noop))
        _ = await send(rename)

        let repeated = await send(rename)
        let other = await send(.swap(sessionID))

        #expect(repeated.error == "Rename Session is still pending on box")
        #expect(other.ok)
        #expect(script.commandCalls.count == 2)
    }

    @Test func aLostReplyIsSettledByALookupWhereItWasSent() async {
        install(snapshot(rev: 3))
        queue({ _ in "" })
        queueLookup(reply(.applied, rev: 3))

        let response = await send(rename)
        let marked = actions.marks
        await settleLookups()

        #expect(!response.ok)
        #expect(marked.map(\.unknown) == [true])
        #expect(script.lookupCalls.count == 1)
        #expect(script.lookupCalls.first?.contains("--epoch e1 --rev 3 --json") == true)
        #expect(actions.marks.isEmpty)
    }

    @Test func aReplyLostWhileALookupRunsIsAskedAboutInTheSameRun() async {
        install(snapshot())
        queue({ _ in "" })
        queue({ _ in "" })
        queueLookup(reply(.fenced))
        queueLookup(reply(.fenced))
        script.gateNextLookup = true
        _ = await send(rename)
        while script.lookupGate == nil { await Task.yield() }

        _ = await send(.swap(sessionID))
        script.openGate()
        await settleLookups()

        #expect(script.lookupCalls.count == 2)
        #expect(actions.marks.isEmpty)
    }

    @Test func aSnapshotArrivingDuringAFailingLookupAsksAgainAfterIt() async {
        install(snapshot())
        queue({ _ in "" })
        queueLookup({ _ in "" })
        queueLookup(reply(.fenced))
        script.gateNextLookup = true
        _ = await send(rename)
        while script.lookupGate == nil { await Task.yield() }

        install(snapshot())
        script.openGate()
        await settleLookups()

        #expect(script.lookupCalls.count == 2)
        #expect(actions.marks.isEmpty)
    }

    @Test func aLookupThatFailsIsNotRetriedUntilTheNextSnapshot() async {
        install(snapshot())
        queue({ _ in "" })
        queueLookup({ _ in "" })

        _ = await send(rename)
        await settleLookups()
        advance(to: 1)
        await settleLookups()

        #expect(script.lookupCalls.count == 1)
        #expect(actions.marks.map(\.unknown) == [true])
    }

    @Test func anUnchangedSnapshotSettlesNothingAndTheLookupFencesTheDelayedCommand() async {
        install(snapshot())
        queue({ _ in "" })
        queueLookup({ _ in "" })
        _ = await send(rename)
        await settleLookups()

        install(snapshot())
        let afterSnapshot = actions.marks
        queueLookup(reply(.fenced))
        await settleLookups()
        install(snapshot())
        await settleLookups()

        #expect(afterSnapshot.map(\.unknown) == [true])
        #expect(actions.marks.isEmpty)
    }

    @Test func aCreateThatCommittedAndLostItsReplyIsAppliedByALookupAfterARestart() async {
        install(snapshot())
        queue({ _ in "" })
        queueLookup({ _ in "" })
        _ = await send(.newWorkspace(name: "dev"))
        await settleLookups()
        queueLookup(reply(.applied, epoch: "e2", rev: 4))

        install(snapshot(epoch: "e2", rev: 4))
        await settleLookups()

        #expect(script.lookupCalls.count == 2)
        #expect(actions.marks.isEmpty)
    }

    @Test func aCommandDelayedAcrossARestartIsRefusedAndClears() async {
        install(snapshot())
        queue(reply(.refused))

        let response = await send(rename)

        #expect(response.error == "refused here")
        #expect(actions.marks.isEmpty)
    }

    @Test func aReceiptFromANewerEpochWaitsForTheMirrorToReachIt() async {
        install(snapshot())
        queue(reply(.applied, epoch: "e2", rev: 4))
        _ = await send(rename)
        let waiting = actions.marks

        install(snapshot(epoch: "e2", rev: 4))

        #expect(waiting.map(\.unknown) == [false])
        #expect(actions.marks.isEmpty)
        #expect(script.lookupCalls.isEmpty)
    }

    @Test func anOldEpochReplyAfterTheNewEpochArrivedIsLookedUp() async {
        install(snapshot())
        queue(reply(.applied, epoch: "e1", rev: 1)) { [weak self] in
            guard let self else { return }
            install(snapshot(epoch: "e2", rev: 0))
        }
        queueLookup(reply(.applied, epoch: "e2", rev: 0))

        _ = await send(rename)
        await settleLookups()

        #expect(script.lookupCalls.count == 1)
        #expect(actions.marks.isEmpty)
    }

    @Test func aNewEpochArrivingBeforeTheRevisionSendsTheWaitingReceiptToALookup() async {
        install(snapshot())
        queue(reply(.applied, epoch: "e1", rev: 5))
        _ = await send(rename)
        queueLookup(reply(.applied, epoch: "e2", rev: 0))

        install(snapshot(epoch: "e2", rev: 0))
        await settleLookups()

        #expect(script.lookupCalls.count == 1)
        #expect(actions.marks.isEmpty)
    }

    @Test func anUnknownOutcomeStaysUntilDismissed() async {
        install(snapshot())
        queue({ _ in "" })
        queueLookup(reply(.unknown))
        _ = await send(rename)
        await settleLookups()
        advance(to: 1)
        install(snapshot(rev: 1))
        await settleLookups()
        let kept = actions.marks

        actions.dismissUnknown()

        #expect(kept.map(\.unknown) == [true])
        #expect(script.lookupCalls.count == 1)
        #expect(actions.marks.isEmpty)
    }

    @Test func anUnknownOutcomeGoesWithItsRow() async {
        install(snapshot())
        queue({ _ in "" })
        queueLookup(reply(.unknown))
        _ = await send(rename)
        await settleLookups()

        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionRemoved(sessionID)))

        #expect(actions.marks.isEmpty)
    }

    @Test func nothingIsSentWhileTheWindowIsNotConnected() async {
        let response = await send(rename)

        #expect(response.error == "box is not connected")
        #expect(script.calls.isEmpty)
        #expect(actions.marks.isEmpty)
    }

    @Test func aPaneActionPinsThePanesTheWindowSaw() async {
        install(snapshot())
        queue(reply(.noop))

        _ = await send(.swap(sessionID))

        let line = script.commandCalls.first ?? ""
        #expect(line.contains("--expect-panes \(panes[0].uuidString),\(panes[1].uuidString) --op-id"))
    }

    @Test func aPaneActionKeepsThePanesSeenWhenItWasDecided() async throws {
        install(snapshot())
        queue(reply(.refused))
        guard case .ready(let prepared) = actions.prepare(.swap(sessionID)) else { Issue.record("not prepared"); return }
        let replacement = CatalogPane(identity: UUID(), daemon: "agterm-new", endpoint: Self.endpoint)
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .paneRemoved(panes[1], session: sessionID)))
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .paneAdded(replacement, session: sessionID)))

        _ = await actions.send(prepared)

        let line = script.commandCalls.first ?? ""
        #expect(line.contains("--expect-panes \(panes[0].uuidString),\(panes[1].uuidString) --op-id"))
        #expect(!line.contains(replacement.identity.uuidString))
    }

    @Test func aPaneActionOnAnEndedRowIsRefusedHere() async {
        install(snapshot(sessions: [session(sessionID, panes: [])]))

        let response = await send(.closeSplit(sessionID))

        #expect(response.error == "the session has ended on box")
        #expect(script.calls.isEmpty)
    }

    @Test func aCreatedRowIsNotSelectedWhenTheUserMovedDuringTheSend() async throws {
        let other = UUID()
        install(snapshot(sessions: [session(sessionID, panes: panes), session(other, panes: [UUID()])]))
        store.selectSession(sessionID)
        let created = UUID()
        queue(reply(.applied, rev: 1, id: created.uuidString)) { [weak self] in self?.store.selectSession(other) }
        guard case .ready(let prepared) = actions.prepare(.newSession(workspace: workspaceID)) else {
            Issue.record("not prepared")
            return
        }

        _ = await actions.send(prepared, selectingCreated: true)
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(session(created, panes: [UUID()]), workspace: workspaceID, index: 2)))

        #expect(store.selectedSessionID == other)
    }

    @Test func aCreatedRowIsSelectedWhenTheSelectionStayed() async {
        install(snapshot())
        store.selectSession(sessionID)
        let created = UUID()
        queue(reply(.applied, rev: 1, id: created.uuidString))
        guard case .ready(let prepared) = actions.prepare(.newSession(workspace: workspaceID)) else {
            Issue.record("not prepared")
            return
        }

        _ = await actions.send(prepared, selectingCreated: true)
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(session(created, panes: [UUID()]), workspace: workspaceID, index: 1)))

        #expect(store.selectedSessionID == created)
    }

    @Test func aRowReadsBackPendingThenUnknownAndTheWindowListsBoth() async {
        install(snapshot())
        queue(reply(.applied, rev: 3))
        queue({ _ in "" })
        queueLookup(reply(.unknown))

        _ = await send(rename)
        let pending = (actions.pendingState(of: sessionID), actions.marks.count, actions.unknownCount)
        _ = await send(.swap(sessionID))
        await settleLookups()

        #expect(pending == ("pending", 1, 0))
        #expect(actions.pendingState(of: sessionID) == "unknown")
        #expect(actions.marks.count == 2)
        #expect(actions.unknownCount == 1)
        #expect(actions.pendingState(of: UUID()) == nil)
    }

    @Test func theRemoteNodeListsWorkspaceAndTargetlessOperations() async throws {
        install(snapshot())
        queue(reply(.applied, rev: 4))
        queue(reply(.applied, rev: 5))
        _ = await send(.renameWorkspace(workspaceID, name: "ops"))
        _ = await send(.newWorkspace(name: "dev"))

        let node = ControlRemoteWindow(host: "box", catalogID: nil, state: .connected, operations: actions.marks)
        let operations = try #require(node.operations)

        #expect(operations.map(\.action) == ["Rename Workspace", "New Workspace"])
        #expect(operations.map(\.workspace) == [workspaceID.uuidString, nil])
        #expect(operations.allSatisfy { $0.session == nil && $0.state == "pending" })
    }

    @Test func aDetachedRowThatEndedIsRefusedReattachAndRemovedByClose() async throws {
        let other = UUID()
        install(snapshot(sessions: [session(sessionID, panes: panes), session(other, panes: [UUID()])]))
        store.remoteActions = actions
        mirror.detach(sessions: [sessionID])
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionChanged(session(sessionID, panes: []).fields)))
        let refusal = mirror.reattach(session: sessionID)
        let rename = RemoteOperation.parse(ControlRequest(cmd: .sessionRename, target: sessionID.uuidString,
                                                          args: ControlArgs(name: "x")), in: store)
        let close = RemoteOperation.parse(ControlRequest(cmd: .sessionClose, target: String(sessionID.uuidString.prefix(8))), in: store)
        queue(reply(.applied, rev: 2))

        guard case .operation(let operation, _) = close else { Issue.record("close did not resolve the hidden row"); return }
        let response = await send(operation)
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .sessionRemoved(sessionID)))

        #expect(refusal == "the session has ended; session.close removes its record")
        guard case .refused = rename else { Issue.record("a rename reached a hidden row"); return }
        #expect(operation == .closeSession(sessionID))
        #expect(response.ok)
        #expect(script.commandCalls.first?.contains("session close --target \(sessionID.uuidString)") == true)
        #expect(actions.marks.isEmpty)
        #expect(store.catalogDetachedSessions.isEmpty)
    }

    @Test func everyChangeToTheTrackedOperationsIsAnnounced() async {
        install(snapshot())
        var changes = 0
        actions.onChange = { changes += 1 }
        queue(reply(.applied, rev: 1))

        _ = await send(rename)
        let afterSend = changes
        advance(to: 1)

        #expect(afterSend >= 2)
        #expect(changes > afterSend)
        #expect(actions.marks.isEmpty)
    }

    @Test func theCreatedIdComesBackWithTheReply() async {
        install(snapshot())
        queue(reply(.applied, rev: 1, id: "new-id"))

        let response = await send(.newSession(workspace: workspaceID))

        #expect(response.result?.id == "new-id")
    }
}
