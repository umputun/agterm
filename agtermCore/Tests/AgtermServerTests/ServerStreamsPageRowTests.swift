import Foundation
import Testing
@testable import AgtermServerKit
@testable import agtermCore

/// Page rows: their attached views and the asks and picks their presenter answers.
extension ServerStreamsTests {
    private func pageRow() async throws -> Session {
        let path = harness.scratch.root + "/row.html"
        try Data("<p>row</p>".utf8).write(to: URL(fileURLWithPath: path))
        var args = ControlArgs()
        args.html = path
        let anchor = try newSession()
        return try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionPage, target: anchor.id.uuidString,
                                                                              args: args)))
    }

    private func view(_ row: Session) throws -> LogClient {
        let offer = harness.actions.attachCompanionPage(row.id.uuidString, window: nil)
        let token = try #require(offer.result?.companionPage?.token, "\(offer)")
        let claimed = streams.claimPageStream(token)
        let claim = try #require(claimed.result?.id.flatMap(UUID.init(uuidString:)), "\(claimed)")
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &pair) == 0)
        streams.adoptPageServeStream(descriptor: pair[0], page: claim, token: token)
        return LogClient(fd: pair[1])
    }

    private func bridge(_ client: LogClient, _ request: String) async throws -> PageServeFrame? {
        try await offPool { () throws -> PageServeFrame? in
            try client.send(.bridge(id: 1, request: request))
            return client.frame()
        }
    }

    @Test func anAttachmentTokenIsClaimedOnceAndExpires() async throws {
        let row = try await pageRow()
        let terminal = try newSession()
        let now = Date()
        streams.now = { now }
        let first = try #require(harness.actions.attachCompanionPage(row.id.uuidString, window: nil).result?.companionPage)
        let late = try #require(harness.actions.attachCompanionPage(row.id.uuidString, window: nil).result?.companionPage)

        #expect(streams.claimPageStream(first.token).ok)
        #expect(streams.claimPageStream(first.token) == ControlResponse(ok: false, error: "page not claimable"))
        streams.now = { now.addingTimeInterval(AppStore.pageClaimWindow + 1) }
        #expect(streams.claimPageStream(late.token) == ControlResponse(ok: false, error: "page not claimable"))
        #expect(first.page == row.htmlOverlay?.id.uuidString)
        #expect(harness.actions.attachCompanionPage(terminal.id.uuidString, window: nil)
            == ControlResponse(ok: false, error: "not a page session"))
    }

    @Test func twoViewsAreServedAtOnceAndBridgeRequestsRunOnTheServer() async throws {
        let row = try await pageRow()
        let first = try view(row)
        let second = try view(row)
        #expect(await eventually { streams.pageAttachments.streams.count == 2 })

        let renamed = try await bridge(first, #"{"cmd":"session.rename","args":{"name":"docs"}}"#)
        let typed = try await bridge(second, #"{"cmd":"session.type","args":{"text":"ls"}}"#)

        guard case .reply(1, let renameReply)? = renamed, case .reply(1, let typeReply)? = typed else {
            Issue.record("no bridge replies: \(String(describing: renamed)), \(String(describing: typed))")
            return
        }
        #expect(try JSONDecoder().decode(ControlResponse.self, from: Data(renameReply.utf8)).ok)
        #expect(row.displayName == "docs")
        #expect(try JSONDecoder().decode(ControlResponse.self, from: Data(typeReply.utf8)).error
            == "session.type: not available on a page session")
    }

    @Test func closingThePageRowEndsEveryView() async throws {
        let row = try await pageRow()
        let first = try view(row)
        let second = try view(row)
        #expect(await eventually { streams.pageAttachments.streams.count == 2 })

        _ = harness.actions.closeSession(row.id.uuidString, window: nil)

        let ends = await offPool { (first.frame(), second.frame()) }
        #expect(ends.0 == nil && ends.1 == nil)
        #expect(await eventually { streams.pageAttachments.streams.isEmpty })
    }

    @Test func stoppingTheServerEndsEveryViewAndKeepsThePageRow() async throws {
        let row = try await pageRow()
        let first = try view(row)
        let second = try view(row)
        #expect(await eventually { streams.pageAttachments.streams.count == 2 })

        streams.shutdown()

        #expect(await eventually { streams.pageAttachments.streams.isEmpty })
        let ends = await offPool { (first.frame(), second.frame()) }
        #expect(ends.0 == nil && ends.1 == nil)
        #expect(harness.store.session(withID: row.id) === row)
        #expect(row.htmlOverlay != nil)
    }

    private func pagePresenter(for row: Session) async throws -> Viewer {
        let request = ControlRequest(cmd: .zmxPresent, target: row.id.uuidString)
        let reply = await harness.actions.serve(request)
        #expect(reply.ok, "\(reply)")
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        #expect(streams.adopt(fds[0], request: request, response: reply, written: true))
        let viewer = Viewer(fd: fds[1])
        try viewer.send(.hello(PresentationHello(version: PresentationCodec.version, kinds: PresentationHub.supportedKinds,
                                                 mode: .presenter)))
        let snapshot = await offPool { viewer.first { if case .snapshot = $0 { true } else { false } } }
        guard case .snapshot(let shown)? = snapshot else { Issue.record("no snapshot"); return viewer }
        #expect(shown.layout == nil)
        try viewer.send(.presenterAcquire)
        let granted = await offPool { viewer.first { $0 == .presenterGranted || $0 == .presenterRefused } }
        #expect(granted == .presenterGranted)
        return viewer
    }

    private static func guiAsk() -> PendingAsk {
        PendingAsk(id: UUID().uuidString, title: "publish?", buttons: [ControlAskButton(id: "yes", label: "Yes")], style: .gui)
    }

    @Test func aGuiAskHeldOnAPageRowReachesItsPresenterAndItsAnswerSettles() async throws {
        let row = try await pageRow()
        var args = ControlArgs()
        args.title = "publish?"
        args.buttons = [ControlAskButton(id: "yes", label: "Yes")]
        args.style = "gui"
        let opened = await harness.actions.serve(ControlRequest(cmd: .askOpen, target: row.id.uuidString, args: args))
        let id = try #require(opened.result?.id, "\(opened)")

        let viewer = try await pagePresenter(for: row)
        defer { viewer.disconnect() }

        let offered = await offPool { viewer.first { if case .askRequest = $0 { true } else { false } } }
        guard case .askRequest(let shown)? = offered else { Issue.record("no ask offer"); return }
        #expect(shown.id == id)
        #expect(shown.pane == nil)
        try viewer.send(.askResolve(PresentationAskAnswer(id: shown.id, owner: shown.owner, button: "yes", offer: shown.offer)))
        #expect(await eventually { askOutcome(id)?.id == "yes" })
    }

    @Test func aCancelledAskOnAPageRowIsWithdrawnFromItsPresenter() async throws {
        let row = try await pageRow()
        let viewer = try await pagePresenter(for: row)
        defer { viewer.disconnect() }
        let ask = Self.guiAsk()
        #expect(openAsk(ask, on: row).ok)
        #expect(await offPool { viewer.first { if case .askRequest = $0 { true } else { false } } } != nil)

        #expect(harness.actions.cancelAsk(ask.id, window: nil).ok)

        let dismiss = await offPool { viewer.first { if case .askDismiss = $0 { true } else { false } } }
        guard case .askDismiss(let ref)? = dismiss else { Issue.record("no ask dismiss"); return }
        #expect(ref.id == ask.id)
        #expect(askOutcome(ask.id)?.result == .cancelled)
    }

    @Test func aPickOnAPageRowIsAnsweredByItsPresenter() async throws {
        let row = try await pageRow()
        let viewer = try await pagePresenter(for: row)
        defer { viewer.disconnect() }
        let pick = PendingPick(id: UUID().uuidString, items: [ControlPickItem(id: "a", label: "A")])

        #expect(harness.actions.openPick(pick, session: row.id.uuidString, window: nil, follow: false).ok)
        let request = await offPool { viewer.first { if case .pickRequest = $0 { true } else { false } } }
        guard case .pickRequest(let shown)? = request else { Issue.record("no pick request"); return }
        try viewer.send(.pickResolve(PresentationPickAnswer(id: shown.id, owner: shown.owner, item: "a", offer: shown.offer)))

        #expect(await eventually { harness.actions.pickResult(pick.id, window: nil).result?.pick?.result == .picked })
    }

    @Test func aPageRowsPresenterLeavingKeepsItsViewAndHandsTheAskToTheNext() async throws {
        let row = try await pageRow()
        let view = try view(row)
        #expect(await eventually { streams.pageAttachments.streams.count == 1 })
        let first = try await pagePresenter(for: row)
        let ask = Self.guiAsk()
        #expect(openAsk(ask, on: row).ok)
        #expect(await offPool { first.first { if case .askRequest = $0 { true } else { false } } } != nil)

        await drop(first, from: row)

        #expect(await eventually { row.askPending?.id == ask.id && !row.askPresentedRemotely })
        #expect(streams.pageAttachments.streams.count == 1)
        let next = try await pagePresenter(for: row)
        defer { next.disconnect() }
        let offered = await offPool { next.first { if case .askRequest = $0 { true } else { false } } }
        guard case .askRequest(let shown)? = offered else { Issue.record("no ask offer"); return }
        #expect(shown.id == ask.id)
        let renamed = try await bridge(view, #"{"cmd":"session.rename","args":{"name":"still served"}}"#)
        guard case .reply(1, let reply)? = renamed else { Issue.record("no bridge reply: \(String(describing: renamed))"); return }
        #expect(try JSONDecoder().decode(ControlResponse.self, from: Data(reply.utf8)).ok)
    }
}
