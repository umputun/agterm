import XCTest
@testable import agterm
import agtermCore

private let child = "0E2B7C1A-5D4F-4E3B-9A61-7C2D8F0B1A23"
private let other = "6C1D2E3F-4A5B-4C6D-8E7F-9A0B1C2D3E4F"
private let pageRoot = "3B2A1C0D-9E8F-4A7B-8C6D-5E4F3A2B1C0D"

@MainActor
final class ControlServerFollowCompanionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx", socketDirectory: "/tmp/agterm-zmx-abc")

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-follow-companion-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
    }

    override func tearDown() async throws {
        settings = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    func testANewTerminalCompanionAttachesUnderTheRowWithoutTheLeadOrTheSelection() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session(child, parent: "origin-1")) }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        let selected = store.selectedSessionID
        let stream = try open(row, server: server, transport: transport)

        stream.send(.snapshot(PresentationSnapshot(status: nil, hud: nil, companions: list([child]))))
        let attached = try await companion(of: row, in: store)

        XCTAssertEqual(attached.remoteSessionID, child)
        XCTAssertEqual(attached.remoteHost, "buildbox")
        XCTAssertEqual(ZmxLeadBook.shared.states[attached.paneIdentity]?.attachment.claim, false)
        XCTAssertEqual(store.selectedSessionID, selected)
        XCTAssertTrue(row.followedCompanions.contains(child))
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testANewPageCompanionAttachesUnderTheRow() async throws {
        let runner = RoutedRunner { argv in Origin.pageAttach(argv) ? Origin.pageReply(parent: "origin-1") : Origin.tree(sessions: "") }
        let (server, store, transport) = makeServer(runner)
        server.pageLauncher = FakePageLauncher()
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child], kind: .page)))
        let page = try await companion(of: row, in: store)

        XCTAssertEqual(page.content, .page)
        XCTAssertEqual(page.remoteSessionID, child)
        XCTAssertTrue(row.followedCompanions.contains(child))
    }

    func testACompanionClosedHereIsNotAttachedAgainByEitherCopyNorOneAttachedByHand() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session("origin-1", companions: [child, other]) + "," + Origin.session(child, parent: "origin-1")
                                                     + "," + Origin.session(other, parent: "origin-1")) }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        let copy = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)
        stream.send(.companions(list([child])))
        let followed = try await companion(of: row, in: store)
        let byHand = await server.attachRemoteSession(host: "buildbox", session: other, window: nil)
        XCTAssertTrue(byHand.ok, byHand.error ?? "")
        _ = store.closeSession(followed.id)
        _ = store.closeSession(try XCTUnwrap(byHand.result?.id.flatMap(UUID.init(uuidString:))))
        let calls = runner.invocations.count

        stream.send(.companions(list([child, other])))
        let copyStream = try open(copy, server: server, transport: transport)
        copyStream.send(.snapshot(PresentationSnapshot(status: nil, hud: nil, companions: list([child, other]))))
        await settled(server, rows: [row, copy])

        XCTAssertTrue(store.companions(of: row.id).isEmpty)
        XCTAssertTrue(store.companions(of: copy.id).isEmpty)
        XCTAssertEqual(runner.invocations.count, calls)
        XCTAssertTrue(copy.followedCompanions.isSuperset(of: [child, other]))
    }

    func testTwoCopiesGetOneRowInTotalForATerminalAndForTwoPageOffersInFlight() async throws {
        for kind in [PresentationCompanions.Member.Kind.terminal, .page] {
            let runner = RoutedRunner { argv in
                Origin.pageAttach(argv) ? Origin.pageReply(parent: "origin-1") : Origin.tree(sessions: Origin.session(child, parent: "origin-1"))
            }
            let (server, store, transport) = makeServer(runner)
            server.pageLauncher = FakePageLauncher()
            let row = try parentRow(in: store)
            let copy = try parentRow(in: store)
            let streams = try [open(row, server: server, transport: transport), open(copy, server: server, transport: transport)]

            for stream in streams { stream.send(.companions(list([child], kind: kind))) }
            await settled(server, rows: [row, copy])

            XCTAssertEqual(store.companions(of: row.id).count + store.companions(of: copy.id).count, 1, "\(kind)")
            XCTAssertTrue(row.followedCompanions.contains(child), "\(kind)")
            XCTAssertTrue(copy.followedCompanions.contains(child), "\(kind)")
            server.stopRemotePresentations()
            for session in store.workspaces.flatMap(\.sessions) where session.remoteHost != nil { _ = store.closeSession(session.id) }
        }
    }

    func testATransportFailureRetriesOnTheBackoffWithoutANewList() async throws {
        let online = Flag()
        let runner = RoutedRunner { _ in
            online.value ? Origin.tree(sessions: Origin.session(child, parent: "origin-1")) : RemoteCommandResult(status: 255, stdout: "", stderr: "unreachable")
        }
        let (server, store, transport) = makeServer(runner)
        advancingClock(server)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child])))
        await settled(server, rows: [row])
        XCTAssertNotNil(server.companionFollow.rows[row.id]?.retries[child])
        XCTAssertTrue(store.companions(of: row.id).isEmpty)

        online.value = true
        server.tickCompanionFollow()
        _ = try await companion(of: row, in: store)
        XCTAssertNil(server.companionFollow.rows[row.id]?.retries[child])
    }

    func testAPageReceiptOverAFailedConnectionIsRetried() async throws {
        let online = Flag()
        let runner = RoutedRunner { _ in
            var reply = Origin.pageReply(parent: "origin-1")
            if !online.value { reply = RemoteCommandResult(status: 255, stdout: reply.stdout, stderr: "connection closed") }
            return reply
        }
        let (server, store, transport) = makeServer(runner)
        server.pageLauncher = FakePageLauncher()
        advancingClock(server)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child], kind: .page)))
        await settled(server, rows: [row])
        XCTAssertNotNil(server.companionFollow.rows[row.id]?.retries[child])

        online.value = true
        server.tickCompanionFollow()
        let page = try await companion(of: row, in: store)
        XCTAssertEqual(page.content, .page)
    }

    func testTheOriginsLoopbackRefusalIsFinal() async throws {
        let refusal = RemoteCommandResult(status: 1, stdout: #"{"ok":false,"error":"\#(PageAttachmentBook.loopbackRefusal)"}"#, stderr: "")
        let runner = RoutedRunner { _ in refusal }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child], kind: .page)))
        await settled(server, rows: [row])
        stream.send(.companions(list([child, other], kind: .page)))
        await settled(server, rows: [row])

        XCTAssertTrue(row.followedCompanions.contains(child))
        XCTAssertEqual(runner.invocations.filter { $0.joined(separator: " ").contains(child) }.count, 1)
    }

    func testAPageThisMacCannotHoldIsFinalAndAClearInProgressIsRetried() {
        let loopback = page(source: .url("http://127.0.0.1:3000"), persistent: false)
        let saved = page(source: .url("https://app.example.com"), persistent: true)

        XCTAssertEqual(ControlServer.pageRefusal(loopback, profileFailure: { nil }), .handled)
        XCTAssertEqual(ControlServer.pageRefusal(saved, profileFailure: { BrowserClearError.clearing }), .retry)
        XCTAssertEqual(ControlServer.pageRefusal(saved, profileFailure: { "the browser profile id is unreadable" }), .handled)
        XCTAssertNil(ControlServer.pageRefusal(saved, profileFailure: { nil }))
        XCTAssertNil(ControlServer.pageRefusal(page(source: .url("https://app.example.com"), persistent: false), profileFailure: { "x" }))
    }

    func testAChildThatNeverBecomesAttachableIsParkedUntilTheNextList() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: "") }
        let (server, store, transport) = makeServer(runner)
        advancingClock(server)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child])))
        await settled(server, rows: [row])
        let polls = runner.invocations.count
        XCTAssertGreaterThan(polls, 0)
        XCTAssertTrue(server.companionFollow.rows[row.id]?.parked.contains(child) == true)

        server.tickCompanionFollow()
        await settled(server, rows: [row])
        XCTAssertEqual(runner.invocations.count, polls)

        stream.send(.companions(list([child])))
        await settled(server, rows: [row])
        XCTAssertGreaterThan(runner.invocations.count, polls)
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
        XCTAssertFalse(row.followedCompanions.contains(child))
    }

    func testAChildMovedAwayOnTheOriginIsNotAttachedUnderTheOldParent() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session(child, parent: "origin-2")) }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child])))
        await settled(server, rows: [row])

        XCTAssertTrue(store.companions(of: row.id).isEmpty)
        XCTAssertTrue(server.companionFollow.rows[row.id]?.parked.contains(child) == true)
    }

    func testTheUsersOwnNewCompanionIsPlacedOnceAndNoCopyAttachesIt() async throws {
        let created = Flag()
        let runner = RoutedRunner { argv in
            let line = argv.joined(separator: " ")
            if line.contains("--parent") {
                created.value = true
                return RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"id":"\#(child)","parent":"origin-1"}}"#, stderr: "")
            }
            return Origin.tree(sessions: Origin.session("origin-1") + (created.value ? "," + Origin.session(child, parent: "origin-1") : ""))
        }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        let copy = try parentRow(in: store)
        let streams = try [open(row, server: server, transport: transport), open(copy, server: server, transport: transport)]

        let reply = await server.createCompanion(row.id.uuidString, options: CompanionOptions(select: true, tint: SidebarTint(color: .red)),
                                                 window: nil)
        XCTAssertTrue(reply.ok, reply.error ?? "")
        for stream in streams { stream.send(.companions(list([child]))) }
        await settled(server, rows: [row, copy])

        let mine = try XCTUnwrap(store.companions(of: row.id).first)
        XCTAssertEqual(store.companions(of: row.id).count, 1)
        XCTAssertTrue(store.companions(of: copy.id).isEmpty)
        XCTAssertEqual(store.selectedSessionID, mine.id)
        XCTAssertEqual(mine.tint, SidebarTint(color: .red))
        XCTAssertEqual(ZmxLeadBook.shared.states[mine.paneIdentity]?.attachment.claim, true)
        XCTAssertTrue(copy.followedCompanions.contains(child))
    }

    func testAHeldOriginFollowsNothingUntilTheHoldIsReleased() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session(child, parent: "origin-1")) }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)
        let hold = server.holdCompanionFollow(OriginKey(host: "buildbox", endpoint: endpoint, session: "origin-1"))

        stream.send(.companions(list([child])))
        await settled(server, rows: [row])
        XCTAssertTrue(runner.invocations.isEmpty)

        server.releaseCompanionFollow(hold)
        _ = try await companion(of: row, in: store)
    }

    func testAPlainAttachSeedsTheExistingCompanionsWhileAGroupAttachStillAttachesThem() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session("origin-1", companions: [child]) + "," + Origin.session(child, parent: "origin-1")) }
        let (server, store, transport) = makeServer(runner)

        let plain = await server.attachRemoteSession(host: "buildbox", session: "origin-1", window: nil)
        let row = try XCTUnwrap(plain.result?.id.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)))
        XCTAssertTrue(row.companionsBaselined)
        XCTAssertEqual(row.followedCompanions, [child])
        let calls = runner.invocations.count
        try XCTUnwrap(transport.lines.last)(try frame(.hello(PresentationHello(version: 1, kinds: [PresentationHub.companionsKind], mode: .mirror)), rev: 0))
        try XCTUnwrap(transport.lines.last)(try frame(.snapshot(PresentationSnapshot(status: nil, hud: nil, companions: list([child]))), rev: 1))
        await settled(server, rows: [row])
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
        XCTAssertEqual(runner.invocations.count, calls)

        let group = await server.attachRemoteGroup(host: "buildbox", session: "origin-1", window: nil)
        let grouped = try XCTUnwrap(group.result?.id.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(store.companions(of: grouped).map(\.remoteSessionID), [child])
    }

    func testAnAttachTimeTreeWithoutMembershipLeavesTheRowToBaselineOnItsFirstList() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session("origin-1") + "," + Origin.session(child, parent: "origin-1")) }
        let (server, store, transport) = makeServer(runner)

        let plain = await server.attachRemoteSession(host: "buildbox", session: "origin-1", window: nil)
        let row = try XCTUnwrap(plain.result?.id.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)))
        XCTAssertFalse(row.companionsBaselined)
        let calls = runner.invocations.count
        try XCTUnwrap(transport.lines.last)(try frame(.hello(PresentationHello(version: 1, kinds: [PresentationHub.companionsKind], mode: .mirror)), rev: 0))
        try XCTUnwrap(transport.lines.last)(try frame(.companions(list([child])), rev: 1))
        await settled(server, rows: [row])

        XCTAssertTrue(row.companionsBaselined)
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
        XCTAssertEqual(runner.invocations.count, calls)
    }

    func testARowWithASavedSetAttachesWhatIsNewAndLeavesWhatItDetachedAlone() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session(child, parent: "origin-1") + "," + Origin.session(other, parent: "origin-1")) }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store, handled: [other])
        let stream = try open(row, server: server, transport: transport)

        stream.send(.snapshot(PresentationSnapshot(status: nil, hud: nil, companions: list([other, child]))))
        await settled(server, rows: [row])

        XCTAssertEqual(store.companions(of: row.id).map(\.remoteSessionID), [child])
    }

    func testAServerWindowsRowIgnoresTheMembership() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session(child, parent: "origin-1")) }
        let (server, store, _) = makeServer(runner)
        let row = try parentRow(in: store, catalogOwned: true)

        server.applyOriginCompanions(list([child]), forSession: row.id)
        await settled(server, rows: [row])

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
        XCTAssertEqual(row.remotePresentation?.followsCompanions, false)
    }

    func testAFollowedChildOfAServerOpensItsOwnPresentationStream() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session(child, parent: "origin-1"), headless: true) }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child])))
        let attached = try await companion(of: row, in: store)

        XCTAssertNotNil(server.remoteClients[attached.id])
        XCTAssertEqual(transport.lines.count, 2)
    }

    func testARefusalThatReturnsAfterANewerListDoesNotParkTheChildThatListWoke() async throws {
        let gate = Gate()
        let calls = Counter()
        let routed = RoutedRunner(gate: gate) { argv in
            guard Origin.pageAttach(argv) else { return Origin.tree(sessions: "") }
            calls.bump()
            return calls.value == 1 ? RemoteCommandResult(status: 1, stdout: #"{"ok":false,"error":"the page is not offered now"}"#, stderr: "")
                : Origin.pageReply(parent: "origin-1")
        }
        let (server, store, transport) = makeServer(routed)
        server.pageLauncher = FakePageLauncher()
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child], kind: .page)))
        try await waitUntil { gate.reached }
        stream.send(.companions(list([child], kind: .page)))
        gate.open()

        let page = try await companion(of: row, in: store)
        XCTAssertEqual(page.content, .page)
        XCTAssertFalse(server.companionFollow.rows[row.id]?.parked.contains(child) == true)
    }

    func testALostStreamFollowsNothingUntilItsReconnectSnapshot() async throws {
        let gate = Gate()
        let runner = RoutedRunner(gate: gate) { _ in Origin.tree(sessions: Origin.session(child, parent: "origin-1")) }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child])))
        try await waitUntil { gate.reached }
        try XCTUnwrap(transport.closes.last)("connection lost")
        gate.open()
        await settled(server, rows: [row])
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
        XCTAssertNil(server.companionFollow.rows[row.id]?.list)
        XCTAssertEqual(row.remotePresentation?.followsCompanions, false)

        let client = try XCTUnwrap(server.remoteClients[row.id])
        client.retryNow()
        client.tick()
        let line = try XCTUnwrap(transport.lines.last)
        line(try frame(.hello(PresentationHello(version: 1, kinds: [PresentationHub.companionsKind], mode: .mirror)), rev: 0))
        line(try frame(.snapshot(PresentationSnapshot(status: nil, hud: nil, companions: list([child]))), rev: 1))
        _ = try await companion(of: row, in: store)
        XCTAssertEqual(row.remotePresentation?.followsCompanions, true)
    }

    func testAnOriginWhoseHelloLeavesOutTheKindFollowsNothingEvenWithAListInItsSnapshot() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session(child, parent: "origin-1")) }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        server.startRemotePresentation(for: row)
        let line = try XCTUnwrap(transport.lines.last)

        line(try frame(.hello(PresentationHello(version: 1, kinds: ["status"], mode: .mirror)), rev: 0))
        line(try frame(.snapshot(PresentationSnapshot(status: nil, hud: nil, companions: list([child]))), rev: 1))
        await settled(server, rows: [row])

        XCTAssertEqual(row.remotePresentation?.connection, .connected)
        XCTAssertEqual(row.remotePresentation?.followsCompanions, false)
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
    }

    func testARetryForAChildTheListNoLongerNamesIsDropped() async throws {
        let runner = RoutedRunner { _ in RemoteCommandResult(status: 255, stdout: "", stderr: "unreachable") }
        let (server, store, transport) = makeServer(runner)
        advancingClock(server)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)
        stream.send(.companions(list([child])))
        await settled(server, rows: [row])
        XCTAssertNotNil(server.companionFollow.rows[row.id]?.retries[child])

        stream.send(.companions(list([])))
        await settled(server, rows: [row])

        XCTAssertEqual(server.companionFollow.rows[row.id]?.retries.isEmpty, true)
    }

    func testAChildTheTreeSpellsInLowercaseIsStillAttached() async throws {
        let runner = RoutedRunner { _ in Origin.tree(sessions: Origin.session(child.lowercased(), parent: "origin-1")) }
        let (server, store, transport) = makeServer(runner)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child])))
        _ = try await companion(of: row, in: store)

        XCTAssertTrue(row.followedCompanions.contains(child))
    }

    func testAPageWhoseHelperFailsToStartIsRemovedAtOnceAndAttachedOnRetry() async throws {
        let runner = RoutedRunner { argv in Origin.pageAttach(argv) ? Origin.pageReply(parent: "origin-1") : Origin.tree(sessions: "") }
        let (server, store, transport) = makeServer(runner)
        let launcher = FakePageLauncher()
        launcher.failsNextLaunch = true
        server.pageLauncher = launcher
        advancingClock(server)
        let row = try parentRow(in: store)
        let stream = try open(row, server: server, transport: transport)

        stream.send(.companions(list([child], kind: .page)))
        await settled(server, rows: [row])
        XCTAssertTrue(store.companions(of: row.id).isEmpty)
        XCTAssertNotNil(server.companionFollow.rows[row.id]?.retries[child])
        XCTAssertFalse(row.followedCompanions.contains(child))
        XCTAssertTrue(library.remoteRecentClosedItems.isEmpty)

        server.tickCompanionFollow()
        let page = try await companion(of: row, in: store)
        XCTAssertEqual(page.content, .page)
        await settled(server, rows: [row])
        XCTAssertEqual(store.companions(of: row.id).count, 1)
        XCTAssertTrue(library.remoteRecentClosedItems.isEmpty)
    }

    func testAnExplicitPageAttachWhoseHelperFailsMarksNoCopy() async throws {
        let runner = RoutedRunner { argv in Origin.pageAttach(argv) ? Origin.pageReply(parent: "origin-1") : Origin.tree(sessions: "") }
        let (server, store, _) = makeServer(runner)
        let launcher = FakePageLauncher()
        launcher.failsNextLaunch = true
        server.pageLauncher = launcher
        let row = try parentRow(in: store)
        let copy = try parentRow(in: store)

        _ = await server.attachRemotePage(child, origin: RemoteBinding.Origin(host: "buildbox", endpoint: endpoint, sessionName: child),
                                          presentation: ControlServer.PagePresentation(version: 1, headless: false), at: .companion(of: row.id),
                                          select: false)

        XCTAssertFalse(copy.followedCompanions.contains(child))
        XCTAssertFalse(row.followedCompanions.contains(child))
    }

    func testAPageRootAttachedFromAMacFollowsItsMembershipThroughAnObserverAndKeepsItsRowState() async throws {
        let listed = Flag()
        let runner = RoutedRunner { argv in
            if Origin.pageAttach(argv) { return Origin.pageReply(parent: nil) }
            let listedChild = listed.value ? "," + Origin.session(child, parent: pageRoot) : ""
            return Origin.tree(sessions: Origin.pageRootEntry(companions: []) + listedChild)
        }
        let (server, store, transport) = makeServer(runner)
        server.pageLauncher = FakePageLauncher()

        let attached = await server.attachRemoteSession(host: "buildbox", session: pageRoot, window: nil)
        XCTAssertTrue(attached.ok, attached.error ?? "")
        let root = try XCTUnwrap(attached.result?.id.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)))

        XCTAssertEqual(transport.hellos.last, PresentationHello(version: PresentationCodec.version, kinds: RemotePresentationClient.observerKinds,
                                                                mode: .mirror))
        let line = try XCTUnwrap(transport.lines.last)
        line(try frame(.hello(PresentationHello(version: 1, kinds: RemotePresentationClient.observerKinds, mode: .mirror)), rev: 0))
        line(try frame(.snapshot(PresentationSnapshot(status: nil, hud: nil, companions: list([]))), rev: 1))
        listed.value = true
        line(try frame(.companions(list([child])), rev: 2))
        let followed = try await companion(of: root, in: store)

        XCTAssertEqual(followed.remoteSessionID, child)
        XCTAssertEqual(root.remotePresentation?.connection, .unsupported)
        XCTAssertEqual(root.remotePresentation?.followsCompanions, true)
        XCTAssertNil(root.remoteRowNotice)
    }

    func testAPageRootObserverRestartsWithTheRowAndAnEndedOrRefusingOriginLeavesTheRowAlone() throws {
        for kinds in [RemotePresentationClient.observerKinds, [PresentationHub.endedKind]] {
            let (server, store, transport) = makeServer(RoutedRunner { _ in Origin.tree(sessions: "") })
            store.onRemoteRowVisibility = { [weak server] session, shown in
                MainActor.assumeIsolated { server?.remoteRowVisibilityChanged(session, shown: shown) }
            }
            let root = try pageRow(in: store)
            server.startRemotePresentation(for: root)
            XCTAssertTrue(store.softCloseSession(root.id))
            XCTAssertNil(server.remoteClients[root.id])
            XCTAssertTrue(store.undoPendingClose())
            XCTAssertEqual(transport.hellos.count, 2)
            XCTAssertEqual(transport.hellos.last?.kinds, RemotePresentationClient.observerKinds)

            let line = try XCTUnwrap(transport.lines.last)
            line(try frame(.hello(PresentationHello(version: 1, kinds: kinds, mode: .mirror)), rev: 0))
            if kinds.contains(PresentationHub.companionsKind) {
                line(try frame(.snapshot(PresentationSnapshot(status: nil, hud: nil, companions: list([child]))), rev: 1))
                line(try frame(.ended, rev: 2))
            }

            XCTAssertNil(server.companionFollow.rows[root.id], "\(kinds)")
            XCTAssertEqual(root.remotePresentation?.followsCompanions, false, "\(kinds)")
            XCTAssertNotNil(store.session(withID: root.id), "\(kinds)")
            XCTAssertEqual(root.remotePresentation?.connection, .connecting, "\(kinds)")
            XCTAssertTrue(store.companions(of: root.id).isEmpty, "\(kinds)")
            server.stopRemotePresentations()
        }
    }

    func testACatalogPageRowKeepsTheFullStream() throws {
        let (server, store, transport) = makeServer(RoutedRunner { _ in Origin.tree(sessions: "") })
        let row = try pageRow(in: store, catalogOwned: true)

        server.startRemotePresentation(for: row)

        XCTAssertEqual(transport.hellos.last, PresentationHello(version: PresentationCodec.version, kinds: PresentationHub.supportedKinds,
                                                                mode: .presenter))
    }

    // MARK: - fixtures

    private func pageRow(in store: AppStore, catalogOwned: Bool = false) throws -> Session {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let row = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox",
                                                 remoteSessionID: pageRoot, content: .page))
        store.bindRemote(RemoteBinding(remoteSessionID: pageRoot, daemonsByLocalPane: [:], presentationVersion: catalogOwned ? 1 : nil,
                                       origin: RemoteBinding.Origin(host: "buildbox", endpoint: endpoint, sessionName: "dash"),
                                       catalogOwned: catalogOwned),
                         forSession: row.id)
        store.setRemoteConnection(.connecting, forSession: row.id)
        store.baselineCompanions([], forSession: row.id)
        return row
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private func makeServer(_ runner: RoutedRunner) -> (ControlServer, AppStore, StreamTransport) {
        let actions = AppActions(library: library)
        let server = ControlServer(library: library, actions: actions, settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                                   socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteCompanionPause = {}
        let transport = StreamTransport()
        server.remoteTransport = transport
        addTeardownBlock { @MainActor in server.stopRemotePresentations() }
        return (server, library.activeStore!, transport)
    }

    private func advancingClock(_ server: ControlServer) {
        var now = Date()
        server.hudClock = {
            now = now.addingTimeInterval(5)
            return now
        }
    }

    private func parentRow(in store: AppStore, handled: [String] = [], catalogOwned: Bool = false) throws -> Session {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let row = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox",
                                                 remoteSessionID: "origin-1"))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin-1", daemonsByLocalPane: [row.paneIdentity: "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"],
                                       presentationVersion: 1,
                                       origin: RemoteBinding.Origin(host: "buildbox", endpoint: endpoint, sessionName: "parent"),
                                       catalogOwned: catalogOwned),
                         forSession: row.id)
        store.baselineCompanions(handled, forSession: row.id)
        return row
    }

    private struct Stream {
        let line: @MainActor (Data) -> Void
        let revision: Counter

        @MainActor func send(_ body: PresentationFrame.Body) {
            revision.value += 1
            line(try! PresentationCodec.encode(PresentationFrame(gen: 1, rev: revision.value, body: body)).dropLast())
        }
    }

    private func open(_ row: Session, server: ControlServer, transport: StreamTransport) throws -> Stream {
        server.startRemotePresentation(for: row)
        let line = try XCTUnwrap(transport.lines.last)
        line(try frame(.hello(PresentationHello(version: 1, kinds: [PresentationHub.companionsKind], mode: .mirror)), rev: 0))
        return Stream(line: line, revision: Counter())
    }

    private func frame(_ body: PresentationFrame.Body, rev: Int) throws -> Data {
        try PresentationCodec.encode(PresentationFrame(gen: 1, rev: rev, body: body)).dropLast()
    }

    private func list(_ ids: [String], kind: PresentationCompanions.Member.Kind = .terminal) -> PresentationCompanions {
        PresentationCompanions(members: ids.map { PresentationCompanions.Member(id: UUID(uuidString: $0)!, kind: kind) })
    }

    private func companion(of row: Session, in store: AppStore) async throws -> Session {
        let deadline = Date().addingTimeInterval(10)
        while store.companions(of: row.id).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return try XCTUnwrap(store.companions(of: row.id).first)
    }

    private func settled(_ server: ControlServer, rows: [Session]) async {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        } while rows.contains(where: { server.companionFollow.rows[$0.id]?.pass != nil }) && Date() < deadline
    }

    private func page(source: PresentationPageSource, persistent: Bool) -> PresentationPage {
        PresentationPage(page: UUID().uuidString, token: "tok", source: source, identity: "app", chromeless: false, javascript: false,
                         navigation: false, browse: false, persistent: persistent, backgroundColor: nil, pane: nil, sizePercent: nil,
                         follow: false)
    }
}

private enum Origin {
    static func pageAttach(_ argv: [String]) -> Bool { argv.joined(separator: " ").contains("page-attach") }

    static func pageRootEntry(companions: [String]) -> String {
        let members = companions.map { #"{"id":"\#($0)","name":"c"}"# }.joined(separator: ",")
        return #"{"id":"\#(pageRoot)","name":"dash","windowID":"w1","windowName":"main","workspaceID":"ws1","workspaceName":"work","#
            + #""cwd":"/srv","panes":[],"content":"page","companions":[\#(members)]}"#
    }

    static func pageReply(parent: String?) -> RemoteCommandResult {
        let parentKey = parent.map { #""parent":"\#($0)","# } ?? ""
        return RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"id":"\#(child)",\#(parentKey)"companionPage":{"#
            + #""page":"5A1E7C2B-3D4F-4E5A-8B6C-7D8E9F0A1B2C","token":"tok-1","source":{"file":{"path":"/srv/report.html","grantRoot":"/srv"}},"#
            + #""identity":"report.html","chromeless":false,"javascript":true,"navigation":false,"browse":false,"#
            + #""persistent":false,"follow":false}}}"#, stderr: "")
    }

    static func session(_ id: String, parent: String? = nil, companions: [String]? = nil) -> String {
        let parentKey = parent.map { #","parent":"\#($0)""# } ?? ""
        let members = companions.map { #","companions":["# + $0.map { #"{"id":"\#($0)","name":"c"}"# }.joined(separator: ",") + "]" } ?? ""
        return #"{"id":"\#(id)","name":"c","windowID":"w1","windowName":"main","workspaceID":"ws1","workspaceName":"work","#
            + #""cwd":"/repo","panes":[{"pane":"left","daemon":"agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"}]\#(parentKey)\#(members)}"#
    }

    static func tree(sessions: String, headless: Bool = false) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"remote":{"#
            + #""endpoint":{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"},"#
            + #""presentation":1,"# + (headless ? #""headless":true,"# : "")
            + #""sessions":[\#(sessions)]}}}"#, stderr: "")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        get { lock.withLock { count } }
        set { lock.withLock { count = newValue } }
    }

    func bump() { lock.withLock { count += 1 } }
}

private final class RoutedRunner: RemoteCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let gate: Gate?
    private let answer: @Sendable ([String]) -> RemoteCommandResult

    init(gate: Gate? = nil, _ answer: @escaping @Sendable ([String]) -> RemoteCommandResult) {
        self.gate = gate
        self.answer = answer
    }

    var invocations: [[String]] { lock.withLock { recorded } }

    func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
        await Task.yield()
        let count = lock.withLock {
            recorded.append(argv)
            return recorded.count
        }
        let reply = answer(argv)
        if count == 1 { await gate?.pass() }
        return reply
    }
}

@MainActor
final class StreamTransport: RemotePresentationTransport {
    final class Link: RemotePresentationLink {
        let sent: (Data) -> Void
        init(sent: @escaping (Data) -> Void) { self.sent = sent }
        func send(_ line: Data) { sent(line) }
        func stop() {}
    }

    var lines: [@MainActor (Data) -> Void] = []
    var closes: [@MainActor (String) -> Void] = []
    var hellos: [PresentationHello] = []

    func open(_: [String], onLine: @escaping @MainActor (Data) -> Void,
              onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
        lines.append(onLine)
        closes.append(onClose)
        return Link { [weak self] line in
            guard case .hello(let hello)? = (try? PresentationCodec.decode(line.dropLast()))?.body else { return }
            self?.hellos.append(hello)
        }
    }
}

/// Gate holds the first runner call until opened, after it has taken its reply.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrived = false

    var reached: Bool { lock.withLock { arrived } }

    func pass() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                arrived = true
                guard !opened else { return true }
                waiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let continuation = lock.withLock {
            opened = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}
