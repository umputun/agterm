import Foundation
import agtermCore

extension ServerActions {
    /// receiptCommands are the served structural commands; any other command refuses an `opID`.
    static let receiptCommands: Set<Command> = [
        .sessionNew, .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionRename, .sessionClose, .sessionMove,
        .sessionCompanionNew, .workspaceNew, .workspaceRename, .workspaceDelete, .workspaceMove,
    ]

    public var takesOperationReceipts: Bool { true }

    /// serveOperation answers a repeated `opID` from the table, refuses another epoch, and otherwise runs the
    /// command once. Its marker is in the table while it runs, so the command's own save records the id.
    func serveOperation(_ request: ControlRequest, opID: String) async -> ControlResponse {
        guard Self.receiptCommands.contains(request.cmd) else {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) takes no operation id")
        }
        guard CatalogReceipt.isValidOpID(opID) else { return ControlResponse(ok: false, error: "invalid operation id") }
        let hub = streams.catalogHub
        var table = store.catalogOperations ?? CatalogOperationTable()
        if let recorded = table.receipt(opID) { return operationsDurable() ? Self.reply(recorded) : Self.unsaved(opID) }
        guard request.args?.epoch == hub.epoch else {
            let error = "the catalog is at epoch \(hub.epoch); take its snapshot and send the command again"
            let refusal = CatalogReceipt(opID: opID, epoch: hub.epoch, outcome: .refused, error: error)
            return save(refusal, into: &table) ? Self.reply(refusal) : Self.unsaved(opID)
        }
        hub.refresh()
        let before = hub.rev
        table.record(CatalogReceipt(opID: opID, epoch: hub.epoch, outcome: .applied))
        store.catalogOperations = table
        let response = await ControlDispatcher(actions: self).dispatch(request)
            ?? ControlResponse(ok: false, error: "\(request.cmd.rawValue) is not available on agterm-server")
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
        table = store.catalogOperations ?? table
        guard save(receipt, into: &table) else { return Self.unsaved(opID) }
        var reply = response
        var result = reply.result ?? ControlResult()
        result.receipt = receipt
        reply.result = result
        return reply
    }

    /// catalogOperation answers a lookup from the table. An id the server has not seen is fenced, so the command
    /// arriving late is refused rather than run after the caller gave up on it.
    public func catalogOperation(_ opID: String) -> ControlResponse {
        var table = store.catalogOperations ?? CatalogOperationTable()
        if let recorded = table.receipt(opID) {
            guard operationsDurable() else { return Self.unsaved(opID) }
            return ControlResponse(ok: true, result: Self.result(recorded))
        }
        let fence = CatalogReceipt(opID: opID, epoch: streams.catalogHub.epoch, outcome: .fenced)
        guard save(fence, into: &table) else { return ControlResponse(ok: false, error: "could not save the fence for operation \(opID)") }
        return ControlResponse(ok: true, result: Self.result(fence))
    }

    /// save records `receipt` and writes it. A failed write leaves it in memory, so this run still answers the id
    /// the same way, but the caller is told nothing durable was kept.
    private func save(_ receipt: CatalogReceipt, into table: inout CatalogOperationTable) -> Bool {
        table.record(receipt)
        store.catalogOperations = table
        operationsUnsaved = !store.saveChecked()
        return !operationsUnsaved
    }

    /// operationsDurable is whether the table on disk holds what memory does, retrying a write that failed: an
    /// entry only memory holds is never handed out as a receipt, since a restart would lose it.
    private func operationsDurable() -> Bool {
        if operationsUnsaved { operationsUnsaved = !store.saveChecked() }
        return !operationsUnsaved
    }

    private static func unsaved(_ opID: String) -> ControlResponse {
        ControlResponse(ok: false, error: "the receipt for operation \(opID) could not be saved; ask catalog.op for it")
    }

    /// reply is a receipt's answer: ok unless the operation was refused or fenced.
    private static func reply(_ receipt: CatalogReceipt) -> ControlResponse {
        switch receipt.outcome {
        case .applied, .noop: return ControlResponse(ok: true, result: Self.result(receipt))
        case .refused: return ControlResponse(ok: false, result: Self.result(receipt), error: receipt.error)
        case .fenced:
            return ControlResponse(ok: false, result: Self.result(receipt),
                                   error: "operation \(receipt.opID) was fenced by a lookup and will not run")
        }
    }

    private static func result(_ receipt: CatalogReceipt) -> ControlResult {
        var result = ControlResult()
        result.receipt = receipt
        return result
    }
}
