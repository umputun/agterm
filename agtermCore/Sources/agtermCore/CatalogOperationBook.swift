import Foundation

/// CatalogOperationHost is what a catalog's origin lends its operation book: the store holding the table, the hub
/// numbering the catalog, the refusals only the origin can judge, and the command itself.
@MainActor
public protocol CatalogOperationHost: AnyObject {
    /// operationStore holds the table, nil once the catalog's store is gone: nothing is saved then, since another
    /// store may own the file or the file was deleted.
    var operationStore: AppStore? { get }
    var operationHub: CatalogHub { get }
    /// operationRefusal answers why `request` cannot run on the catalog as it stands now, nil when it can.
    func operationRefusal(_ request: ControlRequest) -> String?
    func runOperation(_ request: ControlRequest) async -> ControlResponse
}

/// CatalogOperationBook runs each operation id at most once and answers what became of it, for one catalog:
/// agterm-server's, or one Mac window's.
@MainActor
public final class CatalogOperationBook {
    /// receiptCommands are the structural commands that take an operation id; any other refuses one.
    public static let receiptCommands: Set<Command> = [
        .sessionNew, .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionRename, .sessionClose, .sessionTerminate,
        .sessionMove,
        .sessionCompanionNew, .sessionCompanionPage, .sessionPage, .workspaceNew, .workspaceRename, .workspaceDelete, .workspaceMove, .sessionScratch,
        .sessionFlag, .sessionTint, .workspaceFlag, .workspaceTint,
        .sessionRestart, .sessionCompanionDuplicate, .sessionCompanionConvert, .sessionCompanionMove, .sessionCompanionPromote, .zmxKill, .zmxKillPane,
        .recentOpen, .recentClear, .sessionUndo,
    ]

    // set while the table holds an entry its last write failed to save
    private var unsaved = false
    // operations that finished with no store to save into, recorded into the next store the host has
    private var held: [CatalogReceipt] = []

    public init() {}

    /// serve answers a repeated `opID` from the table, refuses another epoch, and otherwise runs the command once.
    /// Its marker is in the table while it runs, so the command's own save records the id.
    public func serve(_ request: ControlRequest, opID: String, host: any CatalogOperationHost) async -> ControlResponse {
        guard Self.receiptCommands.contains(request.cmd) else {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) takes no operation id")
        }
        guard CatalogReceipt.isValidOpID(opID) else { return ControlResponse(ok: false, error: "invalid operation id") }
        guard let store = host.operationStore else { return Self.gone }
        let hub = host.operationHub
        var table = settleHeld(in: store, host: host)
        if let recorded = table.receipt(opID) { return durable(store) ? Self.reply(recorded) : Self.unsaved(opID) }
        guard request.args?.epoch == hub.epoch else {
            let error = "the catalog is at epoch \(hub.epoch); take its snapshot and send the command again"
            let refusal = CatalogReceipt(opID: opID, epoch: hub.epoch, outcome: .refused, error: error)
            return save(refusal, into: &table, host: host) ? Self.reply(refusal) : Self.unsaved(opID)
        }
        if let refusal = host.operationRefusal(request) {
            let receipt = CatalogReceipt(opID: opID, epoch: hub.epoch, outcome: .refused, error: refusal)
            return save(receipt, into: &table, host: host) ? Self.reply(receipt) : Self.unsaved(opID)
        }
        hub.refresh()
        let before = hub.rev
        table.record(CatalogReceipt(opID: opID, epoch: hub.epoch, outcome: .applied), at: Self.position(hub))
        store.catalogOperations = table
        let response = await host.runOperation(request)
        hub.refresh()
        let receipt: CatalogReceipt
        if !response.ok {
            receipt = CatalogReceipt(opID: opID, epoch: hub.epoch, outcome: .refused, error: response.error)
        } else if hub.rev > before {
            receipt = CatalogReceipt(opID: opID, epoch: hub.epoch, outcome: .applied, rev: hub.rev)
        } else {
            receipt = CatalogReceipt(opID: opID, epoch: hub.epoch, outcome: .noop)
        }
        // another request may have recorded its own operation while this one ran
        guard let current = host.operationStore else {
            held.append(receipt)
            return Self.unsaved(opID)
        }
        table = settleHeld(in: current, host: host)
        guard save(receipt, into: &table, host: host) else { return Self.unsaved(opID) }
        var reply = response
        var result = reply.result ?? ControlResult()
        result.receipt = receipt
        reply.result = result
        return reply
    }

    /// lookup answers `catalog.op` from the table. An id the origin has not seen is fenced, so the command arriving
    /// late is refused rather than run after the caller gave up on it; it is recorded `unknown` instead when a drop
    /// may have taken its entry since `sent`, where the caller sent it.
    public func lookup(_ opID: String, sent: CatalogPosition?, host: any CatalogOperationHost) -> ControlResponse {
        guard let store = host.operationStore else { return Self.gone }
        var table = settleHeld(in: store, host: host)
        if let recorded = table.receipt(opID) {
            guard durable(store) else { return Self.unsaved(opID) }
            return ControlResponse(ok: true, result: Self.result(recorded))
        }
        let outcome: CatalogReceipt.Outcome = table.mayHaveDropped(since: sent) ? .unknown : .fenced
        let fence = CatalogReceipt(opID: opID, epoch: host.operationHub.epoch, outcome: outcome)
        guard save(fence, into: &table, host: host) else {
            return ControlResponse(ok: false, error: "could not save the fence for operation \(opID)")
        }
        return ControlResponse(ok: true, result: Self.result(fence))
    }

    /// save records `receipt` and writes it. A failed write leaves it in memory, so this run still answers the id
    /// the same way, but the caller is told nothing durable was kept.
    private func save(_ receipt: CatalogReceipt, into table: inout CatalogOperationTable, host: any CatalogOperationHost) -> Bool {
        table.record(receipt, at: Self.position(host.operationHub))
        guard let store = host.operationStore else { return false }
        store.catalogOperations = table
        unsaved = !store.saveChecked()
        return !unsaved
    }

    /// settleHeld records the held receipts into `store`'s table, which a failed write leaves for `durable` to retry.
    private func settleHeld(in store: AppStore, host: any CatalogOperationHost) -> CatalogOperationTable {
        var table = store.catalogOperations ?? CatalogOperationTable()
        guard !held.isEmpty else { return table }
        for receipt in held { table.record(receipt, at: Self.position(host.operationHub)) }
        held = []
        store.catalogOperations = table
        unsaved = !store.saveChecked()
        return table
    }

    /// durable is whether the table on disk holds what memory does, retrying a write that failed: an entry only
    /// memory holds is never handed out as a receipt, since a restart would lose it.
    private func durable(_ store: AppStore) -> Bool {
        if unsaved { unsaved = !store.saveChecked() }
        return !unsaved
    }

    private static func position(_ hub: CatalogHub) -> CatalogPosition { CatalogPosition(epoch: hub.epoch, rev: hub.rev) }

    private static let gone = ControlResponse(ok: false, error: "the catalog's window is closed")

    private static func unsaved(_ opID: String) -> ControlResponse {
        ControlResponse(ok: false, error: "the receipt for operation \(opID) could not be saved; ask catalog.op for it")
    }

    /// reply is a receipt's answer: ok unless the operation was refused, fenced or unknown.
    private static func reply(_ receipt: CatalogReceipt) -> ControlResponse {
        switch receipt.outcome {
        case .applied, .noop: return ControlResponse(ok: true, result: Self.result(receipt))
        case .refused: return ControlResponse(ok: false, result: Self.result(receipt), error: receipt.error)
        case .fenced:
            return ControlResponse(ok: false, result: Self.result(receipt),
                                   error: "operation \(receipt.opID) was fenced by a lookup and will not run")
        case .unknown:
            return ControlResponse(ok: false, result: Self.result(receipt),
                                   error: "operation \(receipt.opID) has an unknown outcome and will not run")
        }
    }

    private static func result(_ receipt: CatalogReceipt) -> ControlResult {
        var result = ControlResult()
        result.receipt = receipt
        return result
    }
}
