import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerAttachedForwardTests: XCTestCase {
    private static let endpoint = ControlZmxEndpoint(executable: "/Applications/agterm.app/zmx", socketDirectory: "/tmp/agterm-zmx-abc")
    private let originLeft = UUID()
    private let originRight = UUID()
    private let created = "0E2B7C1A-5D4F-4E3B-9A61-7C2D8F0B1A23"
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var servers: [ControlServer] = []

    private final class Transport: RemotePresentationTransport {
        final class Link: RemotePresentationLink {
            func send(_: Data) {}
            func stop() {}
        }

        private var deliver: [(Data) -> Void] = []
        private var rev = 0

        func open(_: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose _: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            deliver.append(onLine)
            return Link()
        }

        func feed(_ body: PresentationFrame.Body) throws {
            rev += 1
            deliver.last?(Data(try PresentationCodec.encode(PresentationFrame(gen: 3, rev: rev, body: body)).dropLast()))
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-attached-forward-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
    }

    override func tearDown() async throws {
        for server in servers { server.stopRemotePresentations() }
        servers = []
        library.finalizeAllPendingCloses()
        settings = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    func testTerminateClosesTheOriginsSessionAndEveryRowShowingItHere() async throws {
        let runner = ScriptedRunner([ok(ControlResult(undoable: true, closed: ["origin-1"]))])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store)
        let twin = try attachedRow(in: store)

        let reply = try await run(server, ControlRequest(cmd: .sessionTerminate, target: row.id.uuidString,
                                                         args: ControlArgs(undoable: true)))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertTrue(line(runner, 0).contains("session close --target origin-1 --undoable"), line(runner, 0))
        XCTAssertNil(store.session(withID: row.id))
        XCTAssertNil(store.session(withID: twin.id))
        XCTAssertEqual(Set(reply.result?.closed ?? []), [row.id.uuidString, twin.id.uuidString])
        XCTAssertEqual(reply.result?.undoable, true)
    }

    func testTheOriginsRecentEntryIsNotedWhileAServerWindowIsFrontmost() async throws {
        let runner = ScriptedRunner([ok(ControlResult(closed: ["origin-1"], recentID: "r1"))])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store)
        library.frontmostWindowID = library.newRemoteWindow(host: "box").id
        XCTAssertFalse(library.activeStore === store)

        let reply = try await run(server, ControlRequest(cmd: .sessionTerminate, target: row.id.uuidString, args: ControlArgs()))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        let entry = try XCTUnwrap(RecentClosedStore(directory: stateDir).loadRemote().first)
        XCTAssertEqual(entry.originSessionID, "origin-1")
        XCTAssertEqual(entry.originRecentID, "r1")
    }

    func testATerminateWithNoAnswerIsUnknownClosesNothingAndIsNotSentAgain() async throws {
        let runner = ScriptedRunner([RemoteCommandResult(status: -1, stdout: "", stderr: "the remote did not answer in time")])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store)

        let reply = try await run(server, ControlRequest(cmd: .sessionTerminate, target: row.id.uuidString))

        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.error?.contains("unknown") == true, reply.error ?? "")
        XCTAssertTrue(store.session(withID: row.id) === row)
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testABatchTerminateSendsOneClosePerOriginAndNamesWhatFailedAndWhatClosed() async throws {
        let runner = ScriptedRunner([ok(ControlResult(closed: ["origin-1"])),
                                     RemoteCommandResult(status: -1, stdout: "", stderr: "no route to host")])
        let (server, store) = try makeServer(runner)
        let first = try attachedRow(in: store)
        let local = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory()))
        let other = try attachedRow(in: store, host: "otherbox", origin: "origin-2")

        let reply = try await run(server, ControlRequest(cmd: .sessionTerminate, target: first.id.uuidString,
                                                         args: ControlArgs(targets: [first, local, other].map(\.id.uuidString))))

        XCTAssertFalse(reply.ok)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertTrue(runner.invocations[0].contains("buildbox"))
        XCTAssertTrue(runner.invocations[1].contains("otherbox"))
        XCTAssertTrue(reply.error?.contains("otherbox") == true, reply.error ?? "")
        XCTAssertTrue(reply.error?.contains("closed") == true, reply.error ?? "")
        XCTAssertNil(store.session(withID: first.id))
        XCTAssertNil(store.session(withID: local.id))
        XCTAssertTrue(store.session(withID: other.id) === other)
        XCTAssertEqual(Set(reply.result?.closed ?? []), [first.id.uuidString, local.id.uuidString])
    }

    func testTerminateOfALocalRowClosesItAsCloseAndAnAttachedRowIsNeverOnlyDetached() async throws {
        let runner = ScriptedRunner([])
        let (server, store) = try makeServer(runner)
        let local = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory()))
        let row = try attachedRow(in: store)

        XCTAssertNil(server.attachedRoute(ControlRequest(cmd: .sessionTerminate, target: local.id.uuidString)))
        let closed = server.terminateSessions([local.id.uuidString], window: nil, undoable: false)
        let refused = server.terminateSessions([row.id.uuidString], window: nil, undoable: false)

        XCTAssertTrue(closed.ok, closed.error ?? "")
        XCTAssertNil(store.session(withID: local.id))
        XCTAssertEqual(refused.error, "session.terminate on an attached session must run on its origin")
        XCTAssertTrue(store.session(withID: row.id) === row)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testAnOriginTooOldForThePinnedKillIsRefusedAsTooOld() async throws {
        let runner = ScriptedRunner([RemoteCommandResult(
            status: 1, stdout: #"{"ok":false,"error":"invalid request: Cannot initialize Command from invalid String value zmx.kill.pane"}"#,
            stderr: "")])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store)

        let reply = try await run(server, ControlRequest(cmd: .zmxKill, target: row.id.uuidString, args: ControlArgs(force: true, pane: "left")))

        XCTAssertEqual(reply.error, "the agterm on buildbox is too old for this")
        XCTAssertTrue(store.session(withID: row.id) === row)
    }

    func testAKillRunsOnTheOriginPinnedToItsPaneAndActiveStaysLocal() async throws {
        let runner = ScriptedRunner([ok()])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store, split: true)

        XCTAssertNil(server.attachedRoute(ControlRequest(cmd: .zmxKill, target: "active", args: ControlArgs(force: true, pane: "right"))))
        let reply = try await run(server, ControlRequest(cmd: .zmxKill, target: row.id.uuidString, args: ControlArgs(force: true, pane: "right")))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 0).lowercased().contains(
            "zmx kill --target origin-1 --pane right --pane-id \(originRight.uuidString.lowercased()) --force"), line(runner, 0))
        XCTAssertTrue(row.hasSplit)
    }

    func testRestartIsRefusedBeforeSendingUntilTheOriginPublishesRespawns() async throws {
        let runner = ScriptedRunner([])
        let (server, store) = try makeServer(runner)
        let unconnected = try attachedRow(in: store)
        let older = try attachedRow(in: store)
        try connect(older, server: server, kinds: ["layout"])
        let restart = { (row: Session) in
            ControlRequest(cmd: .sessionRestart, target: row.id.uuidString, args: ControlArgs(pane: "left"))
        }

        let notConnected = try await run(server, restart(unconnected))
        let tooOld = try await run(server, restart(older))

        XCTAssertEqual(notConnected.error, "the session on buildbox is not connected; nothing was restarted")
        XCTAssertEqual(tooOld.error, "the agterm on buildbox is too old to restart a pane from here")
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testRestartRunsOnAnOriginThatPublishesRespawnsAndAnswersItsReceiptForThisPane() async throws {
        let receipt = ControlRestartReceipt(paneID: originLeft.uuidString, oldPid: 10, newPid: 11, replayedArgv: ["vim"])
        let runner = ScriptedRunner([ok(ControlResult(id: "origin-1", restart: receipt))])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store)
        try connect(row, server: server, kinds: ["layout", PresentationHub.restartRespawnKind])

        let reply = try await run(server, ControlRequest(cmd: .sessionRestart, target: row.id.uuidString,
                                                         args: ControlArgs(command: "make test", pane: "left")))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(reply.result?.id, row.id.uuidString)
        XCTAssertEqual(reply.result?.restart, ControlRestartReceipt(paneID: row.paneIdentity.uuidString, oldPid: 10, newPid: 11,
                                                                    replayedArgv: ["vim"]))
        XCTAssertTrue(line(runner, 0).lowercased().contains(
            "session restart --target origin-1 --pane-id \(originLeft.uuidString.lowercased()) --command=make test"), line(runner, 0))
    }

    func testConvertMakesTheParentOnTheOriginAndNestsTheRowUnderItHere() async throws {
        let runner = ScriptedRunner([ok(ControlResult(id: "origin-1", parent: created)), tree(sessions: session(created))])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store)
        let slot = try XCTUnwrap(store.sessionLocation(ofSession: row.id)?.index)

        let reply = try await run(server, ControlRequest(cmd: .sessionCompanionConvert, target: row.id.uuidString))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 0).contains("session convert --companion --target origin-1"), line(runner, 0))
        let parent = try XCTUnwrap(reply.result?.parent.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)))
        XCTAssertEqual(parent.remoteSessionID, created)
        XCTAssertEqual(store.sessionLocation(ofSession: parent.id)?.index, slot)
        XCTAssertEqual(row.parentID, parent.id)
    }

    func testDuplicateCreatesTheSessionOnTheOriginAndAttachesItAfterTheRow() async throws {
        let runner = ScriptedRunner([ok(ControlResult(id: created)), tree(sessions: session(created))])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store)
        let slot = try XCTUnwrap(store.sessionLocation(ofSession: row.id)?.index)

        let reply = try await run(server, ControlRequest(cmd: .sessionDuplicate, target: row.id.uuidString))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 0).contains("session new --after origin-1 --no-select"), line(runner, 0))
        let copy = try XCTUnwrap(reply.result?.id.flatMap(UUID.init(uuidString:)).flatMap(store.session(withID:)))
        XCTAssertEqual(copy.remoteSessionID, created)
        XCTAssertEqual(store.sessionLocation(ofSession: copy.id)?.index, slot + 1)
        XCTAssertNil(copy.parentID)
    }

    func testASplitAndItsCloseRunOnTheOriginAndChangeNothingHere() async throws {
        let runner = ScriptedRunner([ok(), ok()])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store)

        let split = try await run(server, ControlRequest(cmd: .sessionSplit, target: row.id.uuidString,
                                                         args: ControlArgs(mode: "on", axis: "horizontal")))
        let close = try await run(server, ControlRequest(cmd: .sessionSplitClose, target: row.id.uuidString))

        XCTAssertTrue(split.ok, split.error ?? "")
        XCTAssertTrue(close.ok, close.error ?? "")
        XCTAssertTrue(line(runner, 0).contains("session split visibility on --target origin-1 --axis horizontal"), line(runner, 0))
        XCTAssertTrue(line(runner, 1).contains("session split close --target origin-1"), line(runner, 1))
        XCTAssertFalse(row.hasSplit)
    }

    // regression: two rows of one origin session gave their scratch surfaces the origin's scratch UUID as token and lead key
    func testTwoRowsOfOneOriginSessionGiveTheirScratchSurfacesTheirOwnKeys() throws {
        let (server, store) = try makeServer(ScriptedRunner([]))
        let rows = try [attachedRow(in: store), attachedRow(in: store)]
        let scratch = UUID()

        let views = rows.map { row in
            store.applyRemoteLayout(PresentationLayout(panes: [originLeft], primary: originLeft, shown: false, scratch: scratch,
                                                       scratchShown: true), forSession: row.id, attach: server)
            let view = agtermApp.makeScratchSurface(for: row, store: store, env: [:], suppressAutoFocus: true,
                                                    actions: AppActions(library: library))
            row.scratchSurface = view
            return view
        }
        let clients = try rows.map { try XCTUnwrap($0.scratchClientIdentity) }
        defer { clients.forEach { ZmxLeadBook.shared.forget(pane: $0) } }

        XCTAssertEqual(Set(clients).count, 2)
        XCTAssertEqual(views.map(\.paneToken), clients.map(\.uuidString))
        XCTAssertTrue(clients.allSatisfy { ZmxLeadBook.shared.states[$0] != nil })
        XCTAssertNil(ZmxLeadBook.shared.states[scratch])
        XCTAssertEqual(views.map(\.linkClickPane), [scratch, scratch])
        XCTAssertEqual(rows.map(\.originScratch), [scratch, scratch])
    }

    func testTheScratchRunsOnAnOriginThatShowsItsScratchAndIsRefusedWhereItCannot() async throws {
        let runner = ScriptedRunner([ok()])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store)
        let scratch = ControlRequest(cmd: .sessionScratch, target: row.id.uuidString, args: ControlArgs(mode: "on"))

        let unconnected = try await run(server, scratch)
        store.setRemoteConnection(.connected, forSession: row.id)
        store.applyRemoteLayout(PresentationLayout(panes: [originLeft], primary: originLeft, shown: false),
                                forSession: row.id, attach: server)
        let older = try await run(server, scratch)
        store.applyRemoteLayout(PresentationLayout(panes: [originLeft], primary: originLeft, shown: false, scratchShown: false),
                                forSession: row.id, attach: server)
        let reply = try await run(server, scratch)
        store.setRemoteConnection(.failed("lost"), forSession: row.id)
        let dropped = try await run(server, scratch)

        XCTAssertEqual(unconnected.error, "the session on buildbox is not connected; the scratch did not change")
        XCTAssertEqual(older.error, "the agterm on buildbox is too old to show its scratch here")
        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertNotNil(row.remotePresentation?.layout)
        XCTAssertEqual(dropped.error, "the session on buildbox is not connected; the scratch did not change")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertTrue(line(runner, 0).contains("session scratch on --target origin-1"), line(runner, 0))
        XCTAssertFalse(row.scratchActive)
    }

    func testRequestsTheirOwnChecksRefuseNeverReachTheOrigin() async throws {
        let runner = ScriptedRunner([])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store, split: true)
        let id = row.id.uuidString
        let requests = [
            ControlRequest(cmd: .zmxKill, target: id, args: ControlArgs(pane: "left")),
            ControlRequest(cmd: .zmxKill, target: id, args: ControlArgs(force: true, window: "active", pane: "left")),
            ControlRequest(cmd: .zmxKillPane, target: id, args: ControlArgs(force: true, pane: "left")),
            ControlRequest(cmd: .sessionRestart, target: id, args: ControlArgs()),
            ControlRequest(cmd: .sessionRestore, target: id, args: ControlArgs(mode: "set")),
        ]

        for request in requests {
            XCTAssertNil(server.attachedRoute(request), "\(request.cmd.rawValue) \(String(describing: request.args))")
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testAPaneTokenFollowsTheRuleOfItsCommandBeforeAnythingIsSent() async throws {
        let runner = ScriptedRunner([])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store, split: true)
        try connect(row, server: server, kinds: ["layout", PresentationHub.restartRespawnKind])
        let unknown = UUID().uuidString
        let right = try XCTUnwrap(row.splitPaneIdentity).uuidString

        let restart = try await run(server, ControlRequest(cmd: .sessionRestart, target: row.id.uuidString,
                                                           args: ControlArgs(pane: "left", paneID: unknown)))
        let kill = try await run(server, ControlRequest(cmd: .zmxKillPane, target: row.id.uuidString,
                                                        args: ControlArgs(force: true, pane: "left", paneID: right)))

        XCTAssertEqual(restart.error, "unknown pane id: \(unknown)")
        XCTAssertEqual(kill.error, "pane \(right) is no longer the left pane; nothing was killed")
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testAKillAfterASwapHereSendsTheRoleThePaneHoldsOnTheOrigin() async throws {
        let runner = ScriptedRunner([ok()])
        let (server, store) = try makeServer(runner)
        let row = try attachedRow(in: store, split: true)
        store.applyRemoteLayout(PresentationLayout(panes: [originLeft, originRight], primary: originLeft, axis: "vertical", shown: true),
                                forSession: row.id, attach: server)
        XCTAssertNil(store.swapPanes(row.id, allowingUnrealized: true))

        let reply = try await run(server, ControlRequest(cmd: .zmxKill, target: row.id.uuidString, args: ControlArgs(force: true, pane: "left")))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 0).lowercased().contains(
            "--pane right --pane-id \(originRight.uuidString.lowercased())"), line(runner, 0))
    }

    func testTerminateSendsEverySelectedIdAndClosesOnlyTheRowsTheOriginEnded() async throws {
        let runner = ScriptedRunner([ok(ControlResult(closed: ["origin-1"]))])
        let (server, store) = try makeServer(runner)
        let parent = try attachedRow(in: store)
        let companion = try attachedRow(in: store, origin: "origin-2")
        store.nest(companion.id, under: parent.id)

        let reply = try await run(server, ControlRequest(cmd: .sessionTerminate, target: parent.id.uuidString,
                                                         args: ControlArgs(targets: [parent.id.uuidString, companion.id.uuidString])))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 0).contains("session close --target origin-1 --target origin-2"), line(runner, 0))
        XCTAssertNil(store.session(withID: parent.id))
        XCTAssertTrue(store.session(withID: companion.id) === companion)
        XCTAssertNil(companion.parentID)
        XCTAssertEqual(reply.result?.closed, [parent.id.uuidString])
    }

    func testACompanionTheOriginDidNotEndOutlivesItsTerminatedParentHere() async throws {
        let runner = ScriptedRunner([ok(ControlResult(closed: ["origin-1"]))])
        let (server, store) = try makeServer(runner)
        let parent = try attachedRow(in: store)
        let companion = try attachedRow(in: store, origin: "origin-2")
        store.nest(companion.id, under: parent.id)

        let reply = try await run(server, ControlRequest(cmd: .sessionTerminate, target: parent.id.uuidString))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 0).contains("session close --target origin-1"), line(runner, 0))
        XCTAssertFalse(line(runner, 0).contains("origin-2"), line(runner, 0))
        XCTAssertNil(store.session(withID: parent.id))
        XCTAssertTrue(store.session(withID: companion.id) === companion)
        XCTAssertNil(companion.parentID)
        XCTAssertEqual(reply.result?.closed, [parent.id.uuidString])
    }

    func testRestoreRunsOnAMacOriginAndIsRefusedForAServer() async throws {
        let runner = ScriptedRunner([ok()])
        let (server, store) = try makeServer(runner)
        let mac = try attachedRow(in: store)
        let headless = try attachedRow(in: store, headless: true)
        let pin = { (row: Session) in
            ControlRequest(cmd: .sessionRestore, target: row.id.uuidString, args: ControlArgs(mode: "set", command: "-make test"))
        }

        let pinned = try await run(server, pin(mac))
        let refused = try await run(server, pin(headless))

        XCTAssertTrue(pinned.ok, pinned.error ?? "")
        XCTAssertTrue(line(runner, 0).lowercased().contains(
            "session restore --target origin-1 --pane-id \(originLeft.uuidString.lowercased())"), line(runner, 0))
        XCTAssertTrue(line(runner, 0).contains("-- -make test"), line(runner, 0))
        XCTAssertEqual(refused.error, "agterm-server keeps every pane running")
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testALayoutAddingASplitAndAScratchAttachesTheirOriginDaemonsHere() async throws {
        let (server, store) = try makeServer(ScriptedRunner([]))
        let row = try attachedRow(in: store)
        let transport = try connect(row, server: server, kinds: ["layout"])
        let scratch = UUID()

        try transport.feed(.layout(PresentationLayout(panes: [originLeft, originRight], primary: originLeft, axis: "vertical", shown: true,
                                                      scratch: scratch, scratchShown: true)))

        XCTAssertTrue(row.hasSplit)
        XCTAssertTrue(row.isSplit)
        let split = try XCTUnwrap(row.splitInitialCommand)
        XCTAssertTrue(split.contains(ZmxSupport.daemonName(for: originRight)), split)
        XCTAssertTrue(split.contains("buildbox"), split)
        let attach = try XCTUnwrap(row.scratchCommand)
        XCTAssertTrue(attach.contains(ZmxSupport.daemonName(for: scratch)), attach)
        XCTAssertTrue(row.scratchActive)
        if let local = row.splitPaneIdentity { ZmxLeadBook.shared.forget(pane: local) }
    }

    func testACompanionMoveRunsOnTheOriginByItsIDsThenTakesTheSlotHere() async throws {
        let runner = ScriptedRunner([ok(ControlResult(id: "c1", parent: "p2"))])
        let (server, store) = try makeServer(runner)
        let (companion, destination) = try companionAndDestination(in: store)
        let resident = try attachedRow(in: store, origin: "d1")
        store.nest(resident.id, under: destination.id)

        let reply = try await run(server, move(companion, under: destination, index: 0))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertTrue(line(runner, 0).hasSuffix("session move --target c1 --parent p2 --json"), line(runner, 0))
        XCTAssertEqual(companion.parentID, destination.id)
        XCTAssertEqual(store.companions(of: destination.id).map(\.id), [companion.id, resident.id])
        XCTAssertEqual(reply.result?.parent, destination.id.uuidString)
    }

    func testACompanionMoveTakesAPaddedParentAsTheDispatcherDoes() async throws {
        let runner = ScriptedRunner([ok(ControlResult(id: "c1", parent: "p2"))])
        let (server, store) = try makeServer(runner)
        let (companion, destination) = try companionAndDestination(in: store)
        var request = move(companion, under: destination)
        request.args?.parent = " \(destination.id.uuidString) "

        let reply = try await run(server, request)

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertTrue(line(runner, 0).hasSuffix("session move --target c1 --parent p2 --json"), line(runner, 0))
        XCTAssertEqual(companion.parentID, destination.id)
    }

    func testACompanionMoveTheChecksHereRefuseNeverReachesTheOrigin() async throws {
        let runner = ScriptedRunner([])
        let (server, store) = try makeServer(runner)
        let (companion, destination) = try companionAndDestination(in: store)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let local = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        let elsewhere = try attachedRow(in: store, host: "otherbox", origin: "o2")
        let parent = try XCTUnwrap(companion.parentID.flatMap(store.session(withID:)))

        XCTAssertNil(server.attachedRoute(move(companion, under: destination, index: -1)))
        XCTAssertNil(server.attachedRoute(move(companion, under: parent, index: 0)), "a reorder under its own parent stays here")
        let refusals = [move(destination, under: parent), move(companion, under: local), move(companion, under: elsewhere)].map { request in
            guard case .refused(let reply) = server.attachedRoute(request) else { return "routed" }
            return reply.error ?? ""
        }

        XCTAssertEqual(refusals, [CompanionMoveRefusal.notCompanion.message, CompanionMoveRefusal.otherHost.message,
                                  CompanionMoveRefusal.otherHost.message])
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testAnOriginThatRefusesOrIsTooOldLeavesTheCompanionWhereItIs() async throws {
        let unknown = ControlResponse(ok: false, error: "invalid request: unknown cmd session.companion.move")
        let runner = ScriptedRunner([printed(ControlResponse(ok: false, error: "no such session"), status: 1),
                                     RemoteCommandResult(status: 64, stdout: "", stderr: "Error: Unknown option '--parent'"),
                                     printed(unknown, status: 1)])
        let (server, store) = try makeServer(runner)
        let (companion, destination) = try companionAndDestination(in: store)
        let parent = companion.parentID

        var errors: [String] = []
        for _ in 0..<3 { errors.append(try await run(server, move(companion, under: destination)).error ?? "") }

        XCTAssertEqual(errors, ["no such session", "the agterm on buildbox is too old for this", "the agterm on buildbox is too old for this"])
        XCTAssertEqual(companion.parentID, parent)
    }

    func testAnOriginMoveWhoseRowLeftThisMacMeanwhileSaysItMovedOnlyThere() async throws {
        let runner = ScriptedRunner([ok(ControlResult(id: "c1", parent: "p2"))])
        let (server, store) = try makeServer(runner)
        let (companion, destination) = try companionAndDestination(in: store)
        let route = try XCTUnwrap(server.attachedRoute(move(companion, under: destination)))
        _ = store.closeExactly([destination.id])

        let reply = await server.runRemoteRoute(route)

        XCTAssertEqual(reply.error, "moved on buildbox, but not here: no such session")
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testAGuiMoveOfAnAttachedCompanionAsksTheOrigin() async throws {
        let runner = ScriptedRunner([ok(ControlResult(id: "c1", parent: "p2"))])
        let (server, store) = try makeServer(runner)
        server.actions.remoteAttacher = server
        let (companion, destination) = try companionAndDestination(in: store)

        server.actions.moveCompanion(companion.id, under: destination.id, at: nil, in: store)

        let deadline = Date().addingTimeInterval(5)
        while companion.parentID != destination.id, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(companion.parentID, destination.id)
        XCTAssertTrue(line(runner, 0).hasSuffix("session move --target c1 --parent p2 --json"), line(runner, 0))
    }

    func testAGuiDuplicateOfAnAttachedRowAsksTheOrigin() async throws {
        let runner = ScriptedRunner([ok(ControlResult(id: created)), tree(sessions: session(created))])
        let (server, store) = try makeServer(runner)
        server.actions.remoteAttacher = server
        let row = try attachedRow(in: store)

        server.actions.duplicateSession(row.id, in: store)

        let deadline = Date().addingTimeInterval(5)
        while !store.workspaces.flatMap(\.sessions).contains(where: { $0.remoteSessionID == created }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.workspaces.flatMap(\.sessions).contains { $0.remoteSessionID == created })
        XCTAssertTrue(line(runner, 0).contains("session new --after origin-1 --no-select"), line(runner, 0))
    }

    private func makeServer(_ runner: ScriptedRunner) throws -> (ControlServer, AppStore) {
        let server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                                   socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteCompanionPause = {}
        servers.append(server)
        return (server, try XCTUnwrap(library.activeStore))
    }

    private func attachedRow(in store: AppStore, host: String = "buildbox", origin: String = "origin-1",
                             headless: Bool = false, split: Bool = false) throws -> Session {
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let row = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: host))
        var daemons = [row.paneIdentity: ZmxSupport.daemonName(for: originLeft)]
        if split {
            store.toggleSplit(row.id)
            daemons[try XCTUnwrap(row.splitPaneIdentity)] = ZmxSupport.daemonName(for: originRight)
        }
        store.bindRemote(RemoteBinding(remoteSessionID: origin, daemonsByLocalPane: daemons, presentationVersion: 1,
                                       origin: RemoteBinding.Origin(host: host, endpoint: Self.endpoint, sessionName: "c"),
                                       originHeadless: headless), forSession: row.id)
        return row
    }

    @discardableResult
    private func connect(_ row: Session, server: ControlServer, kinds: [String]) throws -> Transport {
        let transport = Transport()
        server.remoteTransport = transport
        server.startRemotePresentation(for: row)
        try transport.feed(.hello(PresentationHello(version: 1, kinds: kinds, mode: .mirror)))
        return transport
    }

    private func run(_ server: ControlServer, _ request: ControlRequest) async throws -> ControlResponse {
        let route = try XCTUnwrap(server.attachedRoute(request))
        return await server.runRemoteRoute(route)
    }

    private func line(_ runner: ScriptedRunner, _ index: Int) -> String {
        guard runner.invocations.indices.contains(index) else { return "" }
        return (runner.invocations[index].last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
    }

    private func companionAndDestination(in store: AppStore) throws -> (companion: Session, destination: Session) {
        let parent = try attachedRow(in: store, origin: "p1")
        let companion = try attachedRow(in: store, origin: "c1")
        store.nest(companion.id, under: parent.id)
        return (companion, try attachedRow(in: store, origin: "p2"))
    }

    private func move(_ row: Session, under parent: Session, index: Int? = nil) -> ControlRequest {
        var args = ControlArgs()
        args.parent = parent.id.uuidString
        args.index = index
        return ControlRequest(cmd: .sessionCompanionMove, target: row.id.uuidString, args: args)
    }

    private func printed(_ response: ControlResponse, status: Int32) -> RemoteCommandResult {
        let data = (try? JSONEncoder().encode(response)) ?? Data()
        return RemoteCommandResult(status: status, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }

    private func ok(_ result: ControlResult = ControlResult()) -> RemoteCommandResult {
        let data = (try? JSONEncoder().encode(ControlResponse(ok: true, result: result))) ?? Data()
        return RemoteCommandResult(status: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }

    private func session(_ id: String) -> String {
        #"{"id":"\#(id)","name":"c","windowID":"w1","windowName":"main","workspaceID":"ws1","workspaceName":"work","#
            + #""cwd":"/repo","panes":[{"pane":"left","daemon":"agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3"}]}"#
    }

    private func tree(sessions: String) -> RemoteCommandResult {
        RemoteCommandResult(status: 0, stdout: #"{"ok":true,"result":{"remote":{"#
            + #""endpoint":{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"},"#
            + #""sessions":[\#(sessions)]}}}"#, stderr: "")
    }
}
