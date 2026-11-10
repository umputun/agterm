import Foundation
import Testing
@testable import agtermCore

@MainActor
struct SessionPickTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []
        var refusesDismissal = false

        func offer(_ frame: PresentationFrame) -> Bool {
            if refusesDismissal, case .pickDismiss = frame.body { return false }
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }
    }

    static let items = [ControlPickItem(id: "a", label: "Alpha"), ControlPickItem(id: "b", label: "Beta")]

    let book = SessionPickBook.shared
    let store = makeStore()
    let hub = PresentationHub(staleTimeout: 30)
    let presenter = Sink()

    private func pick(allowCustom: Bool = false) -> PendingPick {
        PendingPick(id: UUID().uuidString, items: Self.items, allowCustom: allowCustom)
    }

    private func window() -> (WindowInfo.ID, PickController) {
        let id = UUID()
        let controller = PickController()
        PickRegistry.shared.register(id, controller: controller)
        return (id, controller)
    }

    private func session() throws -> Session {
        let workspace = store.addWorkspace(name: "work")
        return try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
    }

    @discardableResult
    private func presented(_ session: Session, kinds: [String] = PresentationHub.pickKinds) throws -> PresentationHub.SubscriberID {
        store.presentationHub = hub
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: session.paneIdentity)
        let notice = try #require(ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):follower:1"))
        _ = ZmxLeadBook.shared.apply(notice, pane: session.paneIdentity)
        let hello = PresentationHello(version: 1, kinds: kinds, mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        return id
    }

    private func owner(of session: Session) -> Int { hub.presenterGeneration(session: session.id) }

    @Test(arguments: [
        ("a", nil, ControlPickResult(result: .picked, id: "a", label: "Alpha", index: 0)),
        (nil, nil, ControlPickResult(result: .cancelled)),
        (nil, "free text", ControlPickResult(result: .custom, query: "free text")),
    ] as [(String?, String?, ControlPickResult)])
    func anAnswerIsReadAgainstTheStoredItems(item: String?, query: String?, expected: ControlPickResult) {
        #expect(pick(allowCustom: true).validatedResult(item: item, query: query) == expected)
    }

    @Test(arguments: [("zzz", nil), (nil, "text"), ("a", "text")] as [(String?, String?)])
    func anAnswerThePickCannotProduceIsRefused(item: String?, query: String?) {
        #expect(pick().validatedResult(item: item, query: query) == nil)
    }

    @Test func aLocalPickAnsweredWithNoPollFreesTheSessionForTheNextOne() throws {
        let session = try session()
        let (windowID, controller) = window()
        let first = pick()

        #expect(book.openLocal(first, session: session.id, window: windowID, controller: controller) == nil)
        #expect(book.node(forSession: session.id) == ControlSessionPick(id: first.id))
        controller.resolve(ControlPickResult(result: .picked, id: "b", label: "Beta", index: 1))

        #expect(book.placement(forSession: session.id) == nil)
        #expect(book.result(for: first.id) == ControlPickResult(result: .picked, id: "b", label: "Beta", index: 1))
        #expect(book.openLocal(pick(), session: session.id, window: windowID, controller: controller) == nil)
    }

    @Test func aSecondPickOnTheSameSessionIsRefused() throws {
        let session = try session()
        let (windowID, controller) = window()
        let (otherID, other) = window()
        #expect(book.openLocal(pick(), session: session.id, window: windowID, controller: controller) == nil)

        #expect(book.openLocal(pick(), session: session.id, window: otherID, controller: other) == "pick already pending")
        #expect(other.pending == nil)
    }

    @Test func aWindowHoldingAnAskRefusesTheLocalPick() throws {
        let session = try session()
        let (windowID, controller) = window()
        controller.openAsk(PendingAsk(id: UUID().uuidString, title: "t", buttons: [ControlAskButton(id: "ok", label: "OK")],
                                      style: .gui))

        #expect(book.openLocal(pick(), session: session.id, window: windowID, controller: controller) == "ask already pending")
        #expect(book.placement(forSession: session.id) == nil)
    }

    @Test func cancellingALocalPickEndsItInItsWindow() throws {
        let session = try session()
        let (windowID, controller) = window()
        let local = pick()
        _ = book.openLocal(local, session: session.id, window: windowID, controller: controller)

        #expect(book.cancel(local.id))

        #expect(controller.pending == nil)
        #expect(book.result(for: local.id) == ControlPickResult(result: .cancelled))
        #expect(book.cancel(local.id), "cancelling a finished pick is a no-op success")
        #expect(!book.cancel(UUID().uuidString))
    }

    @Test func closingTheWindowCancelsTheLocalPickAndKeepsItReadable() throws {
        let session = try session()
        let (windowID, controller) = window()
        let local = pick()
        _ = book.openLocal(local, session: session.id, window: windowID, controller: controller)

        PickRegistry.shared.unregister(windowID)

        #expect(book.result(for: local.id) == ControlPickResult(result: .cancelled))
        #expect(book.node(forSession: session.id) == nil)
    }

    @Test func theSessionLeavingCancelsItsPick() throws {
        let session = try session()
        let (windowID, controller) = window()
        let local = pick()
        _ = book.openLocal(local, session: session.id, window: windowID, controller: controller)

        store.closeSession(session.id)

        #expect(controller.pending == nil)
        #expect(book.result(for: local.id) == ControlPickResult(result: .cancelled))
    }

    @Test func aPresentedSessionHandsThePickToItsPresenter() throws {
        let session = try session()
        try presented(session)
        let remote = pick()

        #expect(store.presentPickRemotely(remote, in: session, window: nil) == true)

        #expect(presenter.bodies.last == .pickRequest(PresentationPick(remote, owner: owner(of: session))))
        #expect(book.node(forSession: session.id) == ControlSessionPick(id: remote.id, remote: true))
        #expect(book.result(for: remote.id) == ControlPickResult(result: .pending))
        #expect(store.presentPickRemotely(pick(), in: session, window: nil) == false)
    }

    @Test func aPresenterWithoutThePickKindsKeepsThePickLocal() throws {
        let session = try session()
        try presented(session, kinds: ["status"])

        #expect(store.presentPickRemotely(pick(), in: session, window: nil) == nil)
        #expect(book.placement(forSession: session.id) == nil)
    }

    @Test func aMacSessionNotFollowingKeepsThePickLocal() throws {
        let session = try session()
        try presented(session)
        ZmxLeadBook.shared.forget(pane: session.paneIdentity)

        #expect(store.presentPickRemotely(pick(), in: session, window: nil) == nil)
    }

    @Test func aHeadlessOriginHandsThePickOverWithNoFollowingPane() throws {
        let (headless, session) = makeHeadlessSession(split: false)
        headless.presentationHub = hub
        let hello = PresentationHello(version: 1, kinds: PresentationHub.pickKinds, mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)

        #expect(headless.presentPickRemotely(pick(), in: session, window: nil) == true)
    }

    @Test func thePresentersAnswerResolvesUnderItsOwnerOnly() throws {
        let session = try session()
        try presented(session)
        let remote = pick()
        _ = store.presentPickRemotely(remote, in: session, window: nil)
        let owner = owner(of: session)

        #expect(!book.resolveRemote(PresentationPickAnswer(id: remote.id, owner: owner + 1, item: "a"), session: session.id))
        #expect(!book.resolveRemote(PresentationPickAnswer(id: remote.id, owner: owner, item: "zzz"), session: session.id))
        #expect(book.resolveRemote(PresentationPickAnswer(id: remote.id, owner: owner, item: "b"), session: session.id))

        #expect(book.result(for: remote.id) == ControlPickResult(result: .picked, id: "b", label: "Beta", index: 1))
        #expect(book.node(forSession: session.id) == nil)
    }

    @Test func cancellingAPresentedPickDismissesItOnThePresenter() throws {
        let session = try session()
        try presented(session)
        let remote = pick()
        _ = store.presentPickRemotely(remote, in: session, window: nil)

        #expect(book.cancel(remote.id))

        #expect(presenter.bodies.last == .pickDismiss(PresentationPickRef(id: remote.id, owner: owner(of: session))))
        #expect(book.result(for: remote.id) == ControlPickResult(result: .cancelled))
    }

    @Test func aRefusedPickMovesIntoTheSessionsWindow() throws {
        let session = try session()
        try presented(session)
        let (windowID, controller) = window()
        let remote = pick()
        _ = store.presentPickRemotely(remote, in: session, window: nil)

        book.handBack(session: session.id, refused: PresentationPickRef(id: remote.id, owner: owner(of: session) + 1),
                      to: controller, window: windowID)
        #expect(controller.pending == nil, "a refusal under another owner takes nothing back")
        book.handBack(session: session.id, refused: PresentationPickRef(id: remote.id, owner: owner(of: session)),
                      to: controller, window: windowID)

        #expect(controller.pending == remote)
        #expect(book.node(forSession: session.id) == ControlSessionPick(id: remote.id))
        controller.resolve(ControlPickResult(result: .picked, id: "a", label: "Alpha", index: 0))
        #expect(book.result(for: remote.id) == ControlPickResult(result: .picked, id: "a", label: "Alpha", index: 0))
    }

    @Test(arguments: [true, false])
    func aHandbackIntoAnOccupiedWindowCancelsAndLeavesTheOtherModal(lost: Bool) throws {
        let session = try session()
        let subscriber = try presented(session)
        let (windowID, controller) = window()
        let unrelated = pick()
        controller.open(unrelated)
        let remote = pick()
        _ = store.presentPickRemotely(remote, in: session, window: nil)

        if lost {
            hub.unsubscribe(subscriber)
            book.handBack(session: session.id, to: controller, window: windowID)
        } else {
            book.handBack(session: session.id, refused: PresentationPickRef(id: remote.id, owner: owner(of: session)),
                      to: controller, window: windowID)
        }

        #expect(controller.pending == unrelated)
        #expect(book.result(for: remote.id) == ControlPickResult(result: .cancelled))
    }

    @Test func aStaleRefusalUnderTheSameOwnerLeavesTheNewerPick() throws {
        let session = try session()
        try presented(session)
        let (windowID, controller) = window()
        let first = pick()
        _ = store.presentPickRemotely(first, in: session, window: windowID)
        book.cancel(first.id)
        let second = pick()
        _ = store.presentPickRemotely(second, in: session, window: windowID)

        book.handBack(session: session.id, refused: PresentationPickRef(id: first.id, owner: owner(of: session)),
                      to: controller, window: windowID)

        #expect(controller.pending == nil)
        #expect(book.node(forSession: session.id) == ControlSessionPick(id: second.id, remote: true))
    }

    @Test func aDismissalThatDropsThePresenterLeavesNoPickerBehind() throws {
        let session = try session()
        try presented(session)
        let (windowID, controller) = window()
        hub.onPresenterLost = { [book] lost in book.handBack(session: lost, to: controller, window: windowID) }
        let remote = pick()
        _ = store.presentPickRemotely(remote, in: session, window: windowID)
        presenter.refusesDismissal = true

        #expect(book.cancel(remote.id))

        #expect(!hub.hasPresenter(session: session.id))
        #expect(controller.pending == nil)
        #expect(book.result(for: remote.id) == ControlPickResult(result: .cancelled))
    }

    @Test func aPickKeepsItsOwningWindowAfterItEnds() throws {
        let session = try session()
        try presented(session)
        let (windowID, _) = window()
        let remote = pick()
        _ = store.presentPickRemotely(remote, in: session, window: windowID)

        #expect(book.window(of: remote.id) == windowID)
        book.cancel(remote.id)
        #expect(book.window(of: remote.id) == windowID)
        #expect(book.window(of: UUID().uuidString) == nil)
    }

    @Test(arguments: [true, false])
    func theRequestCarriesFollow(follow: Bool) throws {
        let session = try session()
        try presented(session)
        let remote = pick()

        _ = store.presentPickRemotely(remote, in: session, window: nil, follow: follow)

        guard case .pickRequest(let request)? = presenter.bodies.last else {
            Issue.record("expected a pick request")
            return
        }
        #expect(request.follow == (follow ? true : nil))
    }

    @Test func aHeadlessHandbackWithNoWindowCancels() throws {
        let session = try session()
        try presented(session)
        let remote = pick()
        _ = store.presentPickRemotely(remote, in: session, window: nil)

        book.handBack(session: session.id, to: nil, window: nil)

        #expect(book.result(for: remote.id) == ControlPickResult(result: .cancelled))
    }

    private func replica(owner: Int = 4) -> PresentationPick { PresentationPick(pick(allowCustom: true), owner: owner) }

    @Test func aReplicaAnswerGoesBackToTheOrigin() throws {
        let session = try session()
        let (windowID, controller) = window()
        let request = replica()
        var answers: [PresentationFrame.Body] = []

        #expect(book.openReplica(request, session: session.id, window: windowID, controller: controller) { answers.append($0) })
        #expect(book.node(forSession: session.id) == ControlSessionPick(id: request.id, replica: true))
        controller.resolve(ControlPickResult(result: .custom, query: "typed"))

        #expect(answers == [.pickResolve(PresentationPickAnswer(id: request.id, owner: 4, query: "typed"))])
        #expect(book.node(forSession: session.id) == nil)
    }

    @Test func aReplicaInAnOccupiedWindowWaitsAndIsShownWhenTheSlotFrees() throws {
        let session = try session()
        let (windowID, controller) = window()
        let local = pick()
        controller.open(local)
        let request = replica()

        #expect(book.openReplica(request, session: session.id, window: windowID, controller: controller) { _ in })
        #expect(controller.pending == local)
        #expect(book.node(forSession: session.id) == ControlSessionPick(id: request.id, replica: true))
        controller.cancel()

        #expect(controller.pending?.id == request.id)
    }

    @Test func aClosingWindowDetachesItsShownAndQueuedReplicasWithoutAnsweringOrMountingThem() throws {
        let first = try session(), second = try session()
        let (windowID, controller) = window()
        let shown = replica(), waiting = replica()
        var answers: [PresentationFrame.Body] = []
        _ = book.openReplica(shown, session: first.id, window: windowID, controller: controller) { answers.append($0) }
        _ = book.openReplica(waiting, session: second.id, window: windowID, controller: controller) { answers.append($0) }

        PickRegistry.shared.unregister(windowID)

        #expect(answers.isEmpty)
        #expect(controller.pending == nil)
        #expect(book.node(forSession: first.id) == nil)
        #expect(book.node(forSession: second.id) == nil)
    }

    @Test func aLocalPickEndingInItsWindowStillShowsTheQueuedReplica() throws {
        let session = try session()
        let (windowID, controller) = window()
        controller.open(pick())
        let waiting = replica()
        _ = book.openReplica(waiting, session: session.id, window: windowID, controller: controller) { _ in }

        controller.cancel()

        #expect(controller.pending?.id == waiting.id)
    }

    @Test func aQueuedReplicaReadsPendingInItsWindowAndCancelsOnceWithoutTheBlockingPick() throws {
        let session = try session()
        let (windowID, controller) = window()
        let local = pick()
        controller.open(local)
        let waiting = replica()
        var answers: [PresentationFrame.Body] = []
        _ = book.openReplica(waiting, session: session.id, window: windowID, controller: controller) { answers.append($0) }
        #expect(book.result(for: waiting.id) == ControlPickResult(result: .pending))
        #expect(book.window(of: waiting.id) == windowID)

        #expect(book.cancel(waiting.id))
        #expect(book.cancel(waiting.id))
        controller.cancel()

        #expect(answers == [.pickResolve(PresentationPickAnswer(id: waiting.id, owner: 4, result: ControlPickResult(result: .cancelled)))])
        #expect(book.result(for: waiting.id) == ControlPickResult(result: .cancelled))
        #expect(controller.pending == nil)
        #expect(book.node(forSession: session.id) == nil)
    }

    @Test func twoQueuedReplicasAreShownInOrderAsEachIsAnswered() throws {
        let first = try session(), second = try session()
        let (windowID, controller) = window()
        controller.openAsk(PendingAsk(id: UUID().uuidString, title: "local", buttons: [ControlAskButton(id: "ok", label: "OK")], style: .gui))
        let one = replica(), two = replica()
        var answers: [PresentationFrame.Body] = []
        _ = book.openReplica(one, session: first.id, window: windowID, controller: controller) { answers.append($0) }
        _ = book.openReplica(two, session: second.id, window: windowID, controller: controller) { answers.append($0) }

        controller.cancelAsk()
        #expect(controller.pending?.id == one.id)
        controller.resolve(ControlPickResult(result: .custom, query: "x"))

        #expect(controller.pending?.id == two.id)
        #expect(answers == [.pickResolve(PresentationPickAnswer(id: one.id, owner: 4, query: "x"))])
    }

    @Test func aQueuedReplicaDismissedOrDroppedIsNeverShown() throws {
        let first = try session(), second = try session()
        let (windowID, controller) = window()
        controller.open(pick())
        let dismissed = replica(), dropped = replica()
        _ = book.openReplica(dismissed, session: first.id, window: windowID, controller: controller) { _ in }
        _ = book.openReplica(dropped, session: second.id, window: windowID, controller: controller) { _ in }

        book.dismissReplica(PresentationPickRef(id: dismissed.id, owner: 4), session: first.id)
        book.dropReplicas(forSession: second.id)
        controller.cancel()

        #expect(controller.pending == nil)
        #expect(book.node(forSession: first.id) == nil)
    }

    @Test func theOriginsDismissalClosesTheReplicaWithoutAnswering() throws {
        let session = try session()
        let (windowID, controller) = window()
        let request = replica()
        var answers: [PresentationFrame.Body] = []
        _ = book.openReplica(request, session: session.id, window: windowID, controller: controller) { answers.append($0) }

        book.dismissReplica(PresentationPickRef(id: request.id, owner: 3), session: session.id)
        #expect(controller.pending?.id == request.id, "a dismissal under another owner is ignored")
        book.dismissReplica(PresentationPickRef(id: request.id, owner: 4), session: session.id)

        #expect(controller.pending == nil)
        #expect(answers.isEmpty)
    }

    @Test func losingTheStreamClosesTheReplicaAndALateDismissalSparesTheNextOne() throws {
        let session = try session()
        let (windowID, controller) = window()
        let first = replica(owner: 4)
        var answers: [PresentationFrame.Body] = []
        _ = book.openReplica(first, session: session.id, window: windowID, controller: controller) { answers.append($0) }

        book.dropReplicas(forSession: session.id)
        #expect(controller.pending == nil)
        #expect(book.node(forSession: session.id) == nil)
        let second = replica(owner: 5)
        #expect(book.openReplica(second, session: session.id, window: windowID, controller: controller) { answers.append($0) })
        book.dismissReplica(PresentationPickRef(id: first.id, owner: 4), session: session.id)

        #expect(controller.pending?.id == second.id)
        #expect(answers.isEmpty)
    }

    @Test func aRowsStreamLeavingConnectedDropsItsReplica() throws {
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin", daemonsByLocalPane: [
            session.paneIdentity: ZmxSupport.daemonName(for: UUID()),
        ], presentationVersion: 1), forSession: session.id)
        store.setRemoteConnection(.connected, forSession: session.id)
        let (windowID, controller) = window()
        _ = book.openReplica(replica(), session: session.id, window: windowID, controller: controller) { _ in }

        store.setRemoteConnection(.failed("gone"), forSession: session.id)

        #expect(controller.pending == nil)
        #expect(book.node(forSession: session.id) == nil)
    }

    @Test func theTreeReportsTheSessionsPick() throws {
        let session = try session()
        let (windowID, controller) = window()
        let local = pick()
        _ = book.openLocal(local, session: session.id, window: windowID, controller: controller)

        let node = store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }

        #expect(node?.pick == ControlSessionPick(id: local.id))
    }
}
