import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreCompanionMembershipTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var companionFrames: [PresentationCompanions] {
            frames.compactMap { if case .companions(let companions) = $0.body { companions } else { nil } }
        }

        var last: PresentationCompanions? {
            frames.reduce(nil) { last, frame in
                switch frame.body {
                case .snapshot(let snapshot): return snapshot.companions
                case .companions(let companions): return companions
                default: return last
                }
            }
        }
    }

    let hub = PresentationHub(staleTimeout: 30)

    private func origin(headless: Bool = false) throws -> (store: AppStore, workspace: UUID, parent: Session) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir), paneFinalizer: nil, headless: headless)
        store.presentationHub = hub
        let workspace = store.addWorkspace(name: "work")
        let parent = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        return (store, workspace.id, parent)
    }

    @discardableResult
    private func viewer(of session: Session, in store: AppStore) throws -> Sink {
        let sink = Sink()
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: [PresentationHub.companionsKind], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: session.id) }
        return sink
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func members(_ sessions: [Session]) -> PresentationCompanions {
        PresentationCompanions(members: sessions.map {
            PresentationCompanions.Member(id: $0.id, kind: $0.content == .page ? .page : .terminal)
        })
    }

    @Test func theSnapshotListsTheCompanionsInOrderWithTheirKinds() throws {
        let (store, _, parent) = try origin()
        let shell = try store.addCompanion(to: parent.id).get()
        let page = try store.addPageCompanion(to: parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()

        let sink = try viewer(of: parent, in: store)

        #expect(sink.last == members([shell, page]))
        #expect(sink.last?.members.map(\.kind) == [.terminal, .page])
    }

    @Test(arguments: [false, true])
    func aSessionWithNoCompanionsListsNoneAndANewOneFollowsOnTheNextMainTurn(headless: Bool) async throws {
        let (store, _, parent) = try origin(headless: headless)
        let sink = try viewer(of: parent, in: store)
        #expect(sink.last == members([]))

        let shell = try store.addCompanion(to: parent.id).get()
        #expect(sink.companionFrames.isEmpty)
        await nextMainTurn()

        #expect(sink.companionFrames == [members([shell])])
    }

    @Test func aPageCompanionFollowsAsAPage() async throws {
        let (store, _, parent) = try origin()
        let sink = try viewer(of: parent, in: store)

        let page = try store.addPageCompanion(to: parent.id, overlay: HtmlOverlay(source: .file(path: "/tmp/p.html", grantRoot: nil))).get()
        await nextMainTurn()

        #expect(sink.companionFrames == [members([page])])
    }

    @Test func aMoveRepublishesBothParentsAndAReorderTheNewOrder() async throws {
        let (store, workspace, parent) = try origin()
        let other = try #require(store.addSession(toWorkspace: workspace, cwd: "/tmp"))
        let first = try store.addCompanion(to: parent.id).get()
        let second = try store.addCompanion(to: parent.id).get()
        let fromSink = try viewer(of: parent, in: store)
        let toSink = try viewer(of: other, in: store)

        try store.moveCompanion(first.id, under: other.id).get()
        await nextMainTurn()
        #expect(fromSink.last == members([second]))
        #expect(toSink.last == members([first]))

        let third = try store.addCompanion(to: other.id).get()
        await nextMainTurn()
        store.reorderSession(third.id, .up)
        await nextMainTurn()
        #expect(toSink.last == members([third, first]))
    }

    @Test func convertingASessionEmptiesItsOwnList() async throws {
        let (store, _, parent) = try origin()
        let shell = try store.addCompanion(to: parent.id).get()
        let sink = try viewer(of: parent, in: store)
        #expect(sink.last == members([shell]))

        _ = try store.convertToCompanion(parent.id).get()
        await nextMainTurn()

        #expect(sink.companionFrames == [members([])])
    }

    @Test func aCloseRemovesTheMember() async throws {
        let (store, _, parent) = try origin()
        let shell = try store.addCompanion(to: parent.id).get()
        let sink = try viewer(of: parent, in: store)

        _ = store.closeSession(shell.id)
        await nextMainTurn()

        #expect(sink.companionFrames == [members([])])
    }

    @Test func aSoftCloseRemovesTheMemberUndoBringsItBackAndFinalizingSendsNothingMore() async throws {
        let (store, _, parent) = try origin()
        let kept = try store.addCompanion(to: parent.id).get()
        let closed = try store.addCompanion(to: parent.id).get()
        let sink = try viewer(of: parent, in: store)

        #expect(store.softCloseSession(closed.id))
        await nextMainTurn()
        #expect(sink.companionFrames == [members([kept])])

        #expect(store.undoPendingClose())
        await nextMainTurn()
        #expect(sink.companionFrames == [members([kept]), members([kept, closed])])

        #expect(store.softCloseSession(closed.id))
        await nextMainTurn()
        store.finalizeAllPendingCloses()
        await nextMainTurn()
        #expect(sink.companionFrames == [members([kept]), members([kept, closed]), members([kept])])
    }

    @Test func aBatchUndoPublishesOnlyTheFinalGrouping() async throws {
        let (store, _, parent) = try origin()
        let first = try store.addCompanion(to: parent.id).get()
        let second = try store.addCompanion(to: parent.id).get()
        let sink = try viewer(of: parent, in: store)
        #expect(store.softCloseSessions([first.id, second.id]))
        await nextMainTurn()

        #expect(store.undoPendingClose())
        await nextMainTurn()

        #expect(sink.companionFrames == [members([]), members([first, second])])
    }

    @Test func aRowShownFromAnotherHostListsNothingAndIsNotListedAsAMember() async throws {
        let (store, workspace, parent) = try origin()
        let foreign = try #require(store.addSession(toWorkspace: workspace, cwd: "/tmp", remoteHost: "mac-b",
                                                    remoteSessionID: UUID().uuidString, parentID: parent.id))
        let attached = try #require(store.addSession(toWorkspace: workspace, cwd: "/tmp", remoteHost: "mac-b",
                                                     remoteSessionID: UUID().uuidString))

        #expect(store.presentationSnapshot(forSession: attached.id).companions == nil)
        #expect(store.companions(of: parent.id).map(\.id) == [foreign.id])
        #expect(try viewer(of: parent, in: store).last == members([]))
    }
}
