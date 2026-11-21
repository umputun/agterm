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
        func attachCommand(host: String, pane: CatalogPane, claim: Bool) -> String { "attach \(host) \(pane.daemon)\(claim ? " claim" : "")" }
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
        var commandGate: CheckedContinuation<Void, Never>?
        var gateNextCommand = false
        var commandStatus: Int32 = 0

        func answer(_ argv: [String]) async -> (status: Int32, stdout: String) {
            calls.append(argv)
            let line = Self.plain(argv)
            let opID = Self.opID(line)
            guard line.contains(" catalog op ") else {
                if gateNextCommand {
                    gateNextCommand = false
                    await withCheckedContinuation { commandGate = $0 }
                }
                return (commandStatus, commands.isEmpty ? "" : commands.removeFirst()(opID))
            }
            if gateNextLookup {
                gateNextLookup = false
                await withCheckedContinuation { lookupGate = $0 }
            }
            return (0, lookups.isEmpty ? "" : lookups.removeFirst()(opID))
        }

        func openCommandGate() {
            commandGate?.resume()
            commandGate = nil
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

    @Test func aWorkspaceAskedForCollapsedArrivesFolded() async {
        install(snapshot())
        let created = UUID()
        queue(reply(.applied, rev: 1, id: created.uuidString))

        let response = await send(.newWorkspace(name: "x", collapsed: true, tint: nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .workspaceAdded(CatalogWorkspace(id: created, name: "x", sessions: []), index: 1)))

        #expect(response.ok)
        #expect(store.workspaces.first { $0.id == created }?.isExpanded == false)
    }

    @Test func flagAndTintRunHereUntilTheServerKeepsThem() {
        install(snapshot())
        store.remoteActions = actions
        let flag = ControlRequest(cmd: .sessionFlag, target: sessionID.uuidString, args: ControlArgs(mode: "on"))
        let tint = ControlRequest(cmd: .workspaceTint, target: workspaceID.uuidString, args: ControlArgs(mode: "clear"))
        let rename = ControlRequest(cmd: .sessionRename, target: sessionID.uuidString, args: ControlArgs(name: "x"))
        let older = (RemoteOperation.runsLocally(flag, in: store), RemoteOperation.runsLocally(tint, in: store))

        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .workspaceChanged(id: workspaceID, name: "w", tint: "")))

        #expect(older == (true, true))
        #expect(!RemoteOperation.runsLocally(flag, in: store))
        #expect(!RemoteOperation.runsLocally(tint, in: store))
        #expect(!RemoteOperation.runsLocally(rename, in: store))
    }

    @Test func anUndoIDLeavesByItselfWhenItsGraceEnds() async throws {
        install(snapshot())
        actions.undoGrace = 0.05
        let undoable = reply(.applied, rev: 1)
        queue { opID in
            var response = try? JSONDecoder().decode(ControlResponse.self, from: Data(undoable(opID).utf8))
            response?.result?.undoable = true
            response?.result?.undoID = "u1"
            return String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self)
        }

        _ = await send(.closeSession(sessionID, undoable: true))
        #expect(actions.undoIDs == ["u1"])

        var turns = 0
        while !actions.undoIDs.isEmpty, turns < 3000 {
            turns += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(actions.undoIDs.isEmpty)
        #expect(actions.takeUndo() == nil)
    }

    @Test func aBatchCloseIsOneCommandMarkedOnItsFirstRowUntilItsRevision() async {
        let other = UUID()
        install(snapshot(sessions: [session(sessionID, panes: panes), session(other, panes: [UUID()])]))
        queue(reply(.applied, rev: 1))

        let response = await send(.closeSessions([sessionID, other]))
        let pending = (actions.pendingState(of: sessionID), actions.pendingState(of: other))
        advance(to: 1)

        #expect(response.ok)
        #expect(script.commandCalls.count == 1)
        #expect(script.commandCalls[0].contains("session close --target \(sessionID.uuidString) --target \(other.uuidString)"))
        #expect(pending.0 != nil)
        #expect(pending.1 == nil)
        #expect(actions.marks.isEmpty)
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

    @Test func aServerTooOldForACompanionMoveIsAFinalAnswer() async {
        install(snapshot())
        script.commandStatus = 64
        queue({ _ in "" })

        let response = await send(.moveCompanion(sessionID, parent: UUID(), index: 0))
        await settleLookups()

        #expect(response.error == "the agterm-server on box is too old for companion moves")
        #expect(actions.marks.isEmpty)
        #expect(script.lookupCalls.isEmpty)
        #expect(script.commandCalls.first?.contains("session move --target \(sessionID.uuidString) --parent") == true)
    }

    @Test func aRunningServerThatCannotDecodeACompanionMoveIsAFinalAnswer() async {
        install(snapshot())
        let refusal = ControlResponse(ok: false, error: "invalid request: unknown cmd session.companion.move")
        queue({ _ in String(decoding: (try? JSONEncoder().encode(refusal)) ?? Data(), as: UTF8.self) })

        let response = await send(.moveCompanion(sessionID, parent: UUID(), index: nil))
        await settleLookups()

        #expect(response.error == "the agterm-server on box is too old for companion moves")
        #expect(actions.marks.isEmpty)
        #expect(script.lookupCalls.isEmpty)
    }

    @Test func aServerTooOldForACompanionPromotionIsAFinalAnswer() async {
        install(snapshot())
        let refusal = ControlResponse(ok: false, error: "invalid request: unknown cmd session.companion.promote")
        queue({ _ in String(decoding: (try? JSONEncoder().encode(refusal)) ?? Data(), as: UTF8.self) })

        let response = await send(.promoteCompanion(sessionID, to: nil))
        await settleLookups()

        #expect(response.error == "the agterm-server on box is too old for companion promotion")
        #expect(actions.marks.isEmpty)
        #expect(script.lookupCalls.isEmpty)
    }

    @Test func anyOtherOperationTheFarCLIRefusesIsStillLookedUp() async {
        install(snapshot())
        script.commandStatus = 64
        queue({ _ in "" })

        let response = await send(rename)

        #expect(!response.ok)
        #expect(actions.marks.map(\.unknown) == [true])
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

    @Test func aReplacingScratchCarriesTheScratchTheWindowSaw() async {
        let scratch = CatalogPane(identity: UUID(), daemon: ZmxSupport.scratchDaemonName(for: UUID()), endpoint: Self.endpoint)
        var entry = session(sessionID, panes: panes)
        entry.fields.scratch = CatalogScratch(pane: scratch, shown: false)
        install(snapshot(sessions: [entry]))
        queue(reply(.noop))
        queue(reply(.noop))

        _ = await send(.setScratch(sessionID, shown: true, command: "-htop"))
        _ = await send(.setScratch(sessionID, shown: false))

        let lines = script.commandCalls
        #expect(lines.first?.contains("session scratch on --target \(sessionID.uuidString) --command=-htop --expect-scratch \(scratch.identity.uuidString) --op-id") == true)
        #expect(lines.last?.contains("--expect-scratch") == false)
    }

    @Test func aReplacingScratchOnARowWithoutOneExpectsNone() async {
        install(snapshot())
        queue(reply(.noop))

        _ = await send(.setScratch(sessionID, shown: true, command: "htop"))

        #expect(script.commandCalls.first?.contains("--expect-scratch none --op-id") == true)
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

    @Test func aKillAndARestartPinThePanesTheWindowSaw() async {
        install(snapshot())
        queue(reply(.noop))
        queue(reply(.noop))

        _ = await send(.killDaemon(sessionID, pane: .right))
        _ = await send(.restart(sessionID, pane: .left, command: nil))

        let pin = "--expect-panes \(panes[0].uuidString),\(panes[1].uuidString) --op-id"
        #expect(script.commandCalls.count == 2)
        #expect(script.commandCalls.allSatisfy { $0.contains(pin) })
    }

    @Test func anEndedRowIsRestartedWithNoPanesToPin() async {
        install(snapshot(sessions: [session(sessionID, panes: [])]))
        queue(reply(.noop))

        _ = await send(.restart(sessionID, pane: .left, command: "make"))

        let line = script.commandCalls.first ?? ""
        #expect(line.contains("session restart --target \(sessionID.uuidString) --pane left --command=make --op-id"))
        #expect(!line.contains("--expect-panes"))
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

    @Test func everyCommandAndLookupToAMacNamesItsWindow() async {
        let window = UUID()
        let mac = RemoteCatalogMirror(host: "mac", store: store, effects: effects, viewState: RemoteWindowViewState(),
                                      originWindow: window)
        let script = script
        let macActions = RemoteCatalogActions(mirror: mac, runner: { argv in await script.answer(argv) })
        _ = mac.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: Self.versions)))
        _ = mac.receive(.snapshot(snapshot(rev: 3)))
        queue({ _ in "" })
        queueLookup(reply(.applied, rev: 3))

        guard case .ready(let prepared) = macActions.prepare(rename) else {
            Issue.record("not prepared")
            return
        }
        _ = await macActions.send(prepared)
        await macActions.lookupTask?.value

        #expect(script.commandCalls.count == 1)
        #expect(script.lookupCalls.count == 1)
        #expect(script.calls.map(Script.plain).allSatisfy { $0.contains("--window \(window.uuidString)") })
    }

    @Test func aServerWindowsCommandsNameNoWindow() async {
        install(snapshot(rev: 3))
        queue(reply(.applied, rev: 3))

        _ = await send(rename)

        #expect(script.commandCalls.count == 1)
        #expect(script.calls.map(Script.plain).allSatisfy { !$0.contains("--window") })
    }

    @Test func anOperationNamesTheRowsItBroughtBack() {
        let made = UUID(), parent = UUID(), row = UUID(), reopened = UUID()
        let created = ControlResult(id: made.uuidString)
        let converted = ControlResult(id: row.uuidString, parent: parent.uuidString)
        var recent = ControlResult()
        recent.recentOpen = ControlRecentOpen(item: recentItem([reopened, row]), window: UUID().uuidString, complete: true)

        #expect(RemoteOperation.newSession(workspace: UUID()).claimedRows(created) == [made])
        #expect(RemoteOperation.newSessionInNamedWorkspace(name: "w", create: true).claimedRows(created) == [made])
        #expect(RemoteOperation.newCompanion(parent: row).claimedRows(created) == [made])
        #expect(RemoteOperation.duplicateCompanion(row).claimedRows(created) == [made])
        #expect(RemoteOperation.convertCompanion(row).claimedRows(converted) == [parent])
        #expect(RemoteOperation.reopenRecent(nil).claimedRows(recent) == [reopened, row])
        #expect(RemoteOperation.newWorkspace(name: "w").claimedRows(created).isEmpty)
        #expect(RemoteOperation.renameSession(row, name: "x").claimedRows(created).isEmpty)
    }

    @Test func aReopenNamesEveryRowItRestoredWhenTheOriginReportsThem() {
        let companion = UUID(), parent = UUID()
        var recent = ControlResult()
        recent.recentOpen = ControlRecentOpen(item: recentItem([companion]), window: UUID().uuidString, complete: true,
                                              restored: [parent.uuidString, companion.uuidString])

        #expect(RemoteOperation.reopenRecent(nil).claimedRows(recent) == [parent, companion])
    }

    @Test func aReopenThatBroughtBackTheParentTakesTheLeadOfBoth() async throws {
        installMac(snapshot(sessions: []))
        let parent = UUID(), parentPane = UUID()
        queue(answering {
            $0.recentOpen = ControlRecentOpen(item: self.recentItem([self.sessionID]), window: UUID().uuidString, complete: true,
                                              restored: [parent.uuidString, self.sessionID.uuidString])
        })

        _ = await send(.reopenRecent(nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(session(parent, panes: [parentPane]), workspace: workspaceID, index: 0)))
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .sessionAdded(session(sessionID, panes: [panes[0]]), workspace: workspaceID, index: 1)))

        #expect(store.session(withID: parent)?.initialCommand == "attach box agterm-\(parentPane.uuidString) claim")
        #expect(store.session(withID: sessionID)?.initialCommand == "attach box agterm-\(panes[0].uuidString) claim")
    }

    private func recentItem(_ sessions: [UUID]) -> ControlRecentItem {
        ControlRecentItem(id: UUID().uuidString, kind: "session", title: "s", subtitle: nil, closedAt: 0,
                          workspaceID: workspaceID.uuidString, sessionIDs: sessions.map(\.uuidString), host: nil)
    }

    private func installMac(_ snapshot: CatalogSnapshot) {
        mirror.checkVersions(nil, mac: Self.versions, app: nil)
        install(snapshot)
    }

    private func answering(_ edit: @escaping (inout ControlResult) -> Void) -> (String) -> String {
        let base = reply(.applied, rev: 1)
        return { opID in
            var response = try? JSONDecoder().decode(ControlResponse.self, from: Data(base(opID).utf8))
            if var result = response?.result {
                edit(&result)
                response?.result = result
            }
            return String(decoding: (try? JSONEncoder().encode(response)) ?? Data(), as: UTF8.self)
        }
    }

    private func macActions(window: UUID = UUID()) -> RemoteCatalogActions {
        let mac = RemoteCatalogMirror(host: "box", store: store, effects: effects, viewState: RemoteWindowViewState(), originWindow: window)
        let script = script
        return RemoteCatalogActions(mirror: mac, runner: { argv in await script.answer(argv) })
    }

    private func connect(_ mac: RemoteCatalogActions, recent: [ControlRecentItem]? = nil) {
        _ = mac.mirror.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: Self.versions)))
        var catalog = snapshot(sessions: [])
        catalog.recent = recent
        _ = mac.mirror.receive(.snapshot(catalog))
    }

    @Test func aMacWindowClearsItsRecentClosedThroughAnOperationInThatWindow() async throws {
        let window = UUID()
        let mac = macActions(window: window)
        connect(mac, recent: [])
        queue(reply(.applied, rev: 1))

        let response = await mac.clearRecent()

        let line = Script.plain(try #require(script.calls.last))
        #expect(response.ok)
        #expect(line.contains("recent clear") && line.contains("--op-id") && line.contains("--window \(window.uuidString)"))
    }

    @Test func aMacWindowStillConnectingRefusesToClearAndSendsNothing() async {
        let response = await macActions().clearRecent()

        #expect(!response.ok)
        #expect(script.calls.isEmpty)
    }

    @Test func aServerWindowClearsWithAPlainRequest() async throws {
        install(snapshot())
        script.commands.append { _ in #"{"ok":true}"# }

        let response = await actions.clearRecent()

        let line = Script.plain(try #require(script.calls.last))
        #expect(response.ok)
        #expect(line.contains("recent clear") && !line.contains("--op-id"))
    }

    @Test func aMacWindowListsItsRecentClosedFromTheCatalogWithoutAsking() async throws {
        let mac = macActions()
        connect(mac, recent: [recentItem([sessionID])])

        let response = await mac.listRecent()

        #expect(response.result?.recent?.map(\.sessionIDs) == [[sessionID.uuidString]])
        #expect(script.calls.isEmpty)
    }

    @Test func aRowReopenedFromRecentClosedTakesTheLeadWhenItArrives() async throws {
        installMac(snapshot(sessions: []))
        let row = session(sessionID, panes: [panes[0]])
        queue(answering { $0.recentOpen = ControlRecentOpen(item: self.recentItem([self.sessionID]), window: UUID().uuidString, complete: true) })

        _ = await send(.reopenRecent(nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(row, workspace: workspaceID, index: 0)))

        #expect(store.session(withID: sessionID)?.initialCommand == "attach box agterm-\(panes[0].uuidString) claim")
    }

    @Test func anUndoneCloseTakesTheLeadOfTheRowsItClosed() async throws {
        let row = session(sessionID, panes: [panes[0]])
        installMac(snapshot(sessions: [row]))
        queue(answering {
            $0.undoable = true
            $0.undoID = "u1"
            $0.closed = [self.sessionID.uuidString]
        })
        _ = await send(.closeSession(sessionID, undoable: true))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionRemoved(sessionID)))
        queue(answering { $0.id = "u1" })

        _ = await send(.undoClose("u1"))
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .sessionAdded(row, workspace: workspaceID, index: 0)))

        #expect(store.session(withID: sessionID)?.initialCommand == "attach box agterm-\(panes[0].uuidString) claim")
    }

    private func splitPane(held: Bool) -> CatalogPane {
        CatalogPane(identity: panes[1], daemon: "agterm-\(panes[1].uuidString)", endpoint: Self.endpoint, held: held ? true : nil)
    }

    @Test func aSplitThatStartsHeldTakesTheLeadOnceItRunsReplyFirst() async throws {
        installMac(snapshot(sessions: [session(sessionID, panes: [panes[0]])]))
        queue(answering { _ in })

        _ = await send(.setSplit(sessionID, shown: true, axis: nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .paneAdded(splitPane(held: true), session: sessionID)))
        let whileHeld = store.session(withID: sessionID)?.splitInitialCommand
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .paneChanged(splitPane(held: false), session: sessionID)))

        #expect(whileHeld == RemoteSession.endedCommand(host: "box"))
        #expect(store.session(withID: sessionID)?.splitInitialCommand == "attach box agterm-\(panes[1].uuidString) claim")
    }

    @Test func aSplitThatStartsHeldTakesTheLeadOnceItRunsDeltaFirst() async throws {
        installMac(snapshot(sessions: [session(sessionID, panes: [panes[0]])]))
        queue(answering { _ in }, before: { [unowned self] in
            _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .paneAdded(splitPane(held: true), session: sessionID)))
        })

        _ = await send(.setSplit(sessionID, shown: true, axis: nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .paneChanged(splitPane(held: false), session: sessionID)))

        #expect(store.session(withID: sessionID)?.splitInitialCommand == "attach box agterm-\(panes[1].uuidString) claim")
    }

    @Test func anUndoAcceptedBeforeItsOfferExpiresStillTakesTheLead() async throws {
        let row = session(sessionID, panes: [panes[0]])
        installMac(snapshot(sessions: [row]))
        actions.undoGrace = 0.2
        queue(answering {
            $0.undoable = true
            $0.undoID = "u1"
            $0.closed = [self.sessionID.uuidString]
        })
        _ = await send(.closeSession(sessionID, undoable: true))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionRemoved(sessionID)))
        queue(answering { $0.id = "u1" })
        script.gateNextCommand = true

        let undo = Task { await send(.undoClose("u1")) }
        var turns = 0
        while script.commandGate == nil, turns < 3000 {
            turns += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        let inFlight = script.commandGate != nil
        while !actions.undoIDs.isEmpty, turns < 6000 {
            turns += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        let expired = actions.undoIDs.isEmpty
        script.openCommandGate()
        _ = await undo.value
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .sessionAdded(row, workspace: workspaceID, index: 0)))

        #expect(inFlight && expired)
        #expect(store.session(withID: sessionID)?.initialCommand == "attach box agterm-\(panes[0].uuidString) claim")
    }

    @Test func aSplitAddedFromHereTakesTheLeadOfTheNewPaneOnly() async throws {
        installMac(snapshot(sessions: [session(sessionID, panes: [panes[0]])]))
        let added = CatalogPane(identity: panes[1], daemon: "agterm-\(panes[1].uuidString)", endpoint: Self.endpoint)
        queue(answering { _ in })

        _ = await send(.setSplit(sessionID, shown: true, axis: nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .paneAdded(added, session: sessionID)))

        let row = try #require(store.session(withID: sessionID))
        #expect(row.splitInitialCommand == "attach box agterm-\(panes[1].uuidString) claim")
        #expect(row.initialCommand == "attach box agterm-\(panes[0].uuidString)")
    }

    private func rowWithHeldSplit() -> CatalogSession {
        var row = session(sessionID, panes: panes)
        row.panes[1] = splitPane(held: true)
        return row
    }

    private func reopenReply() {
        queue(answering { $0.recentOpen = ControlRecentOpen(item: self.recentItem([self.sessionID]), window: UUID().uuidString, complete: true) })
    }

    @Test func aReopenedRowWhoseSplitStartsHeldTakesItsLeadOnceItRunsReplyFirst() async throws {
        installMac(snapshot(sessions: []))
        reopenReply()

        _ = await send(.reopenRecent(nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(rowWithHeldSplit(), workspace: workspaceID, index: 0)))
        let whileHeld = store.session(withID: sessionID)?.splitInitialCommand
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .paneChanged(splitPane(held: false), session: sessionID)))

        let row = try #require(store.session(withID: sessionID))
        #expect(whileHeld == RemoteSession.endedCommand(host: "box"))
        #expect(row.initialCommand == "attach box agterm-\(panes[0].uuidString) claim")
        #expect(row.splitInitialCommand == "attach box agterm-\(panes[1].uuidString) claim")
    }

    @Test func aReopenedRowWhoseSplitStartsHeldTakesItsLeadOnceItRunsDeltaFirst() async throws {
        installMac(snapshot(sessions: []))
        queue(answering { $0.recentOpen = ControlRecentOpen(item: self.recentItem([self.sessionID]), window: UUID().uuidString, complete: true) },
              before: { [unowned self] in
                  _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(rowWithHeldSplit(), workspace: workspaceID, index: 0)))
              })

        _ = await send(.reopenRecent(nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .paneChanged(splitPane(held: false), session: sessionID)))

        #expect(store.session(withID: sessionID)?.splitInitialCommand == "attach box agterm-\(panes[1].uuidString) claim")
    }

    @Test func aHeldPaneRemovedBeforeItRunsLosesItsClaim() async throws {
        installMac(snapshot(sessions: []))
        reopenReply()
        _ = await send(.reopenRecent(nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(rowWithHeldSplit(), workspace: workspaceID, index: 0)))

        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .paneRemoved(panes[1], session: sessionID)))
        _ = mirror.receive(.delta(epoch: "e1", rev: 3, change: .paneAdded(splitPane(held: false), session: sessionID)))

        #expect(store.session(withID: sessionID)?.splitInitialCommand == "attach box agterm-\(panes[1].uuidString)")
    }

    @Test func aReplyBetweenAPaneRunningAndItsRowGoingLiveStillTakesTheLead() async throws {
        installMac(snapshot(sessions: []))
        var ended = session(sessionID, panes: [panes[0]])
        ended.fields.lifecycle = .ended
        ended.panes[0].held = true
        queue(answering { $0.recentOpen = ControlRecentOpen(item: self.recentItem([self.sessionID]), window: UUID().uuidString, complete: true) },
              before: { [unowned self] in
                  _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(ended, workspace: workspaceID, index: 0)))
                  var running = ended.panes[0]
                  running.held = nil
                  _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .paneChanged(running, session: sessionID)))
              })

        _ = await send(.reopenRecent(nil))
        var live = ended.fields
        live.lifecycle = .live
        _ = mirror.receive(.delta(epoch: "e1", rev: 3, change: .sessionChanged(live)))

        #expect(store.session(withID: sessionID)?.initialCommand == "attach box agterm-\(panes[0].uuidString) claim")
    }

    @Test func aClaimedRowArrivingEndedTakesTheLeadOnceItGoesLive() async throws {
        installMac(snapshot(sessions: []))
        reopenReply()
        _ = await send(.reopenRecent(nil))
        var ended = session(sessionID, panes: [panes[0]])
        ended.fields.lifecycle = .ended
        ended.panes[0].held = true

        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(ended, workspace: workspaceID, index: 0)))
        var running = ended.panes[0]
        running.held = nil
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .paneChanged(running, session: sessionID)))
        var live = ended.fields
        live.lifecycle = .live
        _ = mirror.receive(.delta(epoch: "e1", rev: 3, change: .sessionChanged(live)))

        #expect(store.session(withID: sessionID)?.initialCommand == "attach box agterm-\(panes[0].uuidString) claim")
    }

    @Test func aRowRemovedWhileAPaneIsHeldClaimsNothingWhenTheOriginBringsItBack() async throws {
        installMac(snapshot(sessions: []))
        reopenReply()
        _ = await send(.reopenRecent(nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(rowWithHeldSplit(), workspace: workspaceID, index: 0)))

        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .sessionRemoved(sessionID)))
        _ = mirror.receive(.delta(epoch: "e1", rev: 3, change: .sessionAdded(session(sessionID, panes: panes), workspace: workspaceID, index: 0)))

        #expect(store.session(withID: sessionID)?.splitInitialCommand == "attach box agterm-\(panes[1].uuidString)")
    }

    @Test func aRowDetachedWhileAPaneIsHeldClaimsNothingOnceReattached() async throws {
        installMac(snapshot(sessions: []))
        reopenReply()
        _ = await send(.reopenRecent(nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(rowWithHeldSplit(), workspace: workspaceID, index: 0)))

        mirror.detach(sessions: [sessionID])
        _ = mirror.reattach(session: sessionID)
        _ = mirror.receive(.delta(epoch: "e1", rev: 2, change: .paneChanged(splitPane(held: false), session: sessionID)))

        #expect(store.session(withID: sessionID)?.splitInitialCommand == "attach box agterm-\(panes[1].uuidString)")
    }

    @Test func aNewStreamDropsTheClaimOfAPaneStillHeld() async throws {
        installMac(snapshot(sessions: []))
        reopenReply()
        _ = await send(.reopenRecent(nil))
        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionAdded(rowWithHeldSplit(), workspace: workspaceID, index: 0)))

        mirror.subscribing()
        install(snapshot(epoch: "e2", sessions: [rowWithHeldSplit()]))
        _ = mirror.receive(.delta(epoch: "e2", rev: 1, change: .paneChanged(splitPane(held: false), session: sessionID)))

        #expect(store.session(withID: sessionID)?.splitInitialCommand == "attach box agterm-\(panes[1].uuidString)")
    }

    @Test func showingASplitThatAlreadyRunsClaimsNothing() async throws {
        let row = session(sessionID, panes: panes)
        installMac(snapshot(sessions: [row]))
        queue(answering { _ in })

        _ = await send(.setSplit(sessionID, shown: true, axis: nil))

        #expect(store.session(withID: sessionID)?.splitInitialCommand == "attach box agterm-\(panes[1].uuidString)")
    }
}
