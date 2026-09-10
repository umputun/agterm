import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SurfaceFactorySeedTests: XCTestCase {
    private var stateDir: URL!
    private var store: AppStore!
    private var library: WindowLibrary!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-surface-factory-seed-tests-\(UUID().uuidString)", isDirectory: true)
            store = AppStore(persistence: PersistenceStore(directory: stateDir))
            library = WindowLibrary(directory: stateDir)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            store = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    private let configuration = ZmxSupport.Configuration(
        executablePath: "/bin/zmx",
        environment: ["SHELL": "/bin/zsh", "ZDOTDIR": "/bundle/zsh"],
        daemonName: "agterm-pane",
        socketDirectory: "/tmp/zmx",
        paneID: "pane"
    )

    func testWrappedPrimaryConsumesReplayOnceWithoutTouchingStickyOverride() throws {
        let session = restoredSession()
        session.pendingForegroundCommand = ["/usr/bin/tail", "-f", "/tmp/log file"]
        session.restoreCommand = "sticky"
        session.pendingRestoreCommand = "sticky"

        let first = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .left, denylist: []
        ))
        XCTAssertEqual(first.command, ZmxSupport.attachCommand(
            configuration, replaying: ["/usr/bin/tail", "-f", "/tmp/log file"], denylist: []
        ))
        XCTAssertNil(first.initialInput)
        XCTAssertNil(session.pendingForegroundCommand)
        XCTAssertEqual(session.restoreCommand, "sticky")
        XCTAssertEqual(session.pendingRestoreCommand, "sticky")

        let second = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .left, denylist: []
        ))
        XCTAssertEqual(second.command, configuration.command)
        XCTAssertNil(second.initialInput)
    }

    func testWrappedSplitConsumesReplayOnceWithoutTouchingStickyOverride() throws {
        let session = restoredSession()
        session.pendingSplitForegroundCommand = ["/usr/bin/watch", "date"]
        session.splitRestoreCommand = "sticky split"
        session.pendingSplitRestoreCommand = "sticky split"

        let first = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .right, denylist: []
        ))
        XCTAssertEqual(first.command, ZmxSupport.attachCommand(
            configuration, replaying: ["/usr/bin/watch", "date"], denylist: []
        ))
        XCTAssertNil(first.initialInput)
        XCTAssertNil(session.pendingSplitForegroundCommand)
        XCTAssertEqual(session.splitRestoreCommand, "sticky split")
        XCTAssertEqual(session.pendingSplitRestoreCommand, "sticky split")

        let second = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .right, denylist: []
        ))
        XCTAssertEqual(second.command, configuration.command)
        XCTAssertNil(second.initialInput)
    }

    func testFallbackDoesNotConsumeEitherReplay() {
        let session = restoredSession()
        session.pendingForegroundCommand = ["primary"]
        session.pendingSplitForegroundCommand = ["split"]

        XCTAssertNil(ZmxLaunch.surfaceSeed(
            disposition: .fallback, session: session, pane: .left, denylist: []
        ))
        XCTAssertNil(ZmxLaunch.surfaceSeed(
            disposition: .fallback, session: session, pane: .right, denylist: []
        ))
        XCTAssertEqual(session.pendingForegroundCommand, ["primary"])
        XCTAssertEqual(session.pendingSplitForegroundCommand, ["split"])
    }

    func testDeniedReplaySuppressesDurableCommandOnBothPanes() throws {
        for pane in [StatusPane.left, .right] {
            let session = restoredSession()
            setDurableCommand("echo durable", on: pane, session: session)
            setPendingCapture(["/usr/bin/tmux", "attach"], on: pane, session: session)

            let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(
                disposition: .wrapped(configuration), session: session, pane: pane, denylist: ["tmux"]
            ))

            XCTAssertEqual(seed.command, configuration.command)
            XCTAssertNil(seed.initialInput)
            XCTAssertNil(pendingCapture(on: pane, session: session))
        }
    }

    func testRestoredWrappedPanesUseDurableCommandWhenCaptureIsAbsent() throws {
        for pane in [StatusPane.left, .right] {
            let session = restoredSession()
            setDurableCommand("printf durable && echo 'two words'", on: pane, session: session)

            let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(
                disposition: .wrapped(configuration), session: session, pane: pane, denylist: []
            ))

            XCTAssertNotEqual(seed.command, configuration.command)
            XCTAssertTrue(seed.command.contains("printf durable && echo"))
            XCTAssertNil(seed.initialInput)
        }
    }

    func testFreshWrappedPrimaryUsesCreateOnlyPayload() throws {
        let session = Session(initialCwd: "/tmp")
        session.initialCommand = "ssh example"

        let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .left, denylist: []
        ))

        XCTAssertEqual(seed.command, ZmxSupport.attachCommand(
            configuration, replaying: nil, creationCommand: "ssh example", denylist: []
        ))
        XCTAssertNil(seed.initialInput)
    }

    func testFreshWrappedSplitUsesCreateOnlyPayload() throws {
        let session = Session(initialCwd: "/tmp")
        session.splitInitialCommand = "watch date"

        let seed = try XCTUnwrap(ZmxLaunch.surfaceSeed(
            disposition: .wrapped(configuration), session: session, pane: .right, denylist: []
        ))

        XCTAssertEqual(seed.command, ZmxSupport.attachCommand(
            configuration, replaying: nil, creationCommand: "watch date", denylist: []
        ))
        XCTAssertNil(seed.initialInput)
    }

    // MARK: - factory wiring

    // the hosted scheme's isolated state dir latches restore mode `.none`, so both factories build an
    // ordinary disposition and a fresh pane's durable command is the seed in force.
    func testPrimaryFactoryDefersItsSeedAndResolvesOnlyTheLeftSlot() {
        let restored = restoredSession()
        setPendingCapture(["primary"], on: .left, session: restored)
        setPendingCapture(["split"], on: .right, session: restored)

        let view = primarySurface(for: restored)

        XCTAssertNotNil(view.launchSeed)
        XCTAssertEqual(pendingCapture(on: .left, session: restored), ["primary"])
        XCTAssertEqual(pendingCapture(on: .right, session: restored), ["split"])

        view.resolveLaunchSeed()

        XCTAssertNil(pendingCapture(on: .left, session: restored))
        XCTAssertEqual(pendingCapture(on: .right, session: restored), ["split"])

        let fresh = Session(initialCwd: "/tmp")
        fresh.initialCommand = "echo primary"
        XCTAssertEqual(primarySurface(for: fresh).resolveLaunchSeed(),
                       LaunchSeed(command: "echo primary", initialInput: nil, waitAfterCommand: false))
    }

    func testSplitFactoryDefersItsSeedAndResolvesOnlyTheRightSlot() {
        let restored = restoredSession()
        setPendingCapture(["primary"], on: .left, session: restored)
        setPendingCapture(["split"], on: .right, session: restored)

        let view = splitSurface(for: restored)

        XCTAssertNotNil(view.launchSeed)
        XCTAssertEqual(pendingCapture(on: .left, session: restored), ["primary"])
        XCTAssertEqual(pendingCapture(on: .right, session: restored), ["split"])

        view.resolveLaunchSeed()

        XCTAssertEqual(pendingCapture(on: .left, session: restored), ["primary"])
        XCTAssertNil(pendingCapture(on: .right, session: restored))

        let fresh = Session(initialCwd: "/tmp")
        fresh.splitInitialCommand = "echo split"
        XCTAssertEqual(splitSurface(for: fresh).resolveLaunchSeed(),
                       LaunchSeed(command: "echo split", initialInput: nil, waitAfterCommand: false))
    }

    /// Arming expects every restored primary and shown right pane, before any provider exists to say which
    /// of them replays a program. A pane that turns out to replay nothing must leave the queue at
    /// construction, or the drain waits forever on a permit it never asks for.
    func testAPrimaryThatReplaysNothingLeavesTheLaunchQueue() {
        let session = restoredSession()
        let registry = SpawnRegistry(pacer: SpawnPacer())
        registry.pacer.arm(order: [session.paneIdentity], burst: [])

        let view = primarySurface(for: session, registry: registry)

        XCTAssertNil(registry.view(for: session.paneIdentity))
        XCTAssertTrue(registry.pacer.isPassthrough)
        XCTAssertTrue(view.requestSpawnPermit(), "an unpaced pane must not wait on a permit")
    }

    func testASplitThatReplaysNothingLeavesTheLaunchQueue() throws {
        let session = restoredSession()
        session.splitPaneIdentity = UUID()
        let splitKey = try XCTUnwrap(session.splitPaneIdentity)
        let registry = SpawnRegistry(pacer: SpawnPacer())
        registry.pacer.arm(order: [splitKey], burst: [])

        let view = splitSurface(for: session, registry: registry)

        XCTAssertNil(registry.view(for: splitKey))
        XCTAssertTrue(registry.pacer.isPassthrough)
        XCTAssertTrue(view.requestSpawnPermit(), "an unpaced pane must not wait on a permit")
    }

    private func primarySurface(for session: Session, registry: SpawnRegistry? = nil) -> GhosttySurfaceView {
        agtermApp.makeSurface(for: session, store: store, env: [:], services: services(registry))
    }

    private func splitSurface(for session: Session, registry: SpawnRegistry? = nil) -> GhosttySurfaceView {
        agtermApp.makeSplitSurface(for: session, store: store, env: [:], services: services(registry))
    }

    /// A restored split hidden at quit is not armed: shown later it attaches through the unarmed path,
    /// its capture still waiting for that spawn, and the queue drains without it.
    func testAHiddenSplitShownLaterAttachesUnarmedWithItsCaptureIntact() {
        let session = restoredSession()
        session.splitPaneIdentity = UUID()
        session.hasSplit = true
        setPendingCapture(["split"], on: .right, session: session)
        let registry = SpawnRegistry(pacer: SpawnPacer())
        registry.pacer.arm(order: [session.paneIdentity], burst: [])

        let view = splitSurface(for: session, registry: registry)

        XCTAssertTrue(view.requestSpawnPermit(), "a key outside the armed order never waits")
        XCTAssertNotNil(view.launchSeed)
        XCTAssertEqual(pendingCapture(on: .right, session: session), ["split"])
        XCTAssertFalse(registry.pacer.isPassthrough, "the armed primary still waits its turn")
    }

    private func scratchSurface(for session: Session) -> GhosttySurfaceView {
        agtermApp.makeScratchSurface(for: session, store: store, env: [:], suppressAutoFocus: true,
                                     actions: AppActions(library: library))
    }

    private func overlaySurface(for session: Session) -> GhosttySurfaceView {
        agtermApp.makeOverlaySurface(for: session, store: store, pane: nil, env: [:])
    }

    private func remoteSession(reportedCwd: String) -> Session {
        let session = Session(initialCwd: NSHomeDirectory(), remoteHost: "user@box")
        session.currentCwd = reportedCwd
        return session
    }

    func testLocalShellFactoriesOnARemoteSessionSeedHomeWhenTheReportedPathIsMissing() {
        let session = remoteSession(reportedCwd: stateDir.appendingPathComponent("only-on-the-remote").path)
        XCTAssertEqual(scratchSurface(for: session).workingDirectory, NSHomeDirectory())
        XCTAssertEqual(overlaySurface(for: session).workingDirectory, NSHomeDirectory())
        XCTAssertEqual(splitSurface(for: session).workingDirectory, NSHomeDirectory())
    }

    func testLocalShellFactoriesOnARemoteSessionSeedTheReportedPathWhenItExistsLocally() throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let session = remoteSession(reportedCwd: stateDir.path)
        XCTAssertEqual(scratchSurface(for: session).workingDirectory, stateDir.path)
        XCTAssertEqual(overlaySurface(for: session).workingDirectory, stateDir.path)
        XCTAssertEqual(splitSurface(for: session).workingDirectory, stateDir.path)
    }

    func testARestoredSplitPathOnARemoteSessionStillFollowsTheLocalRule() {
        let session = remoteSession(reportedCwd: NSHomeDirectory())
        session.initialSplitCwd = stateDir.appendingPathComponent("split-only-on-the-remote").path
        XCTAssertEqual(splitSurface(for: session).workingDirectory, NSHomeDirectory())
    }

    func testAnExplicitOverlayCwdIsKeptOnARemoteSession() {
        let session = remoteSession(reportedCwd: stateDir.appendingPathComponent("only-on-the-remote").path)
        session.overlayCwd = "/nowhere/explicit"
        XCTAssertEqual(overlaySurface(for: session).workingDirectory, "/nowhere/explicit")
    }

    func testLocalSessionFactoriesKeepTheirInheritedPaths() {
        let session = Session(initialCwd: "/nowhere")
        session.currentCwd = "/nowhere/primary"
        session.initialSplitCwd = "/nowhere/restored-split"
        XCTAssertEqual(scratchSurface(for: session).workingDirectory, "/nowhere/primary")
        XCTAssertEqual(overlaySurface(for: session).workingDirectory, "/nowhere/primary")
        XCTAssertEqual(splitSurface(for: session).workingDirectory, "/nowhere/restored-split")
    }

    func testASplitCreatedAfterClosingTheAttachTimeSplitIsALocalLoginShell() throws {
        let workspace = store.addWorkspace(name: "remote")
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: NSHomeDirectory(),
                                                     command: "ssh -tt box zmx attach primary",
                                                     remoteHost: "box"))
        session.splitInitialCommand = "ssh -tt box zmx attach split"
        session.currentCwd = stateDir.appendingPathComponent("only-on-the-remote").path
        session.hasSplit = true
        session.isSplit = true

        XCTAssertEqual(splitSurface(for: session).resolveLaunchSeed().command, "ssh -tt box zmx attach split")
        XCTAssertEqual(splitSurface(for: session).resolveLaunchSeed().command, "ssh -tt box zmx attach split",
                       "the attach seed is durable across a re-created split surface")

        store.closeSplit(session.id)

        let fresh = splitSurface(for: session)
        XCTAssertNil(fresh.resolveLaunchSeed().command)
        XCTAssertEqual(fresh.workingDirectory, NSHomeDirectory())
    }

    func testTheQuickTerminalStartsWhereTheActiveSessionsLocalRuleSays() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let activeStore = try XCTUnwrap(library.activeStore)
        let local = try XCTUnwrap(activeStore.activeSession)
        local.currentCwd = "/nowhere/primary"
        XCTAssertEqual(agtermApp.quickTerminalCwd(library: library), "/nowhere/primary")

        let workspace = try XCTUnwrap(activeStore.currentWorkspaceID)
        let remote = try XCTUnwrap(activeStore.addSession(toWorkspace: workspace, cwd: home, remoteHost: "box"))
        activeStore.selectSession(remote.id)
        remote.currentCwd = stateDir.appendingPathComponent("only-on-the-remote").path
        XCTAssertEqual(agtermApp.quickTerminalCwd(library: library), home)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        remote.currentCwd = stateDir.path
        XCTAssertEqual(agtermApp.quickTerminalCwd(library: library), stateDir.path)

        XCTAssertEqual(agtermApp.quickTerminalCwd(library: nil), home)
    }

    func testThePolicyCarriesTheReapsRunningNames() {
        let context = agtermApp.LaunchSpawnContext()
        context.runningNames = ["agterm-alive"]

        XCTAssertEqual(agtermApp.launchSeedPolicy(GhosttyApp.shared, context: context).runningNames, ["agterm-alive"])
        XCTAssertNil(agtermApp.launchSeedPolicy(GhosttyApp.shared, context: agtermApp.LaunchSpawnContext()).runningNames,
                     "a skipped or failed list paces every replaying live pane")
    }

    private func services(_ registry: SpawnRegistry?) -> agtermApp.SurfaceServices {
        agtermApp.SurfaceServices(library: library, actions: AppActions(library: library), zmxForegroundResolver: nil, spawnRegistry: registry,
                                  launchContext: agtermApp.LaunchSpawnContext())
    }

    private func restoredSession() -> Session {
        let session = Session(initialCwd: "/tmp")
        session.wasRestored = true
        return session
    }

    private func setDurableCommand(_ command: String, on pane: StatusPane, session: Session) {
        switch pane {
        case .left: session.initialCommand = command
        case .right: session.splitInitialCommand = command
        case .scratch: XCTFail("scratch is not restored")
        }
    }

    private func setPendingCapture(_ argv: [String], on pane: StatusPane, session: Session) {
        switch pane {
        case .left: session.pendingForegroundCommand = argv
        case .right: session.pendingSplitForegroundCommand = argv
        case .scratch: XCTFail("scratch is not restored")
        }
    }

    private func pendingCapture(on pane: StatusPane, session: Session) -> [String]? {
        switch pane {
        case .left: session.pendingForegroundCommand
        case .right: session.pendingSplitForegroundCommand
        case .scratch: nil
        }
    }
}
