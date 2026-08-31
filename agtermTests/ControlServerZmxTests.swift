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
    private func makeServer(list output: String?) -> ControlServer {
        makeServer(runner: { _ in
            guard let output else { throw ZmxClient.CommandError.timedOut }
            return output
        })
    }

    private func makeServer(runner: @escaping ZmxClient.Runner) -> ControlServer {
        ControlServer(
            library: library, actions: AppActions(library: library), settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            zmxClient: ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", runner: runner),
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
    }
}
