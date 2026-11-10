import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsReceiptsTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private var hub: CatalogHub { harness.actions.streams.catalogHub }

    private func args(_ base: ControlArgs = ControlArgs(), op: String, epoch: String? = nil) -> ControlArgs {
        var args = base
        args.opID = op
        args.epoch = epoch ?? hub.epoch
        return args
    }

    private func serve(_ cmd: Command, target: String? = nil, _ base: ControlArgs = ControlArgs(), op: String,
                       epoch: String? = nil) async -> ControlResponse {
        await harness.actions.serve(ControlRequest(cmd: cmd, target: target, args: args(base, op: op, epoch: epoch)))
    }

    private func plain(_ cmd: Command, target: String? = nil, _ args: ControlArgs? = nil) async -> ControlResponse {
        await harness.actions.serve(ControlRequest(cmd: cmd, target: target, args: args))
    }

    private var sessionCount: Int { harness.store.workspaces.flatMap(\.sessions).count }

    @Test func everyStructuralCommandAnswersAppliedAtTheRevisionItsChangeReached() async throws {
        let created = await serve(.sessionNew, op: "new")
        let session = try harness.session(created)
        let id = session.id.uuidString
        let workspace = try #require(await serve(.workspaceNew, ControlArgs(name: "dev"), op: "ws").result?.id)
        let replies = [
            created,
            await serve(.sessionRename, target: id, ControlArgs(name: "build"), op: "rename"),
            await serve(.sessionSplit, target: id, ControlArgs(mode: "on"), op: "split"),
            await serve(.sessionSwap, target: id, op: "swap"),
            await serve(.sessionSplitClose, target: id, op: "split-close"),
            await serve(.sessionCompanionNew, target: id, op: "companion"),
            await serve(.workspaceRename, target: workspace, ControlArgs(name: "ops"), op: "ws-rename"),
            await serve(.sessionMove, target: id, ControlArgs(workspace: workspace), op: "move"),
            await serve(.workspaceMove, target: workspace, ControlArgs(to: "top"), op: "ws-move"),
            await serve(.sessionClose, target: id, op: "close"),
            await serve(.workspaceDelete, target: workspace, op: "ws-delete"),
        ]

        let receipts = replies.map(\.result?.receipt)
        #expect(replies.allSatisfy { $0.ok })
        #expect(receipts.allSatisfy { $0?.outcome == .applied && $0?.epoch == hub.epoch })
        let revisions = receipts.compactMap { $0?.rev }
        #expect(revisions.count == replies.count)
        #expect(revisions == revisions.sorted())
        #expect(revisions.last == hub.rev)
        #expect(Set(receipts.compactMap { $0?.opID }).count == replies.count)
    }

    @Test func aCommandTheHostRefusesAnswersRefusedWithItsError() async {
        let reply = await serve(.sessionRename, target: UUID().uuidString, ControlArgs(name: "x"), op: "bad")

        #expect(!reply.ok)
        #expect(reply.result?.receipt?.outcome == .refused)
        #expect(reply.result?.receipt?.error == reply.error)
    }

    @Test func aCommandThatChangesNothingAnswersNoop() async throws {
        let session = try harness.session(await plain(.sessionNew))

        let reply = await serve(.sessionSplit, target: session.id.uuidString, ControlArgs(mode: "off"), op: "off")

        #expect(reply.ok)
        #expect(reply.result?.receipt == CatalogReceipt(opID: "off", epoch: hub.epoch, outcome: .noop))
    }

    @Test func aRepeatedOperationNeverRunsTwice() async throws {
        let first = await serve(.sessionNew, op: "once")
        let count = sessionCount

        let second = await serve(.sessionNew, op: "once")

        #expect(sessionCount == count)
        #expect(second.result?.receipt == first.result?.receipt)
        #expect(second.ok)
    }

    @Test func aRefusalIsRecordedSoTheIdStaysRefused() async throws {
        _ = await serve(.sessionNew, op: "stale", epoch: "an-old-epoch")
        let count = sessionCount

        let retried = await serve(.sessionNew, op: "stale")

        #expect(sessionCount == count)
        #expect(retried.result?.receipt?.outcome == .refused)
    }

    @Test func anotherEpochIsRefusedBeforeTheCommandRuns() async {
        let count = sessionCount

        let reply = await serve(.sessionNew, op: "old", epoch: "an-old-epoch")

        #expect(sessionCount == count)
        #expect(reply.result?.receipt?.outcome == .refused)
        #expect(reply.error?.contains(hub.epoch) == true)
    }

    @Test func anOperationIdWithoutAnEpochIsRefused() async {
        var args = ControlArgs()
        args.opID = "no-epoch"

        let reply = await harness.actions.serve(ControlRequest(cmd: .sessionNew, args: args))

        #expect(reply.result?.receipt?.outcome == .refused)
    }

    @Test func aNonStructuralCommandRefusesAnOperationId() async throws {
        let session = try harness.session(await plain(.sessionNew))

        let reply = await serve(.sessionStatus, target: session.id.uuidString, ControlArgs(status: "active"), op: "st")

        #expect(reply.error == "session.status takes no operation id")
        #expect(harness.store.catalogOperations?.receipt("st") == nil)
    }

    @Test func aLookupFencesAnUnseenIdSoItsLateArrivalIsRefused() async {
        let lookup = await plain(.catalogOp, target: "late")
        let count = sessionCount

        let arrival = await serve(.sessionNew, op: "late")

        #expect(lookup.ok)
        #expect(lookup.result?.receipt == CatalogReceipt(opID: "late", epoch: hub.epoch, outcome: .fenced))
        #expect(sessionCount == count)
        #expect(!arrival.ok)
        #expect(arrival.result?.receipt?.outcome == .fenced)
    }

    private func lookup(_ opID: String, sent: CatalogPosition?) async -> ControlResponse {
        var args = ControlArgs()
        args.epoch = sent?.epoch
        args.rev = sent?.rev
        return await plain(.catalogOp, target: opID, args)
    }

    private func fillTable(droppingAt position: CatalogPosition) {
        var table = harness.store.catalogOperations ?? CatalogOperationTable()
        for index in 0...CatalogOperationTable.capacity {
            table.record(CatalogReceipt(opID: "filler\(index)", epoch: position.epoch, outcome: .noop), at: position)
        }
        harness.store.catalogOperations = table
    }

    @Test func aMissTheTablesDropCouldCoverIsUnknownAndStaysUnknown() async throws {
        let sent = CatalogPosition(epoch: hub.epoch, rev: hub.rev)
        fillTable(droppingAt: sent)
        let count = sessionCount

        let first = await lookup("lost", sent: sent)
        let again = await lookup("lost", sent: sent)
        let arrival = await serve(.sessionNew, op: "lost")
        let onDisk = try PersistenceStore(directory: URL(fileURLWithPath: harness.scratch.state)).loadChecked().catalogOperations

        #expect(first.ok)
        #expect(first.result?.receipt == CatalogReceipt(opID: "lost", epoch: hub.epoch, outcome: .unknown))
        #expect(again.result?.receipt?.outcome == .unknown)
        #expect(!arrival.ok)
        #expect(arrival.result?.receipt?.outcome == .unknown)
        #expect(sessionCount == count)
        #expect(onDisk?.receipt("lost")?.outcome == .unknown)
    }

    @Test func aMissSentAfterTheLastDropIsFenced() async throws {
        hub.refresh()
        fillTable(droppingAt: CatalogPosition(epoch: hub.epoch, rev: hub.rev))
        _ = await plain(.sessionNew)
        hub.refresh()

        let reply = await lookup("late", sent: CatalogPosition(epoch: hub.epoch, rev: hub.rev))

        #expect(reply.result?.receipt?.outcome == .fenced)
    }

    @Test func aPanePinnedCommandRunsOnTheSameShapedSession() async throws {
        let session = try harness.session(await plain(.sessionNew))
        _ = await plain(.sessionSplit, target: session.id.uuidString, ControlArgs(mode: "on"))
        let split = try #require(harness.store.session(withID: session.id)?.splitPaneIdentity)
        var args = ControlArgs()
        args.panes = [session.paneIdentity.uuidString, split.uuidString]

        let reply = await serve(.sessionSwap, target: session.id.uuidString, args, op: "swap")

        #expect(reply.ok)
        #expect(reply.result?.receipt?.outcome == .applied)
    }

    @Test(arguments: [true, false])
    func aStalePanePinIsRefusedWhateverFormTheTargetTakes(_ prefix: Bool) async throws {
        let session = try harness.session(await plain(.sessionNew))
        harness.store.selectSession(session.id)
        _ = await plain(.sessionSplit, target: session.id.uuidString, ControlArgs(mode: "on"))
        let split = try #require(harness.store.session(withID: session.id)?.splitPaneIdentity)
        var args = ControlArgs()
        args.panes = [session.paneIdentity.uuidString, UUID().uuidString]
        let target = prefix ? String(session.id.uuidString.prefix(8)) : "active"

        let reply = await serve(.sessionSplitClose, target: target, args, op: "close-split")

        #expect(reply.result?.receipt?.outcome == .refused)
        #expect(harness.store.session(withID: session.id)?.splitPaneIdentity == split)
    }

    @Test func aPanePinnedCommandIsRefusedOnceThePanesChanged() async throws {
        let session = try harness.session(await plain(.sessionNew))
        _ = await plain(.sessionSplit, target: session.id.uuidString, ControlArgs(mode: "on"))
        let seen = try #require(harness.store.session(withID: session.id)?.splitPaneIdentity)
        _ = await plain(.sessionSplitClose, target: session.id.uuidString)
        _ = await plain(.sessionSplit, target: session.id.uuidString, ControlArgs(mode: "on"))
        let replacement = try #require(harness.store.session(withID: session.id)?.splitPaneIdentity)
        var args = ControlArgs()
        args.panes = [session.paneIdentity.uuidString, seen.uuidString]

        let reply = await serve(.sessionSplitClose, target: session.id.uuidString, args, op: "close-split")

        #expect(!reply.ok)
        #expect(reply.result?.receipt?.outcome == .refused)
        #expect(reply.error == "the session's panes changed; take the catalog again")
        #expect(harness.store.session(withID: session.id)?.splitPaneIdentity == replacement)
    }

    @Test func aLookupAnswersARecordedOperation() async throws {
        let applied = await serve(.workspaceNew, ControlArgs(name: "dev"), op: "ws")

        let lookup = await plain(.catalogOp, target: "ws")

        #expect(lookup.ok)
        #expect(lookup.result?.receipt == applied.result?.receipt)
    }

    @Test func aReceiptThatCannotBeSavedIsNotHandedOut() async throws {
        let saved = harness.scratch.state + "/workspaces.json"
        try? FileManager.default.removeItem(atPath: saved)
        try FileManager.default.createDirectory(atPath: saved + "/blocker", withIntermediateDirectories: true)

        let unsaved = "the receipt for operation unsaved could not be saved; ask catalog.op for it"

        let reply = await serve(.workspaceNew, ControlArgs(name: "dev"), op: "unsaved")
        let fence = await plain(.catalogOp, target: "unseen")
        let lookupWhileBlocked = await plain(.catalogOp, target: "unsaved")
        let repeatWhileBlocked = await serve(.workspaceNew, ControlArgs(name: "dev"), op: "unsaved")
        let fenceAgainWhileBlocked = await plain(.catalogOp, target: "unseen")
        let lateArrival = await serve(.workspaceNew, ControlArgs(name: "late"), op: "unseen")

        #expect(reply == ControlResponse(ok: false, error: unsaved))
        #expect(fence == ControlResponse(ok: false, error: "could not save the fence for operation unseen"))
        #expect(lookupWhileBlocked == ControlResponse(ok: false, error: unsaved))
        #expect(repeatWhileBlocked == ControlResponse(ok: false, error: unsaved))
        #expect(fenceAgainWhileBlocked.ok == false)
        #expect(lateArrival.ok == false)
        #expect(harness.store.workspaces.filter { $0.name == "dev" }.count == 1)
        #expect(!harness.store.workspaces.contains { $0.name == "late" })

        try FileManager.default.removeItem(atPath: saved)
        let lookup = await plain(.catalogOp, target: "unsaved")
        let fenceLookup = await plain(.catalogOp, target: "unseen")
        let onDisk = try PersistenceStore(directory: URL(fileURLWithPath: harness.scratch.state)).loadChecked().catalogOperations

        #expect(lookup.ok)
        #expect(lookup.result?.receipt?.outcome == .applied)
        #expect(fenceLookup.result?.receipt?.outcome == .fenced)
        #expect(onDisk?.receipt("unsaved")?.outcome == .applied)
        #expect(onDisk?.receipt("unseen")?.outcome == .fenced)
    }

    @Test func catalogOpIsServed() {
        #expect(ServerCommandPolicy.refusal(.catalogOp) == nil)
    }
}
