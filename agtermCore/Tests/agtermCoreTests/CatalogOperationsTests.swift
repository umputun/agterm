import Foundation
import Testing
@testable import agtermCore

@MainActor
struct CatalogOperationsTests {
    private let here = CatalogPosition(epoch: "e1", rev: 0)

    @Test func aRecordedIdIsAnsweredWithItsNewestReceipt() {
        var table = CatalogOperationTable()
        table.record(CatalogReceipt(opID: "a", epoch: "e1", outcome: .applied), at: here)
        table.record(CatalogReceipt(opID: "b", epoch: "e1", outcome: .noop), at: here)

        table.record(CatalogReceipt(opID: "a", epoch: "e1", outcome: .applied, rev: 4), at: here)

        #expect(table.receipt("a") == CatalogReceipt(opID: "a", epoch: "e1", outcome: .applied, rev: 4))
        #expect(table.entries.map(\.opID) == ["b", "a"])
        #expect(table.receipt("c") == nil)
    }

    @Test func theTableKeepsOnlyTheNewestEntries() {
        var table = CatalogOperationTable()

        for index in 0..<(CatalogOperationTable.capacity + 3) {
            table.record(CatalogReceipt(opID: "op\(index)", epoch: "e1", outcome: .noop), at: here)
        }

        #expect(table.entries.count == CatalogOperationTable.capacity)
        #expect(table.receipt("op0") == nil)
        #expect(table.receipt("op2") == nil)
        #expect(table.receipt("op3") != nil)
    }

    @Test func aDropMarksWhereTheCatalogStood() {
        var table = CatalogOperationTable()
        for index in 0..<CatalogOperationTable.capacity {
            table.record(CatalogReceipt(opID: "op\(index)", epoch: "e1", outcome: .noop), at: CatalogPosition(epoch: "e1", rev: 1))
        }
        #expect(table.lastDrop == nil)

        table.record(CatalogReceipt(opID: "over", epoch: "e1", outcome: .noop), at: CatalogPosition(epoch: "e1", rev: 7))

        #expect(table.lastDrop == CatalogPosition(epoch: "e1", rev: 7))
    }

    @Test(arguments: [
        (nil, CatalogPosition(epoch: "e1", rev: 3), false),
        (CatalogPosition(epoch: "e1", rev: 7), CatalogPosition(epoch: "e1", rev: 8), false),
        (CatalogPosition(epoch: "e1", rev: 7), CatalogPosition(epoch: "e1", rev: 7), true),
        (CatalogPosition(epoch: "e1", rev: 7), CatalogPosition(epoch: "e1", rev: 2), true),
        (CatalogPosition(epoch: "e2", rev: 0), CatalogPosition(epoch: "e1", rev: 9), true),
        (CatalogPosition(epoch: "e1", rev: 7), nil, true),
    ] as [(CatalogPosition?, CatalogPosition?, Bool)])
    func aDropCoversAnOperationSentAtOrBeforeIt(_ drop: CatalogPosition?, _ sent: CatalogPosition?, _ covered: Bool) {
        var table = CatalogOperationTable()
        if let drop {
            for index in 0...CatalogOperationTable.capacity {
                table.record(CatalogReceipt(opID: "op\(index)", epoch: drop.epoch, outcome: .noop), at: drop)
            }
        }

        #expect(table.mayHaveDropped(since: sent) == covered)
    }

    @Test func adoptingMovesOnlyAnEarlierEpochsAppliedEntries() {
        var table = CatalogOperationTable()
        table.record(CatalogReceipt(opID: "done", epoch: "old", outcome: .applied, rev: 9), at: here)
        table.record(CatalogReceipt(opID: "marker", epoch: "old", outcome: .applied), at: here)
        table.record(CatalogReceipt(opID: "same", epoch: "new", outcome: .applied, rev: 2), at: here)
        table.record(CatalogReceipt(opID: "noop", epoch: "old", outcome: .noop), at: here)
        table.record(CatalogReceipt(opID: "fence", epoch: "old", outcome: .fenced), at: here)

        table.adopt(epoch: "new", rev: 0)

        #expect(table.receipt("done") == CatalogReceipt(opID: "done", epoch: "new", outcome: .applied, rev: 0))
        #expect(table.receipt("marker") == CatalogReceipt(opID: "marker", epoch: "new", outcome: .applied, rev: 0))
        #expect(table.receipt("same")?.rev == 2)
        #expect(table.receipt("noop")?.epoch == "old")
        #expect(table.receipt("fence")?.epoch == "old")
    }

    @Test(arguments: [("a1", true), ("op.2:b_c-d", true), (String(repeating: "x", count: 128), true), ("", false),
                      (String(repeating: "x", count: 129), false), ("a b", false), ("a\u{1B}[31m", false), ("é", false)])
    func anOperationIdIsShortAndPlain(_ opID: String, _ valid: Bool) {
        #expect(CatalogReceipt.isValidOpID(opID) == valid)
    }

    @Test func theTableIsSavedAndRestoredWithTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-ops-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(persistence: PersistenceStore(directory: directory), paneFinalizer: nil, headless: true)
        var table = CatalogOperationTable()
        table.record(CatalogReceipt(opID: "a", epoch: "e1", outcome: .applied, rev: 3), at: here)
        store.catalogOperations = table

        #expect(store.saveChecked())
        let restored = AppStore(persistence: PersistenceStore(directory: directory), paneFinalizer: nil, headless: true)
        restored.restore(from: try PersistenceStore(directory: directory).loadChecked())

        #expect(restored.catalogOperations == table)
    }

    @Test func aMacStoreWritesNoTable() throws {
        let snapshot = AppStore(persistence: PersistenceStore(directory: FileManager.default.temporaryDirectory), paneFinalizer: nil)
            .snapshot()

        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        #expect(!json.contains("catalogOperations"))
    }

    @Test func aMalformedTableDecodesAsNoneAndKeepsTheCatalog() throws {
        let json = #"{"version":1,"workspaces":[],"catalogOperations":{"entries":"nope"}}"#

        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))

        #expect(snapshot.catalogOperations == nil)
        #expect(snapshot.workspaces.isEmpty)
    }

    @Test func aMacAppRefusesAnOperationIdOnAnyCommand() async {
        let request = ControlRequest(cmd: .sessionNew, args: { var args = ControlArgs(); args.opID = "a"; args.epoch = "e1"; return args }())

        let response = await ControlDispatcher(actions: MockControlActions()).dispatch(request)

        #expect(response?.error == "operation receipts are served only by agterm-server")
    }

    @Test func aMacAppRefusesCatalogOp() async {
        let response = await ControlDispatcher(actions: MockControlActions()).dispatch(ControlRequest(cmd: .catalogOp, target: "a"))

        #expect(response?.error == "catalog.op is served only by agterm-server")
    }

    @Test(arguments: [nil, "", "a b"])
    func catalogOpRefusesAMissingOrInvalidIdBeforeTheHost(_ opID: String?) async {
        let actions = MockControlActions()

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .catalogOp, target: opID))

        #expect(response?.error == "catalog.op requires an operation id")
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [("e1", nil), (nil, 3)] as [(String?, Int?)])
    func catalogOpTakesEpochAndRevTogether(_ epoch: String?, _ rev: Int?) async {
        let actions = MockControlActions()
        var args = ControlArgs()
        args.epoch = epoch
        args.rev = rev

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .catalogOp, target: "a", args: args))

        #expect(response?.error == "catalog.op takes epoch and rev together")
        #expect(actions.calls.isEmpty)
    }
}
