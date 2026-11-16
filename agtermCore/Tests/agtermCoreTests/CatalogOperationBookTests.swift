import Foundation
import Testing
@testable import agtermCore

@MainActor
struct CatalogOperationBookTests {
    private final class Host: CatalogOperationHost {
        let store = AppStore(persistence: PersistenceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("agts-book-\(UUID().uuidString)")), paneFinalizer: nil, headless: true)
        lazy var hub = CatalogHub(epoch: "e1", staleTimeout: 30) { [unowned self] in
            CatalogFixture.snapshot(store.workspaces.map { CatalogWorkspace(id: $0.id, name: $0.name, sessions: []) })
        }
        var refusal: String?
        var runs = 0
        var answer: (AppStore) -> ControlResponse = { store in
            store.addWorkspace(name: "w\(store.workspaces.count)")
            return ControlResponse(ok: true)
        }

        var operationStore: AppStore? { store }
        var operationHub: CatalogHub { hub }
        func operationRefusal(_ request: ControlRequest) -> String? { refusal }
        func runOperation(_ request: ControlRequest) async -> ControlResponse {
            runs += 1
            return answer(store)
        }
    }

    private let host = Host()
    private let book = CatalogOperationBook()

    private func request(_ cmd: Command = .workspaceNew, opID: String = "op-1", epoch: String = "e1") -> ControlRequest {
        var args = ControlArgs()
        args.opID = opID
        args.epoch = epoch
        return ControlRequest(cmd: cmd, args: args)
    }

    @Test func anOperationThatChangesTheCatalogIsAppliedAtItsRevision() async {
        let reply = await book.serve(request(), opID: "op-1", host: host)

        #expect(reply.ok)
        #expect(reply.result?.receipt?.outcome == .applied)
        #expect(reply.result?.receipt?.rev == host.hub.rev)
        #expect(host.hub.rev > 0)
    }

    @Test func aRepeatedIdAnswersItsRecordedReceiptWithoutRunningAgain() async {
        let first = await book.serve(request(), opID: "op-1", host: host)
        let second = await book.serve(request(), opID: "op-1", host: host)

        #expect(host.runs == 1)
        #expect(second.result?.receipt == first.result?.receipt)
    }

    @Test func anOperationThatChangesNothingIsANoop() async {
        host.answer = { _ in ControlResponse(ok: true) }

        #expect(await book.serve(request(), opID: "op-1", host: host).result?.receipt?.outcome == .noop)
    }

    @Test func aFailedCommandIsRecordedRefusedWithItsError() async {
        host.answer = { _ in ControlResponse(ok: false, error: "nope") }
        let reply = await book.serve(request(), opID: "op-1", host: host)

        #expect(!reply.ok)
        #expect(reply.result?.receipt?.outcome == .refused)
        #expect(reply.error == "nope")
    }

    @Test func anotherEpochIsRefusedWithoutRunning() async {
        let reply = await book.serve(request(epoch: "e0"), opID: "op-1", host: host)

        #expect(host.runs == 0)
        #expect(reply.result?.receipt?.outcome == .refused)
        #expect(reply.error == "the catalog is at epoch e1; take its snapshot and send the command again")
    }

    @Test func aHostRefusalIsRecordedSoTheIdStaysRefused() async {
        host.refusal = "the session's panes changed; take the catalog again"
        _ = await book.serve(request(), opID: "op-1", host: host)
        host.refusal = nil
        let again = await book.serve(request(), opID: "op-1", host: host)

        #expect(host.runs == 0)
        #expect(again.error == "the session's panes changed; take the catalog again")
    }

    @Test func aCommandWithoutReceiptsIsRefused() async {
        let reply = await book.serve(request(.sessionType), opID: "op-1", host: host)

        #expect(reply.error == "session.type takes no operation id")
        #expect(host.runs == 0)
    }

    @Test func aLookupOfAnUnseenIdFencesIt() async {
        let lookup = book.lookup("op-9", sent: nil, host: host)
        let late = await book.serve(request(opID: "op-9"), opID: "op-9", host: host)

        #expect(lookup.result?.receipt?.outcome == .fenced)
        #expect(host.runs == 0)
        #expect(late.error == "operation op-9 was fenced by a lookup and will not run")
    }

    @Test func aLookupOfARecordedIdAnswersItsReceipt() async {
        let served = await book.serve(request(), opID: "op-1", host: host)

        #expect(book.lookup("op-1", sent: nil, host: host).result?.receipt == served.result?.receipt)
    }
}
