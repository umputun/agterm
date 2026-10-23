import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreRemotePageTests {
    final class Sink: PresentationSink {
        var frames: [PresentationFrame] = []

        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }

        func close(_: PresentationHub.CloseReason) {}

        var bodies: [PresentationFrame.Body] { frames.map(\.body) }

        var commands: [PresentationPageCommand] {
            bodies.compactMap { if case .pageCommand(let command) = $0 { command } else { nil } }
        }
    }

    final class Drafts {
        var kinds: [ControlEventKind] = []
    }

    static let start = Date(timeIntervalSince1970: 1_789_000_000)

    let store: AppStore
    let drafts = Drafts()
    let hub = PresentationHub(staleTimeout: 30)
    let presenter = Sink()

    init() {
        let drafts = drafts
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        store = AppStore(persistence: PersistenceStore(directory: dir), controlEventSink: { drafts.kinds.append($0.kind) })
    }

    @Test func aPageOpensOnAPresenterThatSpeaksPages() throws {
        let (session, _) = try origin()
        let page = try url("https://example.com/review/42?token=abc")
        var result: RemotePageOpen = .local

        #expect(treeChanges { result = open(session, page, size: 70) } == 1)

        #expect(result == .opened)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .pending)
        #expect(!session.overlayActive)
        let request = try #require(presenter.bodies.compactMap { if case .pageRequest(let r) = $0 { r } else { nil } }.first)
        #expect(request.page == page.id.uuidString)
        #expect(request.source == .url("https://example.com/review/42?token=abc"))
        #expect(request.sizePercent == 70)
        #expect(request.follow)
        #expect(UUID(uuidString: request.token) != nil)
        let node = try #require(store.htmlOverlayNodes(session, zoom: 1.5)?.first)
        #expect(node.remote == true)
        #expect(node.url == "https://example.com/review/42?token=abc")
        #expect(node.zoom == nil)
        #expect(store.remoteOverlayNodes(of: session) == [ControlRemoteOverlayNode(pane: nil, sizePercent: 70,
                                                                                   pageID: page.id.uuidString)])
    }

    @Test func aPresenterWithoutPageKindsKeepsTheRefusal() throws {
        let (session, _) = try origin(kinds: [])
        let page = file()

        #expect(open(session, page) == .unsupported)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == .presenter)
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(!session.overlayActive)
    }

    @Test(arguments: [ZmxLeadRole.leader, .unowned, nil] as [ZmxLeadRole?])
    func aPaneThatDoesNotFollowKeepsThePageHere(role: ZmxLeadRole?) throws {
        let (session, _) = try origin()
        setLead(role, pane: session.paneIdentity)
        let page = file()

        #expect(open(session, page) == .local)
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        #expect(session.htmlOverlayActive)
    }

    @Test func aSessionWidePageWithMixedRolesStaysHere() throws {
        let (session, _) = try origin(split: true)
        setLead(.leader, pane: try #require(session.splitPaneIdentity))

        #expect(open(session, file()) == .local)
        #expect(open(session, file(), pane: .left) == .opened)
    }

    @Test func pointSizesAreRefusedOnlyWhenThePageWouldGoToThePresenter() throws {
        let (session, _) = try origin()
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: 60,
                                                       backgroundColor: nil, points: OverlayPointSize(height: 240))
        let sent = presenter.frames.count

        #expect(store.openRemotePage(session.id, overlay: file(), options: options, now: Self.start) == .pointsUnsupported)
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(presenter.frames.count == sent)

        setLead(.leader, pane: session.paneIdentity)
        #expect(store.openRemotePage(session.id, overlay: file(), options: options, now: Self.start) == .local)
    }

    @Test func aLoopbackUrlIsRefusedOnlyWhenThePageWouldGoToThePresenter() throws {
        let (session, _) = try origin()
        #expect(open(session, try url("http://127.0.0.1:8080/")) == .loopback)
        setLead(.leader, pane: session.paneIdentity)
        #expect(open(session, try url("http://127.0.0.1:8080/")) == .local)
    }

    @Test func aRequestOverOneFrameIsRefusedBeforeAnythingChanges() throws {
        let (session, _) = try origin(split: true)
        let shown = file()
        #expect(open(session, shown, pane: .left) == .opened)
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 30, heightPercent: 8))
        let sent = presenter.frames.count
        let query = String(repeating: "q", count: PresentationCodec.maxFrameBytes)
        let page = try url("https://example.com/report?data=\(query)")

        var result: RemotePageOpen = .opened

        #expect(treeChanges { result = open(session, page) } == 0)

        #expect(result == .tooLarge)
        #expect(session.hudActive)
        #expect(presenter.frames.count == sent)
        #expect(hub.hasPresenter(session: session.id))
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id) == nil)
        #expect(session.remoteOverlays.slots.map(\.job) == [shown.id.uuidString])
    }

    @Test func aTakenSlotAndAMissingPaneAreRefused() throws {
        let (session, _) = try origin()
        #expect(open(session, file()) == .opened)
        #expect(open(session, file()) == .slotTaken)
        #expect(open(session, file(), pane: .right) == .paneMissing)
    }

    @Test func theMirroredStateIsReportedAndOnlyAHiddenChangeTouchesTheTree() throws {
        let (session, _) = try origin()
        let page = file()
        #expect(open(session, page) == .opened)

        #expect(treeChanges { report(page, session, title: "Review") } == 0)
        var node = try #require(store.htmlOverlayNodes(session, zoom: nil)?.first)
        #expect(node.title == "Review")
        #expect(node.page == "/tmp/docs/b.html")
        #expect(node.state == "loaded")
        #expect(node.hidden == nil)

        #expect(treeChanges { report(page, session, hidden: true) } == 1)
        node = try #require(store.htmlOverlayNodes(session, zoom: nil)?.first)
        #expect(node.hidden == true)
        #expect(session.hiddenOverlayNames == ["session"])
    }

    @Test func aPageReportFromAMirrorIsIgnored() throws {
        let (session, presenterID) = try origin()
        let page = file()
        #expect(open(session, page) == .opened)
        var forwarded: [PresentationFrame.Body] = []
        hub.onPresenterFrame = { _, body in forwarded.append(body) }
        let mirror = Sink()
        let mirrorID = try hub.subscribe(session: session.id, hello: PresentationHello(
            version: 1, kinds: PresentationHub.supportedKinds, mode: .mirror), sink: mirror) { PresentationSnapshot(status: nil, hud: nil) }
        let closed = PresentationFrame.Body.pageClosed(PresentationPageChange(page: page.id.uuidString))

        hub.receive(PresentationFrame(gen: mirror.frames[0].gen, rev: 1, body: closed), from: mirrorID)
        #expect(forwarded.isEmpty)
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 1, body: closed), from: try #require(presenterID))
        #expect(forwarded == [closed])
    }

    @Test func closingSendsTheCloseAndDismissesThePage() throws {
        let (session, _) = try origin()
        let page = file()
        #expect(open(session, page) == .opened)
        var ended: [UUID] = []
        RemotePageEnds.shared.onEnd = { ended.append($0) }
        defer { RemotePageEnds.shared.onEnd = nil }

        #expect(treeChanges { store.closeRemoteOverlay(session.id, pane: nil) } == 1)
        #expect(presenter.bodies.contains(.pageClose(PresentationPageChange(page: page.id.uuidString))))
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(ended == [page.id])
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .dismissed)
    }

    @Test func aSubmitRecordsTheAnswerAndALaterCloseKeepsIt() throws {
        let (session, _) = try origin()
        let page = file()
        #expect(open(session, page) == .opened)

        #expect(store.submitHtmlOverlay(session.id, pane: nil, value: "notes") == nil)
        store.receiveRemotePageFrame(.pageClosed(PresentationPageChange(page: page.id.uuidString)), forSession: session.id)

        let outcome = try #require(HtmlPageOutcomes.shared.outcome(for: page.id))
        #expect(outcome.outcome == .submitted)
        #expect(outcome.value == "notes")
        #expect(session.remoteOverlays.slots.isEmpty)
    }

    @Test func aRejectionEndsThePageDismissed() throws {
        let (session, _) = try origin()
        let page = file()
        #expect(open(session, page) == .opened)

        store.receiveRemotePageFrame(.pageRejected(PresentationPageChange(page: page.id.uuidString, reason: "slot taken")),
                                     forSession: session.id)
        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .dismissed)
    }

    @Test func losingThePresenterEndsThePageAndKeepsAnAcceptedAnswer() throws {
        let (session, presenterID) = try origin(split: true)
        let pending = file(), answered = file()
        #expect(open(session, pending) == .opened)
        #expect(open(session, answered, pane: .left) == .opened)
        HtmlPageOutcomes.shared.submit(answered.id, value: "kept")

        hub.unsubscribe(try #require(presenterID))

        #expect(session.remoteOverlays.slots.isEmpty)
        #expect(HtmlPageOutcomes.shared.outcome(for: pending.id)?.outcome == .dismissed)
        #expect(HtmlPageOutcomes.shared.outcome(for: answered.id)?.value == "kept")
    }

    @Test func removingTheSessionEndsItsPage() throws {
        let (session, _) = try origin()
        let page = file()
        #expect(open(session, page) == .opened)

        #expect(store.softCloseSession(session.id))
        #expect(presenter.bodies.contains(.pageClose(PresentationPageChange(page: page.id.uuidString))))
        #expect(HtmlPageOutcomes.shared.outcome(for: page.id)?.outcome == .dismissed)
    }

    @Test func twoTogglesBeforeAnyReportHideThenShow() throws {
        let (session, _) = try origin()
        #expect(open(session, file()) == .opened)

        #expect(store.applyOverlayVisibility(session.id, pane: nil, mode: .toggle) == nil)
        #expect(!session.anyOverlayShown(nil))
        #expect(store.applyOverlayVisibility(session.id, pane: nil, mode: .toggle) == nil)
        #expect(session.anyOverlayShown(nil))

        #expect(presenter.commands.map(\.action) == [.hide, .show])
        #expect(presenter.commands.map(\.seq) == [1, 2])
    }

    @Test func aStaleReportDoesNotOverrideANewerRequest() throws {
        let (session, _) = try origin()
        let page = file()
        #expect(open(session, page) == .opened)
        #expect(store.applyOverlayVisibility(session.id, pane: nil, mode: .hide) == nil)
        #expect(store.applyOverlayVisibility(session.id, pane: nil, mode: .show) == nil)

        report(page, session, hidden: true, seq: 1)
        #expect(session.anyOverlayShown(nil))
        #expect(store.applyOverlayVisibility(session.id, pane: nil, mode: .toggle) == nil)
        #expect(presenter.commands.last?.action == .hide)
    }

    @Test func aHideMadeOnThePresenterTurnsTheNextToggleIntoAShow() throws {
        let (session, _) = try origin()
        let page = file()
        #expect(open(session, page) == .opened)
        #expect(store.applyOverlayVisibility(session.id, pane: nil, mode: .hide) == nil)
        #expect(store.applyOverlayVisibility(session.id, pane: nil, mode: .show) == nil)
        #expect(presenter.commands.map(\.action) == [.hide, .show])
        let show = try #require(presenter.commands.last).seq
        report(page, session, hidden: false, seq: show)

        report(page, session, hidden: true, seq: show)
        #expect(store.applyOverlayVisibility(session.id, pane: nil, mode: .toggle) == nil)

        #expect(presenter.commands.map(\.action) == [.hide, .show, .show])
    }

    @Test func aRemoteProgramStillRefusesToHide() throws {
        let (session, _) = try origin()
        store.overlayJobs = OverlayJobs(now: { Self.start })
        let opened = store.openRemoteOverlay(session.id, options: ControlSessionOverlayOpenOptions(
            command: "revdiff", cwd: nil, wait: false, sizePercent: nil, backgroundColor: nil),
                                    context: OverlayLaunchContext(command: "revdiff", cwd: "/tmp", sessionEnvironment: [:]))
        guard case .opened = opened else { Issue.record("program was not handed over"); return }
        #expect(store.applyOverlayVisibility(session.id, pane: nil, mode: .hide) == .remote)
    }

    @Test func resizeReachesThePresenterAsACommand() throws {
        let (session, _) = try origin()
        #expect(open(session, file()) == .opened)

        #expect(store.resizeRemoteOverlay(session.id, sizePercent: 40) == true)
        #expect(presenter.commands.last == PresentationPageCommand(page: presenter.commands.last?.page ?? "", seq: 1,
                                                                   action: .resize, sizePercent: 40))
        #expect(store.remoteOverlayNodes(of: session)?.first?.sizePercent == 40)
    }

    @Test(arguments: [(HtmlNavigation.back, PresentationPageAction.back), (.forward, .forward), (.browser, .browser)])
    func aUrlPageNavigationReachesThePresenter(navigation: HtmlNavigation, action: PresentationPageAction) throws {
        let (session, _) = try origin()
        #expect(open(session, try url("https://example.com/a")) == .opened)

        #expect(store.navigateRemotePage(session.id, pane: nil, navigation: navigation) == .sent)

        #expect(presenter.commands.last?.action == action)
    }

    @Test func aFilePageGoesBackAndForwardButFinderAndBrowserAreRefused() throws {
        let (session, _) = try origin()
        #expect(open(session, file()) == .opened)

        #expect(store.navigateRemotePage(session.id, pane: nil, navigation: .back) == .sent)
        #expect(store.navigateRemotePage(session.id, pane: nil, navigation: .forward) == .sent)
        #expect(store.navigateRemotePage(session.id, pane: nil, navigation: .browser) == .refused(OverlayHtmlError.remotePage))
        #expect(store.navigateRemotePage(session.id, pane: nil, navigation: .finder) == .refused(OverlayHtmlError.remotePage))

        #expect(presenter.commands.map(\.action) == [.back, .forward])
    }

    @Test func finderOnAUrlPageGivesTheLocalAnswer() throws {
        let (session, _) = try origin()
        #expect(open(session, try url("https://example.com/a")) == .opened)

        #expect(store.navigateRemotePage(session.id, pane: nil, navigation: .finder) == .refused(OverlayHtmlError.finderRequiresFile))
        #expect(presenter.commands.isEmpty)
    }

    @Test(arguments: [false, true])
    func reloadReachesThePresenter(current: Bool) throws {
        let (session, _) = try origin()
        #expect(open(session, file()) == .opened)

        #expect(store.reloadRemotePage(session.id, pane: nil, current: current) == .sent)

        #expect(presenter.commands.last?.action == (current ? .reloadCurrent : .reloadOriginal))
    }

    @Test func aSlotWithoutARemotePageIsLeftToThisMac() throws {
        let (session, _) = try origin()

        #expect(store.navigateRemotePage(session.id, pane: nil, navigation: .back) == .local)
        #expect(store.reloadRemotePage(session.id, pane: nil, current: false) == .local)
    }

    @Test func aReservationWhoseStreamIsGoneRefusesWithoutReopening() throws {
        let (session, presenterID) = try origin()
        #expect(open(session, file()) == .opened)
        hub.onPresenterLost = nil
        hub.unsubscribe(try #require(presenterID))

        #expect(store.reloadRemotePage(session.id, pane: nil, current: false) == .refused(OverlayResultError.viewerGone))
        #expect(store.navigateRemotePage(session.id, pane: nil, navigation: .back) == .refused(OverlayResultError.viewerGone))
        #expect(!session.overlayActive)
    }

    @Test func aPageThePresenterLossEndedLeavesNoOverlay() throws {
        let (session, presenterID) = try origin()
        #expect(open(session, file()) == .opened)
        hub.unsubscribe(try #require(presenterID))

        #expect(store.navigateRemotePage(session.id, pane: nil, navigation: .back) == .local)
        #expect(store.htmlOverlayCommandFailure(session.id, pane: nil) == .noOverlay)
        #expect(!session.overlayActive)
    }

    @Test func aTokenClaimsOnceWithinItsDeadlineForTheSamePresenter() throws {
        let (session, _) = try origin()
        let page = file()
        #expect(open(session, page) == .opened)
        let token = try requestToken()

        #expect(store.claimRemotePage(token: UUID().uuidString, now: Self.start) == nil)
        let claim = try #require(store.claimRemotePage(token: token, now: Self.start.addingTimeInterval(5)))
        #expect(claim == RemotePageClaim(sessionID: session.id, pane: nil, overlay: page))
        #expect(store.claimRemotePage(token: token, now: Self.start.addingTimeInterval(6)) == nil)
    }

    @Test func aLateClaimIsRefusedAndExpiryEndsOnlyAnUnclaimedFilePage() throws {
        let (session, _) = try origin(split: true)
        let filePage = file(), webPage = try url("https://example.com/")
        #expect(open(session, filePage) == .opened)
        let token = try requestToken()
        #expect(open(session, webPage, pane: .left) == .opened)
        let late = Self.start.addingTimeInterval(AppStore.pageClaimWindow + 1)

        #expect(store.claimRemotePage(token: token, now: late) == nil)
        store.expireRemotePageClaims(now: late)

        #expect(session.remoteOverlays.slot(nil) == nil)
        #expect(session.remoteOverlays.slot(.left)?.page?.overlay.id == webPage.id)
        #expect(HtmlPageOutcomes.shared.outcome(for: filePage.id)?.outcome == .dismissed)
    }

    private func origin(kinds: [String] = PresentationHub.supportedKinds,
                        split: Bool = false) throws -> (Session, PresentationHub.SubscriberID?) {
        store.presentationHub = hub
        hub.onPresenterLost = { [store] in store.remoteOverlayPresenterLost(forSession: $0) }
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        if split {
            store.toggleSplit(session.id)
            session.surface = SpySurface(paneToken: "left")
            session.splitSurface = SpySurface(paneToken: "right")
        }
        setLead(.follower, pane: session.paneIdentity)
        if let pane = session.splitPaneIdentity { setLead(.follower, pane: pane) }
        let hello = PresentationHello(version: 1, kinds: kinds, mode: .presenter)
        let id = try hub.subscribe(session: session.id, hello: hello, sink: presenter) { PresentationSnapshot(status: nil, hud: nil) }
        hub.receive(PresentationFrame(gen: presenter.frames[0].gen, rev: 0, body: .presenterAcquire), from: id)
        return (session, id)
    }

    private func open(_ session: Session, _ page: HtmlOverlay, pane: OverlayPane? = nil, size: Int? = nil) -> RemotePageOpen {
        store.openRemotePage(session.id, overlay: page, options: ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: size, backgroundColor: nil, follow: true, pane: pane),
                             now: Self.start)
    }

    private func file() -> HtmlOverlay {
        HtmlOverlay(source: .file(path: "/tmp/docs/index.html", grantRoot: "/tmp/docs"), javascript: true)
    }

    private func url(_ address: String) throws -> HtmlOverlay {
        HtmlOverlay(source: .url(try #require(URL(string: address))))
    }

    private func report(_ page: HtmlOverlay, _ session: Session, title: String? = nil, hidden: Bool = false, seq: Int = 0) {
        store.receiveRemotePageFrame(.pageState(PresentationPageState(
            page: page.id.uuidString, title: title, address: "/tmp/docs/b.html", load: .loaded, error: nil, canGoBack: true,
            canGoForward: false, hidden: hidden, appliedSeq: seq)), forSession: session.id)
    }

    private func requestToken() throws -> String {
        try #require(presenter.bodies.compactMap { if case .pageRequest(let r) = $0 { r.token } else { nil } }.last)
    }

    private func treeChanges(during action: () -> Void) -> Int {
        let before = drafts.kinds.filter { $0 == .treeChanged }.count
        action()
        return drafts.kinds.filter { $0 == .treeChanged }.count - before
    }

    private func setLead(_ role: ZmxLeadRole?, pane: UUID) {
        let attachment = ZmxLeadAttachment(claim: false)
        ZmxLeadBook.shared.begin(attachment, pane: pane)
        if let role, let notice = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(role.rawValue):1") {
            _ = ZmxLeadBook.shared.apply(notice, pane: pane)
        }
    }
}
