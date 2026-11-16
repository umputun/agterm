import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreOpenWorkTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }
        var asks: [PresentationAsk] { bodies.compactMap { if case .askRequest(let r) = $0 { r } else { nil } } }
        var picks: [PresentationPick] { bodies.compactMap { if case .pickRequest(let r) = $0 { r } else { nil } } }
        var pages: [PresentationPage] { bodies.compactMap { if case .pageRequest(let r) = $0 { r } else { nil } } }

        func dismissed(ask id: String) -> Bool { bodies.contains { if case .askDismiss(let r) = $0 { r.id == id } else { false } } }
        func dismissed(pick id: String) -> Bool { bodies.contains { if case .pickDismiss(let r) = $0 { r.id == id } else { false } } }
        func closed(_ page: HtmlOverlay) -> Bool {
            bodies.contains { if case .pageClose(let c) = $0 { c.page == page.id.uuidString } else { false } }
        }
    }

    struct Viewer {
        let id: PresentationHub.SubscriberID
        let gen: Int
        let sink: Sink
    }

    static let buttons = [ControlAskButton(id: "yes", label: "Yes"), ControlAskButton(id: "no", label: "No")]
    static let items = [ControlPickItem(id: "a", label: "Alpha"), ControlPickItem(id: "b", label: "Beta")]
    static let legacyKinds = PresentationHub.supportedKinds.filter { $0 != PresentationHub.offerIdentityKind }

    let store: AppStore
    let hub = PresentationHub(staleTimeout: 30)

    init() {
        store = makeStore()
        store.presentationHub = hub
    }

    private func session(headless: Bool = false) throws -> (AppStore, Session) {
        let host = headless ? makeHeadlessSession(split: false).store : store
        host.presentationHub = hub
        hub.onOwnerLost = { [host] session, owner in host.remoteOverlayOwnerLost(forSession: session, owner: owner) }
        let session = try #require(headless ? host.workspaces.first?.sessions.first
                                            : host.addSession(toWorkspace: host.addWorkspace(name: "work").id, cwd: "/tmp"))
        if !headless { setLead(.follower, pane: session.paneIdentity) }
        return (host, session)
    }

    private func setLead(_ role: ZmxLeadRole, pane: UUID) {
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: pane)
        _ = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(role.rawValue):1").map { ZmxLeadBook.shared.apply($0, pane: pane) }
    }

    private func viewer(_ session: Session, leads: Bool = false, acquire: Bool = false,
                        kinds: [String] = PresentationHub.supportedKinds) throws -> Viewer {
        let sink = Sink()
        let hello = PresentationHello(version: 1, kinds: kinds, mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: sink) { PresentationSnapshot(status: nil, hud: nil) }
        let viewer = Viewer(id: id, gen: sink.frames[0].gen, sink: sink)
        if acquire { hub.receive(PresentationFrame(gen: viewer.gen, rev: 0, body: .presenterAcquire), from: id) }
        if leads { lead(viewer, [session.paneIdentity]) }
        return viewer
    }

    private func lead(_ viewer: Viewer, _ panes: [UUID]) {
        hub.receive(PresentationFrame(gen: viewer.gen, rev: 0, body: .leadReport(PresentationLeadReport(leaders: panes))), from: viewer.id)
    }

    private func ask(style: ControlAskStyle = .terminal) -> PendingAsk {
        PendingAsk(id: UUID().uuidString, title: "deploy?", buttons: Self.buttons, style: style)
    }

    private func pick() -> PendingPick { PendingPick(id: UUID().uuidString, items: Self.items) }

    private func url() throws -> HtmlOverlay { HtmlOverlay(source: .url(try #require(URL(string: "https://example.com/")))) }

    private func openPage(_ page: HtmlOverlay, in session: Session, on host: AppStore? = nil) -> RemotePageOpen {
        (host ?? store).openRemotePage(session.id, overlay: page, options: ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil))
    }

    private func report(_ page: HtmlOverlay, in session: Session, from viewer: Viewer, load: HtmlLoadState = .loaded,
                        on host: AppStore? = nil) {
        let offer = viewer.sink.pages.last { $0.page == page.id.uuidString }?.offer
        (host ?? store).receiveRemotePageFrame(.pageState(PresentationPageState(
            page: page.id.uuidString, title: nil, address: "https://example.com/", load: load, error: nil, canGoBack: false,
            canGoForward: false, hidden: false, appliedSeq: 0, offer: offer)), forSession: session.id, from: viewer.gen)
    }

    private func answer(_ ask: PendingAsk, from viewer: Viewer, in session: Session) -> Bool {
        let offer = viewer.sink.asks.last { $0.id == ask.id }?.offer
        return store.resolveRemoteAsk(PresentationAskAnswer(id: ask.id, owner: viewer.gen, button: "yes", offer: offer), forSession: session.id)
    }

    private func pass(_ session: Session, on host: AppStore? = nil, local: OpenWorkLocal? = nil) {
        (host ?? store).reconcileOpenWork(forSession: session.id, local: local)
    }

    private func local(_ controller: PickController, window: UUID, shows: Bool = true) -> OpenWorkLocal {
        OpenWorkLocal(modal: { _ in (controller, window) }, showsGuiAsk: { _ in shows })
    }

    @Test func theNewLeaderTakesTheAskPickAndPageAndTheOldViewersLateAnswerIsRefused() throws {
        let (_, session) = try session()
        let first = try viewer(session, leads: true, acquire: true)
        let pending = ask(), choice = pick(), page = try url()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: UUID())
        _ = store.presentPickRemotely(choice, in: session, window: nil)
        #expect(openPage(page, in: session) == .opened)
        #expect(session.askRemoteOwner == first.gen)

        let second = try viewer(session, leads: true)
        pass(session)
        report(page, in: session, from: second)

        #expect(session.askRemoteOwner == second.gen)
        #expect(SessionPickBook.shared.placement(forSession: session.id) == .presenter(owner: second.gen))
        #expect(session.remoteOverlays.slot(nil)?.owner == second.gen)
        #expect(second.sink.asks.map(\.id) == [pending.id])
        #expect(second.sink.picks.map(\.id) == [choice.id])
        #expect(first.sink.dismissed(ask: pending.id))
        #expect(first.sink.dismissed(pick: choice.id))
        #expect(first.sink.closed(page))
        #expect(session.askPresentedRemotely)
        #expect(!answer(pending, from: first, in: session))
        #expect(answer(pending, from: second, in: session))
    }

    @Test func aProgramOverlayStaysWithItsViewerWhenTheLeadMoves() throws {
        store.overlayJobs = OverlayJobs()
        let (_, session) = try session()
        let first = try viewer(session, leads: true, acquire: true)
        let opened = store.openRemoteOverlay(session.id, options: ControlSessionOverlayOpenOptions(
            command: "top", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil),
                                             context: OverlayLaunchContext(command: "top", cwd: "/tmp", sessionEnvironment: [:]))
        guard case .opened(let job) = opened else { Issue.record("no job: \(opened)"); return }
        let second = try viewer(session, leads: true)

        pass(session)

        #expect(session.remoteOverlays.slot(job: job)?.owner == first.gen)
        #expect(!second.sink.bodies.contains { if case .overlayRequest = $0 { true } else { false } })
    }

    @Test func theOriginTakingTheLeadBringsWorkHereAndAViewerTakingItSendsItOut() throws {
        let (_, session) = try session()
        let first = try viewer(session, leads: true, acquire: true)
        let pending = ask(), page = try url()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: UUID())
        #expect(openPage(page, in: session) == .opened)

        setLead(.leader, pane: session.paneIdentity)
        pass(session)

        #expect(!session.askPresentedRemotely)
        #expect(session.askPending?.id == pending.id)
        #expect(session.htmlOverlay?.id == page.id)
        #expect(first.sink.dismissed(ask: pending.id))
        #expect(first.sink.closed(page))

        setLead(.follower, pane: session.paneIdentity)
        lead(first, [session.paneIdentity])
        pass(session)

        #expect(session.askRemoteOwner == first.gen)
        #expect(first.sink.asks.map(\.id) == [pending.id, pending.id])
        #expect(first.sink.pages.count == 2)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .pending)
    }

    @Test func aViewerWithdrawingItsClaimWithNoOtherClaimantMovesNothing() throws {
        let (_, session) = try session()
        let holder = try viewer(session, acquire: true)
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: UUID())
        let next = try viewer(session, leads: true)
        pass(session)
        #expect(session.askRemoteOwner == next.gen)

        lead(next, [])
        pass(session)

        #expect(session.askRemoteOwner == next.gen)
        #expect(holder.sink.asks.count == 1)
    }

    @Test func aViewerTakingTheLeadFromTheOriginGetsTheWorkOnce() throws {
        let (_, session) = try session()
        setLead(.leader, pane: session.paneIdentity)
        let pending = ask()
        #expect(session.openAsk(pending, paneIdentity: nil, registry: store.askRegistry))
        let next = try viewer(session)

        setLead(.follower, pane: session.paneIdentity)
        pass(session)
        #expect(!session.askPresentedRemotely)
        lead(next, [session.paneIdentity])
        pass(session)
        pass(session)

        #expect(session.askRemoteOwner == next.gen)
        #expect(next.sink.asks.map(\.id) == [pending.id])
    }

    @Test func aLostViewersWorkGoesToTheViewerLeadingNow() throws {
        let (_, session) = try session()
        let first = try viewer(session, leads: true, acquire: true)
        let pending = ask(), choice = pick(), page = try url()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: UUID())
        _ = store.presentPickRemotely(choice, in: session, window: nil)
        #expect(openPage(page, in: session) == .opened)
        let second = try viewer(session, leads: true)

        hub.unsubscribe(first.id)
        pass(session)

        #expect(session.askRemoteOwner == second.gen)
        #expect(SessionPickBook.shared.placement(forSession: session.id) == .presenter(owner: second.gen))
        #expect(session.remoteOverlays.slot(nil)?.owner == second.gen)
        #expect(second.sink.pages.map(\.page) == [page.id.uuidString])
    }

    @Test func theOnlyViewerQuittingBringsTheAskAndPageHereUntilAViewerClaimsThem() throws {
        let (_, session) = try session()
        let only = try viewer(session, leads: true, acquire: true)
        let pending = ask(), page = try url()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: UUID())
        #expect(openPage(page, in: session) == .opened)

        hub.unsubscribe(only.id)
        pass(session)

        #expect(!session.askPresentedRemotely)
        #expect(session.askPending?.id == pending.id)
        #expect(session.htmlOverlay?.id == page.id)
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .pending)

        let next = try viewer(session, leads: true)
        pass(session)
        report(page, in: session, from: next)

        #expect(session.askRemoteOwner == next.gen)
        #expect(session.remoteOverlays.slot(nil)?.owner == next.gen)
        #expect(session.htmlOverlay == nil)
    }

    @Test func aLostViewersWorkNoRoutedViewerCanShowComesHere() throws {
        let (_, session) = try session()
        let window = UUID(), controller = PickController()
        let only = try viewer(session, leads: true, acquire: true)
        let gui = ask(style: .gui), choice = pick()
        store.presentAskRemotely(gui, in: session, paneIdentity: nil, window: window)
        _ = store.presentPickRemotely(choice, in: session, window: window)
        let older = try viewer(session, acquire: false, kinds: [PresentationHub.pendingSnapshotKind, PresentationHub.jobTokenKind])
        hub.receive(PresentationFrame(gen: older.gen, rev: 0, body: .presenterAcquire), from: older.id)

        hub.unsubscribe(only.id)
        pass(session, local: local(controller, window: window))

        #expect(older.sink.asks.isEmpty)
        #expect(older.sink.picks.isEmpty)
        #expect(controller.pendingAsk?.id == gui.id)
        #expect(session.askPending == nil)
        #expect(store.askRegistry.owner(for: gui.id) == .window(window))
        #expect(SessionPickBook.shared.placement(forSession: session.id) == nil)
        #expect(SessionPickBook.shared.result(for: choice.id) == ControlPickResult(result: .cancelled))
    }

    @Test func aLostViewersPickComesIntoAFreeModalEvenWhereAGuiAskCouldNotBeSeen() throws {
        let (_, session) = try session()
        let window = UUID(), controller = PickController()
        let only = try viewer(session, acquire: true)
        let choice = pick()
        _ = store.presentPickRemotely(choice, in: session, window: window)

        hub.unsubscribe(only.id)
        pass(session, local: local(controller, window: window, shows: false))

        #expect(controller.pending?.id == choice.id)
        #expect(SessionPickBook.shared.placement(forSession: session.id) == .local(window))
    }

    @Test func aLoadedPageWhoseConnectionBreaksIsOfferedOnceMoreToItsViewer() throws {
        let (_, session) = try session()
        let only = try viewer(session, leads: true, acquire: true)
        let page = try url()
        #expect(openPage(page, in: session) == .opened)
        report(page, in: session, from: only)

        #expect(store.remotePageLost(page.id))
        pass(session)

        #expect(only.sink.closed(page))
        #expect(only.sink.pages.count == 2)
        #expect(session.remoteOverlays.slot(nil)?.owner == only.gen)

        #expect(store.remotePageLost(page.id))
        pass(session)

        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .dismissed)
        #expect(only.sink.pages.count == 2)
    }

    @Test func headlessALoadedPageWhoseViewerReportsItsChannelLostIsRetriedOnceThenEnds() throws {
        let (host, session) = try session(headless: true)
        let only = try viewer(session, leads: true, acquire: true)
        let page = try url()
        #expect(openPage(page, in: session, on: host) == .opened)
        report(page, in: session, from: only, on: host)
        let lost: () -> Void = {
            host.receiveRemotePageFrame(.pageClosed(PresentationPageChange(page: page.id.uuidString, reason: PresentationPageChange.channelLost,
                                                                           offer: only.sink.pages.last?.offer)),
                                        forSession: session.id, from: only.gen)
        }

        lost()
        pass(session, on: host)
        #expect(only.sink.pages.count == 2)
        #expect(session.remoteOverlays.slot(nil)?.owner == only.gen)

        lost()
        pass(session, on: host)

        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .dismissed)
        #expect(only.sink.pages.count == 2)
    }

    @Test func aPageThatNeverLoadedUnderItsOfferIsNotOfferedAgain() throws {
        let (_, session) = try session()
        let only = try viewer(session, leads: true, acquire: true)
        let page = try url()
        #expect(openPage(page, in: session) == .opened)
        report(page, in: session, from: only, load: .loading)

        store.receiveRemotePageFrame(.pageClosed(PresentationPageChange(page: page.id.uuidString, reason: PresentationPageChange.channelLost,
                                                                        offer: only.sink.pages.last?.offer)),
                                     forSession: session.id, from: only.gen)

        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .dismissed)
        #expect(only.sink.pages.count == 1)
    }

    @Test func aLeadingViewerRefusingAMovedPageLeavesItWorkingUntilTheNextPass() throws {
        let (_, session) = try session()
        let first = try viewer(session, leads: true, acquire: true)
        let page = try url()
        #expect(openPage(page, in: session) == .opened)
        let second = try viewer(session, leads: true)
        pass(session)
        let offered = try #require(second.sink.pages.last)

        store.receiveRemotePageFrame(.pageRejected(PresentationPageChange(page: page.id.uuidString, reason: "slot taken", offer: offered.offer)),
                                     forSession: session.id, from: second.gen)

        #expect(session.remoteOverlays.slot(nil)?.owner == first.gen)
        #expect(!first.sink.closed(page))
        pass(session)
        #expect(second.sink.pages.count == 2)
    }

    @Test func aViewerWithoutOffersGivesWorkUpButIsNeverHandedItAgain() throws {
        let (_, session) = try session()
        let older = try viewer(session, leads: true, acquire: true, kinds: Self.legacyKinds)
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: UUID())
        let next = try viewer(session, leads: true)
        pass(session)
        #expect(session.askRemoteOwner == next.gen)

        lead(older, [session.paneIdentity])
        pass(session)
        hub.unsubscribe(next.id)
        pass(session)

        #expect(older.sink.asks.count == 1)
        #expect(session.askRemoteOwner != older.gen)
    }

    @Test func aLeaderThatCannotTakeHeldWorkIsNeverChosen() throws {
        let (_, session) = try session()
        let holder = try viewer(session, leads: true, acquire: true)
        let pending = ask()
        store.presentAskRemotely(pending, in: session, paneIdentity: nil, window: UUID())
        let next = try viewer(session, leads: true, kinds: [PresentationHub.offerIdentityKind])

        pass(session)

        #expect(session.askRemoteOwner == holder.gen)
        #expect(next.sink.asks.isEmpty)
    }

    @Test func aWindowAskFollowsOnceTheSessionsOwnAskSlotFrees() throws {
        let (_, session) = try session()
        let window = UUID(), controller = PickController()
        let first = try viewer(session, leads: true, acquire: true)
        let terminal = ask(), gui = ask(style: .gui)
        store.presentAskRemotely(terminal, in: session, paneIdentity: nil, window: window)
        #expect(controller.openAsk(gui.anchored(at: AskAnchor(sessionID: session.id))))
        store.askRegistry.register(id: gui.id, owner: .window(window))
        let second = try viewer(session, leads: true)

        pass(session, local: local(controller, window: window))
        #expect(second.sink.asks.map(\.id) == [terminal.id])
        #expect(controller.pendingAsk?.id == gui.id)

        #expect(answer(terminal, from: second, in: session))
        pass(session, local: local(controller, window: window))

        #expect(second.sink.asks.map(\.id) == [terminal.id, gui.id])
        #expect(controller.pendingAsk == nil)
        #expect(first.sink.asks.count == 1)
    }

    @Test func aPassForASessionThatLeftTheStoreDoesNothing() throws {
        let (_, session) = try session()
        let first = try viewer(session, leads: true, acquire: true)
        store.presentAskRemotely(ask(), in: session, paneIdentity: nil, window: UUID())
        let second = try viewer(session, leads: true)

        #expect(store.softCloseSession(session.id))
        pass(session)

        #expect(second.sink.asks.isEmpty)
        #expect(first.sink.asks.count == 1)
    }

    @Test func aMoveTheNewLeaderCannotTakeDropsTheEarlierPendingMove() throws {
        let (_, session) = try session()
        let first = try viewer(session, leads: true, acquire: true)
        let page = try url()
        #expect(openPage(page, in: session) == .opened)
        let second = try viewer(session, leads: true)
        pass(session)
        #expect(second.sink.pages.count == 1)

        _ = try viewer(session, leads: true, kinds: PresentationHub.supportedKinds.filter { !PresentationHub.pageKinds.contains($0) })
        pass(session)
        report(page, in: session, from: second)

        #expect(second.sink.closed(page))
        #expect(session.remoteOverlays.candidate(job: page.id.uuidString) == nil)
        #expect(session.remoteOverlays.slot(nil)?.owner == first.gen)
        #expect(!first.sink.closed(page))
    }

    @Test func losingTheHolderDuringAPendingMoveOffersThePageOnceAfresh() throws {
        let (_, session) = try session()
        let first = try viewer(session, leads: true, acquire: true)
        let page = try url()
        #expect(openPage(page, in: session) == .opened)
        let second = try viewer(session, leads: true)
        pass(session)
        let moving = try #require(second.sink.pages.last)

        hub.unsubscribe(first.id)
        pass(session)
        store.receiveRemotePageFrame(.pageRejected(PresentationPageChange(page: page.id.uuidString, reason: "slot taken", offer: moving.offer)),
                                     forSession: session.id, from: second.gen)
        report(page, in: session, from: second)

        #expect(second.sink.closed(page))
        #expect(second.sink.pages.count == 2)
        #expect(second.sink.pages.last?.offer != moving.offer)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .pending)
        #expect(session.remoteOverlays.slot(nil)?.owner == second.gen)
    }

    @Test func aViewerWithoutOffersWhosePendingMoveWasDroppedIsNotOfferedThePageAgain() throws {
        let (_, session) = try session()
        _ = try viewer(session, leads: true, acquire: true)
        let page = try url()
        #expect(openPage(page, in: session) == .opened)
        let older = try viewer(session, leads: true, kinds: Self.legacyKinds)
        pass(session)
        #expect(older.sink.pages.count == 1)

        setLead(.leader, pane: session.paneIdentity)
        pass(session)
        setLead(.follower, pane: session.paneIdentity)
        lead(older, [session.paneIdentity])
        pass(session)
        store.receiveRemotePageFrame(.pageClosed(PresentationPageChange(page: page.id.uuidString)), forSession: session.id, from: older.gen)

        #expect(older.sink.pages.count == 1)
        #expect(session.htmlOverlay?.id == page.id)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .pending)
    }

    @Test func headlessWorkAViewerHeldIsOfferedToTheHolderWhenThatViewerLeaves() throws {
        let (host, session) = try session(headless: true)
        let leader = try viewer(session, leads: true)
        let holder = try viewer(session, acquire: true)
        let pending = ask()
        host.presentAskRemotely(pending, in: session, paneIdentity: nil, window: UUID())
        #expect(leader.sink.asks.map(\.id) == [pending.id])
        #expect(holder.sink.asks.isEmpty)

        host.returnAskToPending(forSession: session.id, owner: leader.gen)
        hub.unsubscribe(leader.id)
        pass(session, on: host)

        let shown = try #require(holder.sink.asks.last)
        #expect(shown.id == pending.id)
        #expect(shown.owner == holder.gen)
    }

    @Test func headlessAReofferedPageComesBackAtItsCurrentSizeAndHidden() throws {
        let (host, session) = try session(headless: true)
        let first = try viewer(session, acquire: true)
        let page = try url()
        #expect(openPage(page, in: session, on: host) == .opened)
        let shown = try #require(first.sink.pages.last)
        #expect(host.resizeRemoteOverlay(session.id, sizePercent: 40) == true)
        host.receiveRemotePageFrame(.pageState(PresentationPageState(
            page: shown.page, title: nil, address: nil, load: .loaded, error: nil, canGoBack: false, canGoForward: false,
            hidden: true, appliedSeq: 0, offer: shown.offer)), forSession: session.id, from: first.gen)

        hub.unsubscribe(first.id)
        let next = try viewer(session, acquire: true)
        pass(session, on: host)

        let fresh = try #require(next.sink.pages.last)
        #expect(fresh.page == shown.page)
        #expect(fresh.sizePercent == 40)
        #expect(next.sink.bodies.contains { if case .pageCommand(let command) = $0 { command.action == .hide } else { false } })
    }

    @Test func headlessHeldWorkMovesToTheNewLeaderAndLostWorkGoesThroughThePendingOffer() throws {
        let (host, session) = try session(headless: true)
        let first = try viewer(session, leads: true, acquire: true)
        let pending = ask(), choice = pick()
        host.presentAskRemotely(pending, in: session, paneIdentity: nil, window: UUID())
        _ = host.presentPickRemotely(choice, in: session, window: nil)
        #expect(session.askRemoteOwner == first.gen)
        let second = try viewer(session, leads: true)

        pass(session, on: host)
        #expect(session.askRemoteOwner == second.gen)
        #expect(SessionPickBook.shared.placement(forSession: session.id) == .presenter(owner: second.gen))

        host.returnAskToPending(forSession: session.id, owner: second.gen)
        SessionPickBook.shared.returnToPending(session: session.id, owner: second.gen)
        hub.unsubscribe(second.id)
        pass(session, on: host)

        #expect(session.askRemoteOwner == first.gen)
        #expect(SessionPickBook.shared.placement(forSession: session.id) == .presenter(owner: first.gen))
        #expect(first.sink.asks.map(\.id) == [pending.id, pending.id])
    }
}
