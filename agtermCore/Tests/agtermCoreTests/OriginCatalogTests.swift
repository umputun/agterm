import Foundation
import Testing
@testable import agtermCore

@MainActor
final class OriginCatalogTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
    private lazy var library = WindowLibrary(directory: directory)
    private lazy var window = library.newWindow().id
    private lazy var store = library.store(for: window)!
    private var saved: PersistenceStore {
        PersistenceStore(directory: directory.appendingPathComponent("windows"), fileName: "\(window.uuidString).json")
    }
    private var ran: [ControlRequest] = []
    private lazy var catalog = OriginCatalog(window: window, options: OriginCatalog.Options(
        epoch: "e1", staleTimeout: 30, shape: CatalogProjection(endpoint: CatalogFixture.endpoint, mail: { _ in nil }),
        versions: CatalogFixture.versions, recent: { _ in [] }, schedule: { _ in }))
    private var session: Session!

    init() throws {
        let seeded = store.workspaces.map(\.id)
        let workspace = store.addWorkspace(name: "work")
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/w"))
        seeded.forEach(store.removeWorkspace)
        catalog.projection.evidence = CatalogPaneEvidence(running: [session.paneIdentity])
        catalog.bind(store)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func serve(_ cmd: Command, target: String?, opID: String = "op-1", edit: (inout ControlArgs) -> Void = { _ in }) async
        -> ControlResponse {
        var args = ControlArgs()
        args.opID = opID
        args.epoch = catalog.hub.epoch
        edit(&args)
        let host = catalog.operation(in: library) { [unowned self] request in
            ran.append(request)
            if request.cmd == .sessionRename, let id = request.target.flatMap(UUID.init(uuidString:)) {
                store.renameSession(id, to: request.args?.name ?? "")
            }
            return ControlResponse(ok: true)
        }
        return await catalog.book.serve(ControlRequest(cmd: cmd, target: target, args: args), opID: opID, host: host)
    }

    // an operation resuming after its window reopened once saved the closed store over the new one's file
    @Test func anOperationResumingAfterAReopenSavesThroughTheReopenedStore() async throws {
        let (pending, resume) = try await suspendedRename()

        library.closeWindow(window)
        let reopened = try #require(library.loadStore(for: window))
        _ = reopened.addWorkspace(name: "edited after reopen")
        resume()
        let response = await pending.value

        #expect(response.ok)
        let file = saved.load()
        #expect(file.workspaces.filter { $0.root != true }.map(\.name) == ["work", "edited after reopen"])
        #expect(file.catalogOperations?.receipt("op-1") == response.result?.receipt)
        #expect(reopened.catalogOperations?.receipt("op-1") == response.result?.receipt)
    }

    // an operation finishing while its window was closed left the in-progress marker as its answer after a reopen
    @Test func anOperationFinishingWhileItsWindowIsClosedIsAnsweredAfterTheReopen() async throws {
        let (pending, resume) = try await suspendedRename()
        library.closeWindow(window)
        resume()
        let response = await pending.value
        #expect(!response.ok)

        let reopened = try #require(library.loadStore(for: window))
        let lookup = catalog.book.lookup("op-1", sent: nil, host: catalog.operation(in: library) { _ in ControlResponse(ok: true) })

        let receipt = try #require(lookup.result?.receipt)
        #expect(receipt.outcome == .applied)
        #expect(receipt.rev != nil)
        #expect(reopened.catalogOperations?.receipt("op-1") == receipt)
        #expect(saved.load().catalogOperations?.receipt("op-1") == receipt)
    }

    @Test func anOperationResumingAfterItsWindowWasDeletedSavesNothing() async throws {
        _ = library.newWindow()
        let (pending, resume) = try await suspendedRename()

        library.removeWindow(window)
        resume()
        let response = await pending.value

        #expect(!response.ok)
        #expect(!FileManager.default.fileExists(atPath: saved.fileURL.path))
    }

    @Test func anOperationOnAClosedWindowIsRefusedWithoutRunning() async {
        library.closeWindow(window)

        let response = await serve(.sessionRename, target: session.id.uuidString) { $0.name = "renamed" }

        #expect(response.error == "the catalog's window is closed")
        #expect(ran.isEmpty)
    }

    private func suspendedRename() async throws -> (Task<ControlResponse, Never>, () -> Void) {
        var gate: CheckedContinuation<Void, Never>?
        let host = catalog.operation(in: library) { [unowned self] request in
            store.renameSession(session.id, to: request.args?.name ?? "")
            await withCheckedContinuation { gate = $0 }
            return ControlResponse(ok: true)
        }
        var args = ControlArgs()
        (args.opID, args.epoch, args.name) = ("op-1", catalog.hub.epoch, "renamed")
        let request = ControlRequest(cmd: .sessionRename, target: session.id.uuidString, args: args)
        let pending = Task { await catalog.book.serve(request, opID: "op-1", host: host) }
        while gate == nil { await Task.yield() }
        return (pending, { gate?.resume() })
    }

    @Test func aBoundWindowPublishesItsRows() {
        #expect(catalog.hub.snapshot().workspaces.first?.sessions.map(\.id) == [session.id])
        #expect(catalog.hub.snapshot().catalogID == window)
    }

    @Test func anOperationRunsAgainstItsWindowWithoutReceiptFields() async throws {
        let response = await serve(.sessionRename, target: session.id.uuidString) { $0.name = "renamed" }

        #expect(response.ok)
        #expect(response.result?.receipt?.outcome == .applied)
        let request = try #require(ran.first)
        #expect(request.args?.window == window.uuidString)
        #expect(request.args?.opID == nil)
        #expect(request.args?.epoch == nil)
    }

    @Test func aRepeatedOperationAnswersItsReceiptWithoutRunningAgain() async {
        _ = await serve(.sessionRename, target: session.id.uuidString) { $0.name = "renamed" }
        let again = await serve(.sessionRename, target: session.id.uuidString) { $0.name = "renamed" }

        #expect(again.result?.receipt?.outcome == .applied)
        #expect(ran.count == 1)
    }

    @Test func anOperationOutsideTheWindowIsRefusedAndRecorded() async {
        let response = await serve(.sessionRename, target: UUID().uuidString)

        #expect(!response.ok)
        #expect(response.result?.receipt?.outcome == .refused)
        #expect(ran.isEmpty)
    }

    @Test func anOperationDecidedOnOtherPanesIsRefused() async {
        let response = await serve(.sessionSwap, target: session.id.uuidString) { $0.panes = [UUID().uuidString] }

        #expect(response.error == "the session's panes changed; take the catalog again")
    }

    @Test func aHeldPaneStillCountsAsTheRowsPane() async {
        catalog.projection.evidence = CatalogPaneEvidence()
        let response = await serve(.sessionRestart, target: session.id.uuidString) { $0.panes = [self.session.paneIdentity.uuidString] }

        #expect(response.ok)
    }

    @Test func aScratchOperationDecidedOnAStoppedScratchIsRefused() async {
        session.scratchDaemon = Session.ScratchDaemon(identity: UUID(), shown: false)

        #expect(await serve(.sessionScratch, target: session.id.uuidString) { $0.scratch = "none" }.ok)
        let running = await serve(.sessionScratch, target: session.id.uuidString, opID: "op-2") {
            $0.scratch = UUID().uuidString
        }
        #expect(running.error == "the session's scratch changed; take the catalog again")
    }

    @Test func aReopenedWindowKeepsItsReceiptsAndPublishesAgain() async throws {
        _ = await serve(.sessionRename, target: session.id.uuidString) { $0.name = "renamed" }
        catalog.bind(nil)
        library.closeWindow(window)
        let reopened = try #require(library.loadStore(for: window))

        catalog.bind(reopened)

        #expect(reopened.catalogOperations?.receipt("op-1")?.outcome == .applied)
        #expect(catalog.hub.snapshot().workspaces.first?.sessions.first?.fields.name == "renamed")
    }
}
