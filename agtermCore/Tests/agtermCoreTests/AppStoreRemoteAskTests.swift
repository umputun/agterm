import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreRemoteAskTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }
    }

    static let buttons = [ControlAskButton(id: "yes", label: "Yes"), ControlAskButton(id: "no", label: "No")]
    static let window = UUID()

    let store = makeStore()
    let hub = PresentationHub(staleTimeout: 30)
    let presenter = Sink()
    let mirror = Sink()

    private func origin(presented: Bool = true, split: Bool = false) throws -> (Session, PresentationHub.SubscriberID?) {
        store.presentationHub = hub
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        if split { store.toggleSplit(session.id) }
        guard presented else { return (session, nil) }
        let hello = PresentationHello(version: 1, kinds: [], mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) {
            PresentationSnapshot(status: nil, hud: nil)
        }
        try hub.subscribe(session: session.id, hello: hello, sink: mirror) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        return (session, id)
    }

    private func ask(style: ControlAskStyle = .terminal) -> PendingAsk {
        PendingAsk(id: UUID().uuidString, title: "deploy?", buttons: Self.buttons, style: style)
    }

    private func owner(of session: Session) -> Int { hub.presenterGeneration(session: session.id) }

    @Test func aSessionAskGoesToThePresenterAloneAndIsNotDrawnHere() throws {
        let (session, _) = try origin()
        let pending = ask()

        #expect(store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window) == true)

        #expect(presenter.bodies.last == .askRequest(PresentationAsk(pending, pane: nil, owner: owner(of: session))))
        #expect(!mirror.bodies.contains { if case .askRequest = $0 { true } else { false } })
        #expect(session.askPending?.id == pending.id)
        #expect(session.askPresentedRemotely)
    }

    @Test func aPaneAskCarriesTheOriginsPaneIdentity() throws {
        let (session, _) = try origin(split: true)
        let pending = ask()
        let pane = try #require(session.splitPaneIdentity)

        store.presentAskRemotely(pending, in: session, paneIdentity: pane, window: Self.window)

        #expect(presenter.bodies.last == .askRequest(PresentationAsk(pending, pane: .identity(pane), owner: owner(of: session))))
    }

    @Test func withoutAPresenterTheCallerOpensTheAskItself() throws {
        let (session, _) = try origin(presented: false)

        #expect(store.presentAskRemotely(ask(), in: session, paneIdentity: nil, window: Self.window) == nil)
        #expect(session.askPending == nil)
    }

    @Test func aSecondAskWhileOneIsPresentedIsRefused() throws {
        let (session, _) = try origin()
        store.presentAskRemotely(ask(), in: session, paneIdentity: nil, window: Self.window)

        #expect(store.presentAskRemotely(ask(), in: session, paneIdentity: nil, window: Self.window) == false)
    }

    @Test func anAnswerTakesItsLabelAndIndexFromTheStoredButtons() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "no"),
                                       forSession: session.id))

        #expect(AskRegistry.shared.result(for: pending.id)?.result
            == ControlAskResult(result: .answered, id: "no", label: "No", index: 1))
    }

    @Test func anAnswerNamingAButtonTheAskDoesNotHaveIsRefused() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(!store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "maybe"),
                                        forSession: session.id))
        #expect(session.askPending?.id == pending.id)
    }

    @Test func anAnswerUnderAnotherOwnerIsRefused() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(!store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session) + 1, button: "yes"),
                                        forSession: session.id))
        #expect(session.askPending?.id == pending.id)
    }

    @Test func aDismissalOnTheViewerCompletesEscaped() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: nil),
                               forSession: session.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result == ControlAskResult(result: .escaped))
    }

    @Test func theFirstResultWins() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)
        let answer = PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "yes")
        store.resolveRemoteAsk(answer, forSession: session.id)

        #expect(!store.resolveRemoteAsk(PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "no"),
                                        forSession: session.id))
        #expect(AskRegistry.shared.result(for: pending.id)?.result.id == "yes")
    }

    @Test func aCancelHereCompletesCancelledAndTellsThePresenterToDismiss() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        session.cancelAsk(id: pending.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result == ControlAskResult(result: .cancelled))
        #expect(presenter.bodies.last == .askDismiss(PresentationAskRef(id: pending.id, owner: owner(of: session))))
    }

    @Test func aSoftCloseCancelsTheAskAndTellsThePresenter() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        store.softCloseSession(session.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result.result == .cancelled)
        #expect(presenter.bodies.contains(.askDismiss(PresentationAskRef(id: pending.id, owner: 1))))
    }

    @Test func closingTheCoveredPaneCancelsTheAskAndTellsThePresenter() throws {
        let (session, _) = try origin(split: true)
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: session.splitPaneIdentity, window: Self.window)
        let frameCount = presenter.frames.count

        store.closeSplit(session.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result.result == .cancelled)
        #expect(Array(presenter.bodies.dropFirst(frameCount)) == [
            .askDismiss(PresentationAskRef(id: pending.id, owner: 1)),
            .layout(PresentationLayout(panes: [session.paneIdentity], primary: session.paneIdentity, shown: false)),
        ])
    }

    @Test func aTakenBackTerminalAskIsDrawnHereAndALateAnswerIsRefused() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)
        let stale = PresentationAskAnswer(id: pending.id, owner: owner(of: session), button: "yes")

        #expect(store.takeBackRemoteAsk(forSession: session.id) == nil)

        #expect(session.askPending?.id == pending.id)
        #expect(!session.askPresentedRemotely)
        #expect(!store.resolveRemoteAsk(stale, forSession: session.id))
    }

    @Test func aTakenBackGuiAskIsLeftForTheHostToPlace() throws {
        let (session, _) = try origin()
        let pending = ask(style: .gui)
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(store.takeBackRemoteAsk(forSession: session.id)?.id == pending.id)
        #expect(session.askPresentedRemotely)
    }

    @Test func aHandbackThatCannotBeShownEndsCancelledWithTheReason() throws {
        let (session, _) = try origin()
        let pending = ask(style: .gui)
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        store.failHandback(forSession: session.id)

        #expect(AskRegistry.shared.result(for: pending.id)?.result
            == ControlAskResult(result: .cancelled, reason: ControlAskResult.presentationLost))
        #expect(session.askPending == nil)
    }

    @Test func aRefusalIsHonouredOnlyForTheAskBeingPresented() throws {
        let (session, _) = try origin()
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: Self.window)

        #expect(store.isPresentingRemotely(PresentationAskRef(id: pending.id, owner: owner(of: session)), forSession: session.id))
        #expect(!store.isPresentingRemotely(PresentationAskRef(id: "other", owner: owner(of: session)), forSession: session.id))
        #expect(!store.isPresentingRemotely(PresentationAskRef(id: pending.id, owner: 99), forSession: session.id))
    }

    @Test func losingThePresenterReportsTheSessionToTheHost() throws {
        var lost: [UUID] = []
        hub.onPresenterLost = { lost.append($0) }
        let (session, id) = try origin()

        hub.unsubscribe(try #require(id))

        #expect(lost == [session.id])
    }

    @Test func onlyTheCurrentPresentersAskFramesReachTheHost() throws {
        var received: [PresentationFrame.Body] = []
        hub.onPresenterFrame = { _, body in received.append(body) }
        let (_, id) = try origin()
        let presenterID = try #require(id)
        let mirrorID = PresentationHub.SubscriberID(generation: 2)
        let rejected = PresentationFrame.Body.askRejected(PresentationAskRef(id: "a", owner: 1))

        hub.receive(PresentationFrame(gen: 2, rev: 1, body: rejected), from: mirrorID)
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 1, body: rejected), from: presenterID)

        #expect(received == [rejected])
    }
}
