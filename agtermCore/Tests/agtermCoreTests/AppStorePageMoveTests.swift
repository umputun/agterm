import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStorePageMoveTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }

        var requests: [PresentationPage] { bodies.compactMap { if case .pageRequest(let r) = $0 { r } else { nil } } }

        var commands: [PresentationPageCommand] { bodies.compactMap { if case .pageCommand(let c) = $0 { c } else { nil } } }

        func closed(_ page: UUID) -> Bool {
            bodies.contains(.pageClose(PresentationPageChange(page: page.uuidString, reason: PresentationPageChange.channelLost)))
        }
    }

    struct Viewer {
        let id: PresentationHub.SubscriberID
        let gen: Int
        let sink: Sink
    }

    static let start = Date(timeIntervalSince1970: 1_789_000_000)

    let store = makeStore()
    let hub = PresentationHub(staleTimeout: 30)

    private func viewer(_ session: Session, acquire: Bool = false) throws -> Viewer {
        let sink = Sink()
        let hello = PresentationHello(version: 1, kinds: PresentationHub.supportedKinds, mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: sink) { PresentationSnapshot(status: nil, hud: nil) }
        let gen = sink.frames[0].gen
        if acquire { hub.receive(PresentationFrame(gen: gen, rev: 0, body: .presenterAcquire), from: id) }
        return Viewer(id: id, gen: gen, sink: sink)
    }

    private func session(following: Bool = true) throws -> Session {
        store.presentationHub = hub
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: session.paneIdentity)
        if following, let notice = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):follower:1") {
            _ = ZmxLeadBook.shared.apply(notice, pane: session.paneIdentity)
        }
        return session
    }

    private func open(_ session: Session, _ page: HtmlOverlay, size: Int? = nil,
                      points: OverlayPointSize = OverlayPointSize()) -> RemotePageOpen {
        store.openRemotePage(session.id, overlay: page, options: ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: size, backgroundColor: nil, points: points), now: Self.start)
    }

    private func state(_ page: HtmlOverlay, offer: Int?, hidden: Bool = false, title: String? = nil,
                       text: PresentationTextState? = nil) -> PresentationFrame.Body {
        .pageState(PresentationPageState(page: page.id.uuidString, title: title, address: "/a", load: .loaded, error: nil,
                                         canGoBack: false, canGoForward: false, hidden: hidden, appliedSeq: 0, text: text,
                                         offer: offer))
    }

    private func file() -> HtmlOverlay { HtmlOverlay(source: .file(path: "/tmp/docs/index.html", grantRoot: "/tmp/docs")) }

    private func url() throws -> HtmlOverlay { HtmlOverlay(source: .url(try #require(URL(string: "https://example.com/")))) }

    @Test func aURLPageMovesOnceTheViewerItIsOfferedToReportsIt() throws {
        let session = try session()
        let first = try viewer(session, acquire: true)
        let second = try viewer(session)
        let page = try url()
        #expect(open(session, page) == .opened)

        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        #expect(session.remoteOverlays.slot(nil)?.owner == first.gen)
        let offered = try #require(second.sink.requests.last)
        #expect(offered.token != first.sink.requests.last?.token)
        store.receiveRemotePageFrame(state(page, offer: offered.offer, title: "moved"), forSession: session.id, from: second.gen)

        #expect(session.remoteOverlays.slot(nil)?.owner == second.gen)
        #expect(session.remoteOverlays.slot(nil)?.page?.overlay.current?.title == "moved")
        #expect(first.sink.closed(page.id))
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .pending)
    }

    @Test func aChannelPageStaysWithItsHolderUntilItsOfferIsClaimedAndCommitted() throws {
        let session = try session()
        let first = try viewer(session, acquire: true)
        let second = try viewer(session)
        let page = file()
        #expect(open(session, page) == .opened)
        let held = try #require(first.sink.requests.last?.token)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)

        store.receiveRemotePageFrame(state(page, offer: offered.offer), forSession: session.id, from: second.gen)
        #expect(session.remoteOverlays.slot(nil)?.owner == first.gen)
        #expect(store.claimRemotePage(token: offered.token, now: Self.start)?.overlay.id == page.id)
        #expect(store.claimRemotePage(token: offered.token, now: Self.start) == nil)
        #expect(store.remotePageClaimToken(page.id) == held)
        #expect(store.pageCandidateClaimed(page.id, token: offered.token))
        let move = try #require(store.commitPageCandidate(page.id, token: offered.token))
        #expect(!first.sink.closed(page.id))
        store.finishPageMove(move)

        #expect(session.remoteOverlays.slot(nil)?.owner == second.gen)
        #expect(store.remotePageClaimToken(page.id) == offered.token)
        #expect(session.remoteOverlays.slot(nil)?.page?.offer == offered.offer)
        #expect(first.sink.closed(page.id))
    }

    @Test func aRefusedOfferLeavesThePageWithItsHolder() throws {
        let session = try session()
        let first = try viewer(session, acquire: true)
        let second = try viewer(session)
        let page = file()
        #expect(open(session, page) == .opened)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)

        store.receiveRemotePageFrame(.pageRejected(PresentationPageChange(page: page.id.uuidString, reason: "slot taken",
                                                                          offer: offered.offer)),
                                     forSession: session.id, from: second.gen)

        #expect(store.claimRemotePage(token: offered.token, now: Self.start) == nil)
        #expect(session.remoteOverlays.slot(nil)?.owner == first.gen)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .pending)
    }

    @Test func anExpiredOfferIsDroppedAndTheHolderKeepsThePage() throws {
        let session = try session()
        let first = try viewer(session, acquire: true)
        let second = try viewer(session)
        let page = file()
        #expect(open(session, page) == .opened)
        #expect(store.claimRemotePage(token: try #require(first.sink.requests.last?.token), now: Self.start) != nil)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)

        store.expireRemotePageClaims(now: Self.start.addingTimeInterval(AppStore.pageClaimWindow + 1))

        #expect(second.sink.closed(page.id))
        #expect(store.claimRemotePage(token: offered.token, now: Self.start) == nil)
        #expect(session.remoteOverlays.slot(nil)?.owner == first.gen)
    }

    @Test func aDroppedOfferNeitherMovesNorRevivesThePage() throws {
        let session = try session()
        let first = try viewer(session, acquire: true)
        let second = try viewer(session)
        let page = try url()
        #expect(open(session, page) == .opened)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)

        store.discardPageCandidate(page.id)
        store.receiveRemotePageFrame(state(page, offer: offered.offer), forSession: session.id, from: second.gen)

        #expect(second.sink.closed(page.id))
        #expect(session.remoteOverlays.slot(nil)?.owner == first.gen)
        #expect(store.commitPageCandidate(page.id, token: offered.token) == nil)
    }

    @Test func aPageClosedBeforeItsOfferIsConfirmedTakesTheOfferDownAndStaysClosed() throws {
        let session = try session()
        _ = try viewer(session, acquire: true)
        let second = try viewer(session)
        let page = file()
        #expect(open(session, page) == .opened)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)
        #expect(store.claimRemotePage(token: offered.token, now: Self.start) != nil)

        store.closeRemoteOverlay(session.id, pane: nil)

        #expect(second.sink.closed(page.id))
        #expect(!store.pageCandidateClaimed(page.id, token: offered.token))
        #expect(store.commitPageCandidate(page.id, token: offered.token) == nil)
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .dismissed)
    }

    @Test func aLostViewerTakesItsOfferWithItAndNothingIsSentToIt() throws {
        let session = try session()
        let first = try viewer(session, acquire: true)
        let second = try viewer(session)
        let page = file()
        #expect(open(session, page) == .opened)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)
        let sent = second.sink.frames.count

        store.remoteOverlayOwnerLost(forSession: session.id, owner: second.gen)

        #expect(store.commitPageCandidate(page.id, token: offered.token) == nil)
        #expect(second.sink.frames.count == sent)
        #expect(session.remoteOverlays.slot(nil)?.owner == first.gen)
    }

    @Test func aMovedPageKeepsItsSizePointsHiddenStateAndTextSeed() throws {
        let session = try session()
        let first = try viewer(session, acquire: true)
        let second = try viewer(session)
        let page = HtmlOverlay(source: .text(path: "/tmp/a.go", line: nil))
        #expect(open(session, page, size: 40, points: OverlayPointSize(width: 600)) == .opened)
        store.receiveRemotePageFrame(state(page, offer: first.sink.requests.last?.offer, hidden: true,
                                           text: PresentationTextState(query: "err", revision: 2, matches: 3, current: 1, wrap: true)),
                                     forSession: session.id, from: first.gen)

        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))

        let offered = try #require(second.sink.requests.last)
        #expect(offered.sizePercent == 40)
        #expect(offered.points == OverlayPointSize(width: 600))
        #expect(offered.textSeed?.query == "err")
        #expect(offered.textSeed?.wrap == true)
        #expect(second.sink.commands.map(\.action) == [.hide])
    }

    @Test(arguments: [
        HtmlSource.file(path: "/tmp/docs/index.html", grantRoot: "/tmp/docs"), .markdown(path: "/tmp/docs/a.md"), .image(path: "/tmp/a.png"),
    ])
    func aPageShownHereIsOfferedAndMovesOnceItsOfferIsCommitted(source: HtmlSource) throws {
        let session = try session(following: false)
        let second = try viewer(session)
        let page = HtmlOverlay(source: source, imagePixels: ImagePixels(width: 800, height: 600))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: 60) == nil)
        session.setOverlayHidden(true, slot: nil)

        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)
        #expect(offered.source == AppStore.presentationSource(source, imagePixels: page.imagePixels))
        #expect(offered.sizePercent == 60)
        #expect(second.sink.commands.map(\.action) == [.hide])
        #expect(session.htmlOverlay?.id == page.id)
        #expect(store.claimRemotePage(token: offered.token, now: Self.start)?.overlay.id == page.id)
        #expect(store.commitPageCandidate(page.id, token: offered.token) != nil)

        #expect(session.htmlOverlay == nil)
        #expect(!session.overlayActive)
        #expect(session.remoteOverlays.slot(nil)?.owner == second.gen)
        #expect(session.remoteOverlays.slot(nil)?.page?.hidden == true)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .pending)
    }

    @Test func aPageShownHereWhoseOfferIsRefusedStaysShownHere() throws {
        let session = try session(following: false)
        let second = try viewer(session)
        let page = file()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)

        store.receiveRemotePageFrame(.pageRejected(PresentationPageChange(page: page.id.uuidString, offer: offered.offer)),
                                     forSession: session.id, from: second.gen)
        store.submitHtmlOverlay(session.id, pane: nil, value: "done")

        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(store.commitPageCandidate(page.id, token: offered.token) == nil)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .submitted)
    }

    @Test func aPageShownHereAndSubmittedBeforeItsOfferIsConfirmedTakesTheOfferDown() throws {
        let session = try session(following: false)
        let second = try viewer(session)
        let page = file()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)
        #expect(store.claimRemotePage(token: offered.token, now: Self.start) != nil)

        store.submitHtmlOverlay(session.id, pane: nil, value: "done")

        #expect(second.sink.closed(page.id))
        #expect(store.commitPageCandidate(page.id, token: offered.token) == nil)
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .submitted)
    }

    @Test func aViewersPageMountsHereWithItsOutcomeStillOpen() throws {
        let session = try session()
        let first = try viewer(session, acquire: true)
        let page = file()
        #expect(open(session, page, size: 50) == .opened)
        store.receiveRemotePageFrame(state(page, offer: first.sink.requests.last?.offer, hidden: true), forSession: session.id,
                                     from: first.gen)

        #expect(store.mountRemotePageHere(page.id, forSession: session.id))

        #expect(session.htmlOverlay?.id == page.id)
        #expect(session.overlaySizePercent == 50)
        #expect(session.overlayHidden)
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(first.sink.closed(page.id))
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .pending)
    }

    @Test func aViewersPageForAPaneNotShownHereStaysWithTheViewer() throws {
        let session = try session()
        store.toggleSplit(session.id)
        let attachment = ZmxLeadAttachment(claim: false)
        let right = try #require(session.splitPaneIdentity)
        ZmxLeadBook.shared.begin(attachment, pane: right)
        _ = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):follower:1").map { ZmxLeadBook.shared.apply($0, pane: right) }
        let first = try viewer(session, acquire: true)
        let page = file()
        #expect(store.openRemotePage(session.id, overlay: page, options: ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, pane: .right), now: Self.start) == .opened)
        store.setSplitVisibility(session.id, shown: false)

        #expect(!store.mountRemotePageHere(page.id, forSession: session.id))

        #expect(session.remoteOverlays.slot(.right)?.owner == first.gen)
        #expect(!first.sink.closed(page.id))
    }

    @Test func aPictureTheViewerFittedComesHomeFloatingWithItsPointOverrides() throws {
        let session = try session()
        _ = try viewer(session, acquire: true)
        let page = HtmlOverlay(source: .image(path: "/tmp/a.png"))
        #expect(store.openRemotePage(session.id, overlay: page, options: ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil, imagePixels: ImagePixels(width: 800, height: 600)),
                                     now: Self.start) == .opened)
        _ = store.resizeRemoteOverlay(session.id, sizePercent: nil, points: OverlayPointSize(width: 300))

        #expect(store.mountRemotePageHere(page.id, forSession: session.id))

        #expect(session.overlaySizePercent == ImagePage.basePercent)
        #expect(session.overlayPoints == OverlayPointSize(width: 300))
    }

    @Test func aPageShownHereFollowsItsPaneWhenThePanesSwapBeforeItsOfferIsConfirmed() throws {
        let session = try session(following: false)
        store.toggleSplit(session.id)
        _ = try viewer(session)
        let second = try viewer(session)
        let page = file()
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page, sizePercent: nil) == nil)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)

        #expect(store.swapPanes(session.id, allowingUnrealized: true) == nil)
        #expect(store.claimRemotePage(token: offered.token, now: Self.start) != nil)
        #expect(store.commitPageCandidate(page.id, token: offered.token) != nil)

        #expect(session.remoteOverlays.slot(.right)?.owner == second.gen)
        #expect(session.remoteOverlays.slot(.left) == nil)
    }

    @Test func aPageShownInTheSplitFollowsItWhenItIsPromotedBeforeItsOfferIsConfirmed() throws {
        let session = try session(following: false)
        store.toggleSplit(session.id)
        let second = try viewer(session)
        let page = file()
        #expect(store.openHtmlOverlay(session.id, pane: .right, overlay: page, sizePercent: nil) == nil)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)

        store.promoteSplit(session)
        #expect(store.claimRemotePage(token: offered.token, now: Self.start) != nil)
        #expect(store.commitPageCandidate(page.id, token: offered.token) != nil)

        #expect(session.remoteOverlays.slot(.left)?.owner == second.gen)
        #expect(session.remoteOverlays.slot(.right) == nil)
    }

    @Test func aPageShownInThePrimaryPaneTakesItsOfferDownWhenThatPaneExits() throws {
        let session = try session(following: false)
        store.toggleSplit(session.id)
        let second = try viewer(session)
        let page = file()
        #expect(store.openHtmlOverlay(session.id, pane: .left, overlay: page, sizePercent: nil) == nil)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)

        store.promoteSplit(session)

        #expect(second.sink.closed(page.id))
        #expect(store.commitPageCandidate(page.id, token: offered.token) == nil)
    }

    @Test(arguments: [false, true])
    func aSessionClosedBeforeItsPagesOfferIsConfirmedTakesTheOfferDown(soft: Bool) throws {
        let session = try session(following: false)
        let second = try viewer(session)
        let page = try url()
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        #expect(store.offerPageCandidate(page.id, forSession: session.id, to: second.gen, now: Self.start))
        let offered = try #require(second.sink.requests.last)

        if soft { #expect(store.softCloseSession(session.id)) } else { _ = store.closeSession(session.id) }
        store.receiveRemotePageFrame(state(page, offer: offered.offer), forSession: session.id, from: second.gen)

        #expect(second.sink.closed(page.id))
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(store.commitPageCandidate(page.id, token: offered.token) == nil)
    }
}
