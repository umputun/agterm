import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the zmx group's app arms: the join against the live claim walk, and the refusals
/// that must not read as an empty inventory.
@MainActor
final class ControlServerZmxTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-zmx-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            settingsModel = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    func testRemoteTreeReadsTheFarSidesAnswerInOneInvocation() async throws {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: Self.projection, stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)

        let response = await server.remoteTree(host: "buildbox")

        let remote = try XCTUnwrap(response.result?.remote)
        XCTAssertEqual(remote.host, "buildbox", "the far side names no host; the caller stamps it")
        XCTAssertEqual(remote.sessions.map(\.id), ["s1"])
        XCTAssertEqual(remote.sessions.map(\.windowName), ["main"])
        XCTAssertEqual(remote.endpoint.socketDirectory, "/tmp/agterm-zmx-abc")
        XCTAssertEqual(runner.invocations.count, 1, "the far side does the whole join in one call")
        XCTAssertEqual(runner.invocations.first?.first, "ssh")
    }

    func testTheBareFormAnswersAboutThisAppWithoutSshingAnywhere() async throws {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: "", stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)

        let response = await server.remoteTree(host: nil)

        let remote = try XCTUnwrap(response.result?.remote)
        XCTAssertTrue(response.ok)
        XCTAssertNil(remote.host, "nothing was sshed to, so there is no destination to name")
        XCTAssertTrue(runner.invocations.isEmpty, "the local form must never reach ssh")
        // no pane in this fixture is zmx-backed, and an empty list is a successful answer rather than
        // a refusal: it does not claim to tell "not live" apart from "live with nothing eligible"
        XCTAssertTrue(remote.sessions.isEmpty)
    }

    func testRemoteTreeRefusesANonzeroExitBeforeParsing() async {
        // an ssh that dies mid-write leaves output that may still parse; only the exit status separates a
        // real answer from a truncated one, which is why it is read first
        let truncated = String(Self.projection.dropLast(40))
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 255, stdout: truncated,
                                                                 stderr: "Permission denied (publickey)."))
        let server = makeServer(list: "", remoteRunner: runner)

        let response = await server.remoteTree(host: "buildbox")

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "Permission denied (publickey).")
    }

    func testAFailedRemoteReportsItsOwnReasonRatherThanAGenericOne() async {
        // the remote's agtermctl prints its refusal to stdout and exits nonzero, leaving stderr empty
        let refusal = #"{"ok":false,"error":"could not read the zmx session list"}"#
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 1, stdout: refusal, stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)

        let response = await server.remoteTree(host: "buildbox")

        XCTAssertEqual(response.error, "could not read the zmx session list")
    }

    func testAnSshFailureStillFallsBackToStderr() async {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 255, stdout: "",
                                                                  stderr: "ssh: Could not resolve hostname"))
        let server = makeServer(list: "", remoteRunner: runner)

        let response = await server.remoteTree(host: "buildbox")

        XCTAssertEqual(response.error, "ssh: Could not resolve hostname")
    }

    func testRemoteTreeRejectsAHostileHostWithoutRunningAnything() async {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: "", stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)

        let response = await server.remoteTree(host: "-oProxyCommand=touch /tmp/pwned")

        XCTAssertFalse(response.ok)
        XCTAssertTrue(runner.invocations.isEmpty, "a refused host must never reach a process")
    }

    // a rejected host is rejected for carrying control characters, so echoing it back would print them
    // to a terminal once agtermctl decodes the response
    func testRefusedHostIsNotEchoedIntoTheResponse() async {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: "", stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)

        let response = await server.remoteTree(host: "buildbox\nrm -rf /\u{1B}[31mRED")

        XCTAssertEqual(response.error, "invalid host")
        XCTAssertFalse(response.error?.contains("\n") ?? true)
        XCTAssertFalse(response.error?.contains("\u{1B}") ?? true)
        XCTAssertFalse(response.error?.contains("rm -rf") ?? true)
    }

    func testAttachCreatesARemoteSessionWithAHoldingSshPane() async throws {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: Self.projection, stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)
        let store = try XCTUnwrap(library.activeStore)

        let response = await server.attachRemoteSession(host: "buildbox", session: "s1")

        XCTAssertTrue(response.ok)
        let created = try XCTUnwrap(store.workspaces.flatMap(\.sessions).first { $0.remoteHost != nil })
        XCTAssertEqual(created.remoteHost, "buildbox")
        XCTAssertEqual(created.customName, "build")
        XCTAssertTrue(created.commandWait, "the pane must hold so the disconnect line can be read")
        let command = try XCTUnwrap(created.initialCommand)
        XCTAssertTrue(command.contains("ssh"))
        XCTAssertTrue(command.contains("agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"))
        XCTAssertFalse(created.hasSplit)
    }

    func testAttachResolvesTheRemoteAgainRatherThanTrustingTheCaller() async {
        // the daemon has gone since the picker listed it, so the far side's own eligibility walk no longer
        // offers the session at all; attaching would CREATE the daemon and hand back a fresh shell
        // wearing the session's name
        let vanished = """
        {"ok":true,"result":{"remote":{\
        "endpoint":{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"},\
        "sessions":[]}}}
        """
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: vanished, stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)
        let store = library.activeStore

        let response = await server.attachRemoteSession(host: "buildbox", session: "s1")

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no attachable session s1 on buildbox")
        XCTAssertEqual(runner.invocations.count, 1, "it re-reads before touching the model")
        XCTAssertNil(store?.workspaces.flatMap(\.sessions).first { $0.remoteHost != nil },
                     "a refused attach must leave no half-built row")
    }

    func testAFailedDiscoveryCreatesNothingAndKeepsItsReason() async {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 255, stdout: "",
                                                                  stderr: "Permission denied (publickey)."))
        let server = makeServer(list: "", remoteRunner: runner)
        let store = library.activeStore

        let response = await server.attachRemoteSession(host: "buildbox", session: "s1")

        XCTAssertEqual(response.error, "Permission denied (publickey).")
        XCTAssertNil(store?.workspaces.flatMap(\.sessions).first { $0.remoteHost != nil })
    }

    func testAttachTakesTheSessionIdOnlyNotItsName() async {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: Self.projection, stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)

        // remote names are mutable and non-unique across workspaces, so only the id can address one
        let response = await server.attachRemoteSession(host: "buildbox", session: "build")

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no attachable session build on buildbox")
    }

    func testAttachUsesALocalWorkingDirectoryNotTheRemoteOne() async throws {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: Self.projection, stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)
        let store = try XCTUnwrap(library.activeStore)

        _ = await server.attachRemoteSession(host: "buildbox", session: "s1")

        let created = try XCTUnwrap(store.workspaces.flatMap(\.sessions).first { $0.remoteHost != nil })
        // libghostty chdirs the local ssh process here; /repo exists on buildbox, not necessarily here
        XCTAssertNotEqual(created.initialCwd, "/repo")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.initialCwd, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testAttachBringsBothPanesOfARemoteSplit() async throws {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: Self.splitProjection,
                                                                  stderr: ""))
        let server = makeServer(list: "", remoteRunner: runner)
        let store = try XCTUnwrap(library.activeStore)

        let response = await server.attachRemoteSession(host: "buildbox", session: "s1")

        XCTAssertTrue(response.ok)
        let created = try XCTUnwrap(store.workspaces.flatMap(\.sessions).first { $0.remoteHost != nil })
        XCTAssertTrue(created.hasSplit)
        XCTAssertEqual(created.splitAxis, .topBottom, "the split arrives arranged as it is over there")
        XCTAssertTrue(created.splitCommandWait)
        XCTAssertTrue(try XCTUnwrap(created.splitInitialCommand).contains("agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2"))
    }

    func testListReportsTheEndpointOfTheInjectedClient() throws {
        let server = makeServer(list: "")

        let inventory = try XCTUnwrap(server.listZmxDaemons().result?.zmx)

        let endpoint = try XCTUnwrap(inventory.endpoint)
        XCTAssertEqual(endpoint.executable, "/tmp/zmx")
        XCTAssertEqual(endpoint.socketDirectory, "/tmp/zmx-dir")
    }

    func testListJoinsObservedDaemonsAgainstTheLivePanes() throws {
        let live = try XCTUnwrap(library.allOpenSessions().first)
        let orphan = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let server = makeServer(list: """
        name=\(ZmxSupport.daemonName(for: live.paneIdentity))\tpid=1\tclients=1\tcreated=1
        name=\(orphan)\tpid=2\tclients=0\tcreated=1
        name=notes\tpid=3\tclients=0\tcreated=1
        """)

        let response = server.listZmxDaemons()

        XCTAssertTrue(response.ok)
        let inventory = try XCTUnwrap(response.result?.zmx)
        XCTAssertTrue(inventory.inventoryComplete)
        XCTAssertEqual(inventory.restore.active, GhosttyApp.shared.launchRestoreMode.rawValue)

        let claimed = try XCTUnwrap(inventory.entries.first { $0.sessionID == live.id.uuidString })
        XCTAssertEqual(claimed.state, "claimed")
        XCTAssertEqual(claimed.clients, 1)
        XCTAssertEqual(claimed.pane, "left")

        XCTAssertEqual(inventory.entries.first { $0.daemon == orphan }?.state, "orphan")
        XCTAssertEqual(inventory.entries.first { $0.daemon == "notes" }?.state, "foreign")
    }

    func testAnEmptyNamespaceIsASuccessfulEmptyInventory() throws {
        let response = makeServer(list: "").listZmxDaemons()

        XCTAssertTrue(response.ok, "no daemons is an answer, not a failure")
        let inventory = try XCTUnwrap(response.result?.zmx)
        XCTAssertTrue(inventory.entries.allSatisfy { $0.observation == "absent" },
                      "only the panes' own claims remain, each with no daemon behind it")
    }

    func testAFailedListingIsAnErrorRatherThanAnEmptyInventory() {
        let response = makeServer(list: nil).listZmxDaemons()

        XCTAssertFalse(response.ok, "not having looked must not read as nothing to see")
        XCTAssertEqual(response.error, "could not read the zmx session list")
        XCTAssertNil(response.result?.zmx)
    }

    func testWithoutAClientTheCommandSaysZmxIsUnavailable() {
        let server = ControlServer(
            library: library, actions: AppActions(library: library), settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)

        let response = server.listZmxDaemons()
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, ControlZmxError.unavailable)
    }

    func testPruneNeverPassesForceAndCountsOnlyAConfirmedKill() throws {
        let orphan = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        var invocations: [[String]] = []
        let server = makeServer(runner: { invocation in
            invocations.append(invocation.arguments)
            guard invocation.arguments.first == "kill" else {
                return "name=\(orphan)\tpid=2\tclients=0\tcreated=1"
            }
            return "killed session \(orphan)\n"
        })

        let response = server.pruneZmxDaemons()

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.affected, 1)
        XCTAssertEqual(response.result?.text, "killed \(orphan)")
        XCTAssertEqual(invocations, [["list"], ["list"], ["kill", orphan]],
                       "prune lists, re-lists to revalidate, then kills unforced")
    }

    func testAStaleSocketCleanupIsNotCountedAsAKill() throws {
        let orphan = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "kill" else {
                return "name=\(orphan)\tpid=2\tclients=0\tcreated=1"
            }
            return "cleaned up stale session \(orphan)\n"
        })

        let response = server.pruneZmxDaemons()

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.affected, 0, "an unlinked socket may leave the daemon running")
        XCTAssertEqual(response.result?.text,
                       "\(orphan): cleaned up a stale socket, the daemon may still be running")
    }

    func testACandidateThatGainsAClientBeforeTheKillIsDropped() throws {
        let orphan = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        var listings = 0
        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                XCTFail("a revalidated-away candidate must never be killed")
                return ""
            }
            listings += 1
            // someone attached between the two listings, which is the window zmx cannot close for us
            return "name=\(orphan)\tpid=2\tclients=\(listings == 1 ? 0 : 1)\tcreated=1"
        })

        let response = server.pruneZmxDaemons()

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.affected, 0)
        XCTAssertEqual(response.result?.text, "no orphan daemons left to prune")
    }

    func testPruneRefusesAnIncompleteInventoryAndKillsNothing() throws {
        let stray = UUID()
        let snapshot = Snapshot(workspaces: [WorkspaceSnapshot(
            id: UUID(), name: "workspace 1",
            sessions: [SessionSnapshot(id: UUID(), paneIdentity: nil, customName: nil, cwd: "/tmp")])])
        try PersistenceStore(directory: stateDir.appendingPathComponent("windows"),
                             fileName: "\(stray.uuidString).json").save(snapshot)

        let orphan = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                XCTFail("nothing may be killed against an inventory that cannot account for every pane")
                return ""
            }
            return "name=\(orphan)\tpid=2\tclients=0\tcreated=1"
        })

        let response = server.pruneZmxDaemons()

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, ControlZmxError.incompleteInventory)
    }

    func testPruneLeavesClaimedAndForeignDaemonsAlone() throws {
        let live = try XCTUnwrap(library.allOpenSessions().first)
        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                XCTFail("a claimed pane's daemon and a foreign session are both off limits")
                return ""
            }
            return """
            name=\(ZmxSupport.daemonName(for: live.paneIdentity))\tpid=1\tclients=0\tcreated=1
            name=notes\tpid=3\tclients=0\tcreated=1
            """
        })

        let response = server.pruneZmxDaemons()

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.affected, 0)
        XCTAssertEqual(response.result?.text, "no orphan daemons")
    }

    func testPruneSpareASoftClosedPaneAndAnUnreadableRowWhileTakingTheOrphan() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let pending = try XCTUnwrap(store.workspaces.first?.sessions.first)
        XCTAssertTrue(store.softCloseSession(pending.id), "precondition: a live undo window")

        let orphan = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let unreadable = "agterm-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        var killed: [String] = []
        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                killed.append(invocation.arguments[1])
                return "killed session \(invocation.arguments[1])\n"
            }
            return """
            name=\(ZmxSupport.daemonName(for: pending.paneIdentity))\tpid=1\tclients=0\tcreated=1
            name=\(orphan)\tpid=2\tclients=0\tcreated=1
            name=\(unreadable)\terr=Timeout\tstatus=unreachable
            """
        })

        let response = server.pruneZmxDaemons()

        XCTAssertTrue(response.ok)
        XCTAssertEqual(killed, [orphan],
                       "a soft-closed pane still owns its daemon, and an unreadable row is not an orphan")
        XCTAssertEqual(response.result?.affected, 1)
    }

    func testKillRefusesEveryRowItCannotSafelyDestroy() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        let absentServer = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                XCTFail("a daemon that is not running has nothing to kill")
                return ""
            }
            return ""
        })

        let absent = absentServer.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)
        XCTAssertFalse(absent.ok)
        XCTAssertEqual(absent.error, "\(ZmxSupport.daemonName(for: session.paneIdentity)) is not running")

        let unreadableServer = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                XCTFail("an unreadable row must not be forced: the kill can orphan a live daemon")
                return ""
            }
            return "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\terr=Timeout\tstatus=unreachable"
        })
        let unreadable = unreadableServer.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)
        XCTAssertFalse(unreadable.ok)
        XCTAssertTrue(try XCTUnwrap(unreadable.error).contains("unreadable"))
    }

    func testKillRefusesAPaneWaitingOutItsUndoWindow() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        XCTAssertTrue(store.softCloseSession(session.id))

        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                XCTFail("an undo window is still the user's session")
                return ""
            }
            return "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=1\tclients=1\tcreated=1"
        })

        let response = server.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(try XCTUnwrap(response.error).contains("undo window"))
    }

    func testKillRefusesAPaneTheTargetDoesNotOwn() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        let server = makeServer(runner: { _ in
            "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=1\tclients=1\tcreated=1"
        })

        let response = server.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .right)
        XCTAssertFalse(response.ok, "the session has no split, so no right pane daemon exists")
        XCTAssertTrue(try XCTUnwrap(response.error).contains("no right pane daemon"))
    }

    func testKillingAnAttachedPrimaryPromotesItsSplitAndSuppressesTheQueuedCallback() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        store.setSplitVisibility(session.id, shown: true)
        let splitIdentity = try XCTUnwrap(session.splitPaneIdentity)
        // reconcile cannot tell a promotion from a split's own exit, so only this path rewrites the cell
        let dashboard = DashboardController()
        dashboard.open(members: [DashboardMember(session: session.id, surface: .split)])
        DashboardControllerRegistry.shared.register(library.windows[0].id, controller: dashboard)
        defer { DashboardControllerRegistry.shared.unregister(library.windows[0].id) }
        let primary = attachSurface(to: session, pane: .left)
        session.splitSurface = GhosttySurfaceView(workingDirectory: "/tmp", backedByZmx: true)

        var killed: [[String]] = []
        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                killed.append(invocation.arguments)
                return "killed session \(invocation.arguments[1])\n"
            }
            return "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=1\tclients=1\tcreated=1"
        })

        let response = server.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.pane, "left")
        XCTAssertFalse(session.hasSplit, "the survivor is promoted into the primary slot")
        XCTAssertEqual(session.paneIdentity, splitIdentity, "the survivor's identity moves up with it")
        XCTAssertEqual(killed.count, 1, "the promoted survivor's daemon must not be finalized too")
        // the follow-ups a store-only transition would have skipped
        let promoted = try XCTUnwrap(session.surface as? GhosttySurfaceView)
        XCTAssertNotNil(promoted.onFontSizeChange,
                        "the survivor is the sole pane now and must persist its own font size")
        XCTAssertFalse(promoted.isSplitPane, "promoteToPrimaryPane clears its split role")
        XCTAssertEqual(dashboard.members, [DashboardMember(session: session.id, surface: .primary)],
                       "the dashboard cell watching :right follows the survivor into the primary slot")

        primary.handleProcessExit()
        XCTAssertEqual(store.workspaces.first?.sessions.count, 1,
                       "the queued callback must be a no-op after the kill already ran the transition")
    }

    func testKillingAnAttachedPrimaryWithNoSurvivorClosesTheSessionOnce() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        attachSurface(to: session, pane: .left)

        var killed: [String] = []
        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                killed.append(invocation.arguments[1])
                return "killed session \(invocation.arguments[1])\n"
            }
            return "name=\(daemon)\tpid=1\tclients=1\tcreated=1"
        })

        XCTAssertTrue(server.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left).ok)

        XCTAssertTrue(store.workspaces.first?.sessions.isEmpty ?? false, "the session closes with its pane")
        XCTAssertEqual(killed, [daemon], "the identity this command killed must not be finalized again")
    }

    /// A claimed pane still waiting its turn has no client yet. The kill runs the transition now, and the
    /// teardown cancels its key, so no later grant can spawn a client that would recreate the daemon.
    func testKillingAClaimedUnspawnedPaneRunsTheTransitionAndCancelsItsTurn() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let view = attachSurface(to: session, pane: .left)
        let registry = SpawnRegistry(pacer: SpawnPacer())
        let key = UUID()
        registry.pacer.arm(order: [key], burst: [])
        registry.enqueue(view, key: key, provider: LaunchSeedProvider(shouldPace: true) { _ in
            LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        })
        XCTAssertFalse(view.requestSpawnPermit())
        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else { return "killed session \(invocation.arguments[1])\n" }
            return "name=\(daemon)\tpid=1\tclients=0\tcreated=1"
        })

        let response = server.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertTrue(store.workspaces.first?.sessions.isEmpty ?? false, "the session closes with its pane")
        XCTAssertTrue(registry.pacer.isPassthrough, "the teardown must cancel the pane's turn")
        registry.pacer.expedite(key)
        XCTAssertFalse(view.isRealized, "a cancelled key cannot be granted into a spawn")
    }

    func testAFallbackPaneIsNeverClosedByKillingThePreservedDaemon() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        // requested-live that fell back: the launch reap PRESERVES the claimed daemon while the pane comes
        // up as a plain shell, so this surface never attached to the daemon the command destroys
        let fresh = GhosttySurfaceView(workingDirectory: "/tmp", backedByZmx: false)
        session.surface = fresh

        let server = makeServer(runner: { invocation in
            invocation.arguments.first == "list"
                ? "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=1\tclients=0\tcreated=1"
                : "killed session \(invocation.arguments[1])\n"
        })

        XCTAssertTrue(server.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left).ok)

        XCTAssertEqual(store.workspaces.first?.sessions.count, 1, "a pane that never attached must survive")
        XCTAssertTrue(session.surface === fresh, "and keep the shell it actually has")
    }

    func testAFailedKillLeavesTheNaturalExitPathWorking() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        let view = attachSurface(to: session, pane: .left)

        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else { throw ZmxClient.CommandError.timedOut }
            return "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=1\tclients=1\tcreated=1"
        })

        XCTAssertFalse(server.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left).ok)
        XCTAssertEqual(store.workspaces.first?.sessions.count, 1)

        view.handleProcessExit()
        XCTAssertTrue(store.workspaces.first?.sessions.isEmpty ?? false,
                      "a failed kill must not have consumed the pane's own exit")
    }

    func testAnExplicitWindowScopesTheTargetToThatWindow() throws {
        let first = try XCTUnwrap(library.store(for: library.windows[0].id))
        let firstSession = try XCTUnwrap(first.workspaces.first?.sessions.first)
        let other = library.newWindow(name: "second")
        let second = try XCTUnwrap(library.store(for: other.id))
        let secondSession = try XCTUnwrap(second.workspaces.first?.sessions.first)

        let server = makeServer(runner: { invocation in
            invocation.arguments.first == "list"
                ? """
                  name=\(ZmxSupport.daemonName(for: firstSession.paneIdentity))\tpid=1\tclients=0\tcreated=1
                  name=\(ZmxSupport.daemonName(for: secondSession.paneIdentity))\tpid=2\tclients=0\tcreated=1
                  """
                : "killed session \(invocation.arguments[1])\n"
        })

        let wrongWindow = server.killZmxDaemon(target: secondSession.id.uuidString,
                                               window: library.windows[0].id.uuidString, pane: .left)
        XCTAssertFalse(wrongWindow.ok, "an explicit window must not be ignored for an exact id elsewhere")

        let unknown = server.killZmxDaemon(target: firstSession.id.uuidString, window: "nope", pane: .left)
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.error, "no such window: nope")

        XCTAssertTrue(server.killZmxDaemon(target: secondSession.id.uuidString,
                                           window: other.id.uuidString, pane: .left).ok)
    }

    func testKillReachesAClosedWindowsPaneThatNoStoreCanResolve() throws {
        let closedWindowID = UUID()
        let pane = UUID()
        let session = UUID()
        let snapshot = Snapshot(workspaces: [WorkspaceSnapshot(
            id: UUID(), name: "workspace 1",
            sessions: [SessionSnapshot(id: session, paneIdentity: pane, customName: "build", cwd: "/tmp")])])
        try PersistenceStore(directory: stateDir.appendingPathComponent("windows"),
                             fileName: "\(closedWindowID.uuidString).json").save(snapshot)

        // no index entry, so the window is UNINDEXED: ControlTargetResolver cannot see it at all
        var killed: [String] = []
        let server = makeServer(runner: { invocation in
            guard invocation.arguments.first == "list" else {
                killed.append(invocation.arguments[1])
                return "killed session \(invocation.arguments[1])\n"
            }
            return "name=\(ZmxSupport.daemonName(for: pane))\tpid=1\tclients=0\tcreated=1"
        })

        let response = server.killZmxDaemon(target: session.uuidString, window: nil, pane: .left)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(killed, [ZmxSupport.daemonName(for: pane)])
        XCTAssertEqual(response.result?.id, session.uuidString)
    }

    func testKillRefusesActiveOnEitherSelector() throws {
        let server = makeServer(runner: { _ in "" })

        let target = server.killZmxDaemon(target: "active", window: nil, pane: .left)
        XCTAssertFalse(target.ok)
        XCTAssertEqual(target.error, "zmx.kill needs a session id; 'active' is not accepted")

        let window = server.killZmxDaemon(target: "abc", window: "active", pane: .left)
        XCTAssertFalse(window.ok)
        XCTAssertEqual(window.error, "zmx.kill needs a window id; 'active' is not accepted")
    }

    func testKillRefusesToCloseAPaneZmxDidNotConfirmKilling() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let view = attachSurface(to: session, pane: .left)

        // zmx exits ZERO here: it could not reach the daemon and only unlinked the socket, so the process
        // may still be running. Closing the pane on that would strand it unreachable by name.
        let server = makeServer(runner: { invocation in
            invocation.arguments.first == "list"
                ? "name=\(daemon)\tpid=1\tclients=1\tcreated=1"
                : "cleaned up stale session \(daemon)\n"
        })

        let response = server.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)

        XCTAssertFalse(response.ok, "an unconfirmed kill must not report success")
        XCTAssertEqual(response.error, "\(daemon) did not confirm the kill; zmx cleaned up a stale socket "
            + "and the daemon may still be running")
        XCTAssertEqual(store.workspaces.first?.sessions.count, 1, "the pane stays until the kill is confirmed")

        view.handleProcessExit()
        XCTAssertTrue(store.workspaces.first?.sessions.isEmpty ?? false,
                      "and its own exit path is still armed")
    }

    func testKillRefusesOnEmptyOutputRatherThanAssumingSuccess() throws {
        let store = try XCTUnwrap(library.store(for: library.windows[0].id))
        let session = try XCTUnwrap(store.workspaces.first?.sessions.first)
        attachSurface(to: session, pane: .left)

        // a broken pipe after the kill was sent returns with nothing printed, which is not a confirmation
        let server = makeServer(runner: { invocation in
            invocation.arguments.first == "list"
                ? "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=1\tclients=1\tcreated=1"
                : ""
        })

        let response = server.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "could not kill \(ZmxSupport.daemonName(for: session.paneIdentity)): "
            + "no output")
        XCTAssertEqual(store.workspaces.first?.sessions.count, 1)
    }

    /// A zmx-backed surface for a pane, so the kill path sees a client of the daemon it destroys.
    @discardableResult
    private func attachSurface(to session: Session, pane: ZmxPaneRole) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: "/tmp", backedByZmx: true)
        view.session = session
        let sessionID = session.id
        let store = library.store(forSession: sessionID)
        view.onExit = { [weak view] in
            guard let view, let store else { return }
            agtermApp.handlePaneExit(view, store: store, sessionID: sessionID, library: self.library)
        }
        if pane == .left { session.surface = view } else { session.splitSurface = view }
        return view
    }

    /// A client whose runner returns `list` output, or throws when it is nil.
    private func makeServer(list output: String?,
                            remoteRunner: (any RemoteCommandRunner)? = nil) -> ControlServer {
        makeServer(runner: { _ in
            guard let output else { throw ZmxClient.CommandError.timedOut }
            return output
        }, remoteRunner: remoteRunner)
    }

    private func makeServer(runner: @escaping ZmxClient.Runner,
                            remoteRunner: (any RemoteCommandRunner)? = nil) -> ControlServer {
        ControlServer(
            library: library, actions: AppActions(library: library), settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            zmxClient: ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", runner: runner),
            remoteRunner: remoteRunner,
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
    }

    /// What the far side's own `zmx tree` prints: one document, one attachable session, and no `host` —
    /// it cannot know which name reached it, so the requesting app stamps that on afterwards.
    private static let projection = """
    {"ok":true,"result":{"remote":{\
    "endpoint":{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"},\
    "sessions":[{"id":"s1","name":"build","windowID":"w1","windowName":"main","workspaceID":"ws1",\
    "workspaceName":"work","cwd":"/repo",\
    "panes":[{"pane":"left","daemon":"agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"}]}]}}}
    """

    /// The same remote, whose session has a top/bottom split with both daemons live.
    private static let splitProjection = """
    {"ok":true,"result":{"remote":{\
    "endpoint":{"executable":"/Applications/agterm.app/zmx","socketDirectory":"/tmp/agterm-zmx-abc"},\
    "sessions":[{"id":"s1","name":"build","windowID":"w1","windowName":"main","workspaceID":"ws1",\
    "workspaceName":"work","cwd":"/repo","splitAxis":"horizontal",\
    "panes":[{"pane":"left","daemon":"agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"},\
    {"pane":"right","daemon":"agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2"}]}]}}}
    """
}

/// Records what it was asked to run and answers with a canned result, so the remote commands are covered
/// without a second Mac.
private final class FakeRemoteRunner: RemoteCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let result: RemoteCommandResult

    var invocations: [[String]] { lock.withLock { recorded } }

    init(result: RemoteCommandResult) {
        self.result = result
    }

    func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
        lock.withLock { recorded.append(argv) }
        return result
    }
}
