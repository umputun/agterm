import AppKit
import Darwin
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppDelegateCaptureTests: XCTestCase {
    func testARemoteSessionIsNeitherReadNorCounted() {
        let local = Session(initialCwd: "/tmp")
        local.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        let remote = Session(initialCwd: "/tmp", remoteHost: "buildbox")
        remote.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        var read: [Session] = []

        let count = AppDelegate.captureForegroundCommands(
            sessions: [local, remote],
            commandReader: { view, _, _ in
                read.append(view === local.surface ? local : remote)
                return ["worker"]
            })

        // its foreground is an ssh client the save drops, so reading it inflates the count and spends the
        // exit budget on a pane nothing will persist
        XCTAssertEqual(count, 1)
        XCTAssertTrue(read.allSatisfy { $0 === local })
        XCTAssertNil(remote.foregroundCommand)
        XCTAssertEqual(local.foregroundCommand, ["worker"])
    }

    func testLivePrimaryAndHiddenSplitResolveThroughTheDaemonLookup() throws {
        let primaryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let splitID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let session = Session(initialCwd: "/tmp", paneIdentity: primaryID, splitPaneIdentity: splitID)
        session.surface = GhosttySurfaceView(
            workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": primaryID.uuidString], backedByZmx: true)
        let split = GhosttySurfaceView(
            workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": splitID.uuidString], backedByZmx: true)
        split.setPaneRole(.split)
        session.splitSurface = split
        session.hasSplit = true
        session.isSplit = false
        let leaders = [ZmxSupport.daemonName(for: primaryID): pid_t(11), ZmxSupport.daemonName(for: splitID): 21]

        let count = AppDelegate.captureForegroundCommands(
            sessions: [session], zmxForeground: ZmxDaemonForeground { leaders[$0] },
            commandReader: { view, _, zmxForeground in
                let name = try? XCTUnwrap(view.zmxSessionName)
                let pid = name.flatMap { zmxForeground?.foregroundPID($0) }
                return pid.map { ["worker", String($0)] }
            })

        XCTAssertEqual(count, 2)
        XCTAssertEqual(session.foregroundCommand, ["worker", "11"])
        XCTAssertEqual(session.splitForegroundCommand, ["worker", "21"])
    }

    // #1042: one daemon too busy to answer zmx's listing cost every pane its command at quit
    func testExitCaptureReadsAStoppedDaemonsPaneAndItsHealthyNeighbour() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-stopped-daemon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let daemons = LiveDaemons(stateDirectory: state)
        defer {
            daemons.stop()
            try? FileManager.default.removeItem(at: state)
        }
        let stopped = liveSession(paneID: UUID())
        let healthy = liveSession(paneID: UUID())
        try daemons.start(paneID: stopped.paneIdentity, command: ["/bin/sleep", "601"])
        try daemons.start(paneID: healthy.paneIdentity, command: ["/bin/sleep", "602"])
        let lookup = ZmxDaemonForeground.socket(directory: daemons.socketDirectory)
        try daemons.waitForCommands(of: [stopped, healthy], lookup: lookup)
        try daemons.suspend(paneID: stopped.paneIdentity)

        let count = AppDelegate.captureForegroundCommands(
            sessions: [stopped, healthy], zmxForeground: lookup, preserveUnconsumedPending: true)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(stopped.foregroundCommand, ["/bin/sleep", "601"])
        XCTAssertEqual(healthy.foregroundCommand, ["/bin/sleep", "602"])
    }

    func testHiddenNonLiveSplitStaysNilWhileShownNonLivePanesKeepTheOldPath() {
        let hidden = Session(initialCwd: "/tmp")
        hidden.splitSurface = GhosttySurfaceView(workingDirectory: "/tmp")
        hidden.hasSplit = true
        hidden.isSplit = false
        hidden.splitForegroundCommand = ["stale"]
        var hiddenReads = 0

        _ = AppDelegate.captureForegroundCommands(
            sessions: [hidden], commandReader: { _, _, _ in
                hiddenReads += 1
                return ["wrong"]
            })

        XCTAssertEqual(hiddenReads, 0)
        XCTAssertNil(hidden.splitForegroundCommand)

        let shown = Session(initialCwd: "/tmp")
        shown.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        let split = GhosttySurfaceView(workingDirectory: "/tmp")
        split.setPaneRole(.split)
        shown.splitSurface = split
        shown.hasSplit = true
        shown.isSplit = true
        _ = AppDelegate.captureForegroundCommands(
            sessions: [shown], commandReader: { view, _, zmxForeground in
                XCTAssertNil(zmxForeground)
                return [view.isSplitPane ? "split" : "primary"]
            })

        XCTAssertEqual(shown.foregroundCommand, ["primary"])
        XCTAssertEqual(shown.splitForegroundCommand, ["split"])
    }

    func testAnUnresolvedPaneClearsItsSlotWithoutCostingTheNextPaneItsCommand() {
        let unresolved = liveSession(paneID: UUID())
        let healthy = liveSession(paneID: UUID())
        unresolved.foregroundCommand = ["stale"]
        let healthyName = ZmxSupport.daemonName(for: healthy.paneIdentity)

        let count = AppDelegate.captureForegroundCommands(
            sessions: [unresolved, healthy], zmxForeground: ZmxDaemonForeground { $0 == healthyName ? 30 : nil },
            commandReader: { view, _, zmxForeground in
                view.zmxSessionName.flatMap { zmxForeground?.foregroundPID($0) }.map { ["worker", String($0)] }
            })

        XCTAssertEqual(count, 1)
        XCTAssertNil(unresolved.foregroundCommand)
        XCTAssertEqual(healthy.foregroundCommand, ["worker", "30"])
    }

    func testMidLoopExpiryLeavesTheRemainingPanesWithoutACommand() {
        let first = liveSession(paneID: UUID())
        let second = liveSession(paneID: UUID())
        second.foregroundCommand = ["stale"]
        var checks = 0

        _ = AppDelegate.captureForegroundCommands(
            sessions: [first, second], zmxForeground: ZmxDaemonForeground { _ in 30 },
            timeRemaining: {
                checks += 1
                return checks == 1
            },
            commandReader: { _, _, _ in ["captured"] })

        XCTAssertEqual(first.foregroundCommand, ["captured"])
        XCTAssertNil(second.foregroundCommand)
    }

    func testCapturePolicyIncludesLiveAndRerunButNotFreshShells() {
        XCTAssertTrue(GhosttyApp.capturesForegroundOnExit(mode: .live))
        XCTAssertTrue(GhosttyApp.capturesForegroundOnExit(mode: .rerun))
        XCTAssertFalse(GhosttyApp.capturesForegroundOnExit(mode: .none))
    }

    func testLastWindowClosePersistsInjectedCaptureBeforeTeardown() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-exit-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let library = WindowLibrary(directory: state)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        _ = try XCTUnwrap(store.activeSession)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WindowAccessor.TitleProbeView(
            windowID: windowID, library: library, store: store,
            captureOnExit: { sessions in
                sessions.first?.foregroundCommand = ["worker", "--live"]
                return 1
            })

        window.close()

        let persisted = PersistenceStore(
            directory: state.appendingPathComponent("windows"), fileName: "\(windowID.uuidString).json").load()
        XCTAssertEqual(persisted.workspaces.first?.sessions.first?.foregroundCommand, ["worker", "--live"])
    }

    func testApplicationTerminationPersistsInjectedCaptureBeforeSavingOpenWindows() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-terminate-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let library = WindowLibrary(directory: state)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let delegate = AppDelegate()
        delegate.library = library
        delegate.captureOnExit = { sessions in
            sessions.first?.foregroundCommand = ["worker", "--terminate"]
            return 1
        }

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let persisted = PersistenceStore(
            directory: state.appendingPathComponent("windows"), fileName: "\(windowID.uuidString).json").load()
        XCTAssertTrue(library.isTerminating)
        XCTAssertEqual(persisted.workspaces.first?.sessions.first?.foregroundCommand,
                       ["worker", "--terminate"])
    }

    func testFreshLaunchChangedToRerunCapturesAtFirstExit() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-dynamic-exit-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let library = WindowLibrary(directory: state)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: state))
        XCTAssertEqual(settings.settings.effectiveRestoreMode, .none)
        let capture = AppDelegate.makeExitCapture(settingsModel: settings, zmxForeground: nil)
        session.pendingForegroundCommand = ["worker", "--first-rerun"]
        XCTAssertTrue(settings.setRestoreMode(.rerun))
        let delegate = AppDelegate()
        delegate.library = library
        delegate.captureOnExit = capture

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let persisted = PersistenceStore(
            directory: state.appendingPathComponent("windows"), fileName: "\(windowID.uuidString).json").load()
        XCTAssertEqual(persisted.workspaces.first?.sessions.first?.foregroundCommand,
                       ["worker", "--first-rerun"])
    }

    func testLiveLaunchChangedToRerunCapturesDaemonForegroundAtExit() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-live-to-rerun-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let worker = try startWorker()
        defer { stopWorker(worker) }
        let library = WindowLibrary(directory: state)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        session.surface = GhosttySurfaceView(
            workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": session.paneIdentity.uuidString], backedByZmx: true)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: state))
        XCTAssertTrue(settings.setRestoreMode(.live))
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let capture = AppDelegate.makeExitCapture(
            settingsModel: settings, zmxForeground: ZmxDaemonForeground { $0 == daemon ? worker.processIdentifier : nil })
        XCTAssertTrue(settings.setRestoreMode(.rerun))
        let delegate = AppDelegate()
        delegate.library = library
        delegate.captureOnExit = capture

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let persisted = PersistenceStore(
            directory: state.appendingPathComponent("windows"), fileName: "\(windowID.uuidString).json").load()
        XCTAssertEqual(persisted.workspaces.first?.sessions.first?.foregroundCommand?.last, "30")
    }

    func testConfiguredNoneClearsCapturedAndPendingSlotsOnLastWindowClose() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-disabled-exit-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let library = WindowLibrary(directory: state)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: state))
        XCTAssertEqual(settings.settings.effectiveRestoreMode, .none)
        session.foregroundCommand = ["stale-primary"]
        session.splitForegroundCommand = ["stale-split"]
        session.pendingForegroundCommand = ["pending-primary"]
        session.pendingSplitForegroundCommand = ["pending-split"]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WindowAccessor.TitleProbeView(
            windowID: windowID, library: library, store: store,
            captureOnExit: AppDelegate.makeExitCapture(settingsModel: settings, zmxForeground: nil))

        window.close()

        XCTAssertNil(session.foregroundCommand)
        XCTAssertNil(session.splitForegroundCommand)
        XCTAssertNil(session.pendingForegroundCommand)
        XCTAssertNil(session.pendingSplitForegroundCommand)
        let persisted = PersistenceStore(
            directory: state.appendingPathComponent("windows"), fileName: "\(windowID.uuidString).json").load()
        XCTAssertNil(persisted.workspaces.first?.sessions.first?.foregroundCommand)
        XCTAssertNil(persisted.workspaces.first?.sessions.first?.splitForegroundCommand)
    }

    private func liveSession(paneID: UUID) -> Session {
        let session = Session(initialCwd: "/tmp", paneIdentity: paneID)
        session.surface = GhosttySurfaceView(
            workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": paneID.uuidString], backedByZmx: true)
        return session
    }

    private func startWorker() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func stopWorker(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    func testExitCapturePreservesAnUnconsumedPendingArgvWhenTheReadYieldsNothing() {
        let session = Session(initialCwd: "/tmp")
        session.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        session.pendingForegroundCommand = ["npm", "run", "dev"]

        let count = AppDelegate.captureForegroundCommands(
            sessions: [session], zmxForeground: nil, preserveUnconsumedPending: true,
            commandReader: { _, _, _ in nil })

        XCTAssertEqual(count, 0)
        XCTAssertEqual(session.foregroundCommand, ["npm", "run", "dev"])
    }

    func testExitCapturePreservesAHiddenSplitArgvWhenNoRightSurfaceWasBuilt() {
        let session = Session(initialCwd: "/tmp")
        session.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        session.hasSplit = true
        session.isSplit = false
        session.pendingSplitForegroundCommand = ["tail", "-f", "log"]

        _ = AppDelegate.captureForegroundCommands(
            sessions: [session], zmxForeground: nil, preserveUnconsumedPending: true,
            commandReader: { _, _, _ in nil })

        XCTAssertNil(session.splitSurface)
        XCTAssertEqual(session.splitForegroundCommand, ["tail", "-f", "log"])
    }

    func testExitCaptureDoesNotResurrectAnArgvTheFactoryAlreadyConsumed() {
        let session = Session(initialCwd: "/tmp")
        session.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        session.pendingForegroundCommand = ["npm", "run", "dev"]
        XCTAssertEqual(session.takePendingForegroundCommand(pane: .left), ["npm", "run", "dev"])

        _ = AppDelegate.captureForegroundCommands(
            sessions: [session], zmxForeground: nil, preserveUnconsumedPending: true,
            commandReader: { _, _, _ in nil })

        XCTAssertNil(session.foregroundCommand)
    }

    // a paced pane mounts its surface seconds before it spawns; the argv must survive a quit landing in that
    // window, in both replaying modes.
    func testCleanQuitKeepsTheArgvOfAMountedButUnspawnedPane() throws {
        let rerun = Session(initialCwd: "/tmp")
        rerun.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        rerun.pendingForegroundCommand = ["npm", "run", "dev"]

        _ = AppDelegate.captureForegroundCommands(sessions: [rerun], preserveUnconsumedPending: true)

        XCTAssertFalse(try XCTUnwrap(rerun.surface).isRealized)
        XCTAssertEqual(rerun.foregroundCommand, ["npm", "run", "dev"])

        let paneID = UUID()
        let live = Session(initialCwd: "/tmp", paneIdentity: paneID)
        live.surface = GhosttySurfaceView(
            workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": paneID.uuidString], backedByZmx: true)
        live.pendingForegroundCommand = ["npm", "run", "dev"]
        // the daemon this pane would attach to does not exist yet, which is why the pane is paced at all.
        _ = AppDelegate.captureForegroundCommands(
            sessions: [live], zmxForeground: ZmxDaemonForeground { _ in nil }, preserveUnconsumedPending: true)

        XCTAssertEqual(live.foregroundCommand, ["npm", "run", "dev"])
    }

    func testOnDemandCapturePersistsNothingForAMountedButUnspawnedPane() {
        let session = Session(initialCwd: "/tmp")
        session.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        session.pendingForegroundCommand = ["npm", "run", "dev"]

        let count = AppDelegate.captureForegroundCommands(sessions: [session])

        XCTAssertEqual(count, 0)
        XCTAssertNil(session.foregroundCommand)
        XCTAssertEqual(session.pendingForegroundCommand, ["npm", "run", "dev"])
    }

    // restore.capture persisting an unconsumed slot while it stays armed lets a later show replay it once and
    // a crash replay the persisted copy again.
    func testOnDemandCaptureLeavesAnUnconsumedPendingArgvOutOfTheSnapshot() {
        let session = Session(initialCwd: "/tmp")
        session.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        session.hasSplit = true
        session.isSplit = false
        session.pendingSplitForegroundCommand = ["tail", "-f", "log"]

        _ = AppDelegate.captureForegroundCommands(
            sessions: [session], zmxForeground: nil, commandReader: { _, _, _ in nil })

        XCTAssertNil(session.splitForegroundCommand)
        XCTAssertEqual(session.takePendingForegroundCommand(pane: .right), ["tail", "-f", "log"])
    }

    func testOpenURLsLandTheFolderInTheActiveWindowThenSelectTheLinkedSession() throws {
        let fixture = try LinkFixture()
        defer { fixture.tearDown() }
        let linked = try XCTUnwrap(fixture.back.addSession(toWorkspace: fixture.back.workspaces[0].id,
                                                           cwd: NSTemporaryDirectory(), select: false))
        let folder = fixture.state.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frontCount = fixture.front.workspaces[0].sessions.count

        fixture.delegate.application(NSApp, open: [folder, try XCTUnwrap(URL(string: "agterm://session/\(linked.id.uuidString)"))])

        XCTAssertEqual(fixture.front.workspaces[0].sessions.count, frontCount + 1)
        XCTAssertEqual(fixture.front.workspaces[0].sessions.last?.effectiveCwd, folder.path)
        XCTAssertEqual(fixture.library.frontmostWindowID, fixture.backID)
        XCTAssertEqual(fixture.back.selectedSessionID, linked.id)
    }

    func testColdLaunchFolderWaitsForEveryWindowThenLandsInTheLaunchWindow() throws {
        let fixture = try LinkFixture()
        defer { fixture.tearDown() }
        let folder = fixture.state.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frontCount = fixture.front.workspaces[0].sessions.count
        let reopened = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                                backing: .buffered, defer: false)
        reopened.isReleasedWhenClosed = false
        defer { reopened.orderOut(nil) }
        WindowRegistry.shared.retire(fixture.frontID, window: fixture.hostFront)
        WindowRegistry.shared.register(fixture.frontID, window: reopened)

        fixture.delegate.queueOpenDirectories([folder.path], cold: true)
        XCTAssertEqual(fixture.front.workspaces[0].sessions.count, frontCount)
        fixture.library.frontmostWindowID = fixture.backID
        WindowRegistry.shared.markPresented(fixture.frontID, window: reopened)
        WindowRegistry.shared.markPresented(fixture.backID, window: fixture.hostBack)

        let deadline = Date(timeIntervalSinceNow: 10)
        while fixture.front.workspaces[0].sessions.count == frontCount, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        XCTAssertEqual(fixture.front.workspaces[0].sessions.last?.effectiveCwd, folder.path)
        XCTAssertEqual(fixture.library.frontmostWindowID, fixture.frontID)
    }

    func testColdLaunchFolderLandsInTheLaunchWindowWhileTheFrontmostOneHasNoWorkspace() throws {
        let fixture = try LinkFixture()
        defer { fixture.tearDown() }
        let folder = fixture.state.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frontCount = fixture.front.workspaces[0].sessions.count
        WindowRegistry.shared.retire(fixture.frontID, window: fixture.hostFront)
        WindowRegistry.shared.register(fixture.frontID, window: fixture.hostFront)
        fixture.back.workspaces.removeAll()
        fixture.library.frontmostWindowID = fixture.backID
        WindowRegistry.shared.markPresented(fixture.frontID, window: fixture.hostFront)
        WindowRegistry.shared.markPresented(fixture.backID, window: fixture.hostBack)

        fixture.delegate.queueOpenDirectories([folder.path], cold: true)

        XCTAssertEqual(fixture.front.workspaces[0].sessions.count, frontCount + 1)
        XCTAssertEqual(fixture.library.frontmostWindowID, fixture.frontID)
    }

    func testColdLaunchFolderForAnEmptyRemoteLaunchWindowIsRefusedThere() throws {
        let fixture = try LinkFixture()
        defer { fixture.tearDown() }
        let folder = fixture.state.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frontCount = fixture.front.workspaces[0].sessions.count
        let remoteID = fixture.library.newRemoteWindow(host: "box").id
        let remoteStore = try XCTUnwrap(fixture.library.store(for: remoteID))
        remoteStore.workspaces.removeAll()
        let mirror = RemoteCatalogMirror(host: "box", store: remoteStore, effects: NoCatalogEffects(), viewState: RemoteWindowViewState())
        let remote = RemoteCatalogActions(mirror: mirror, runner: { _ in (255, "") })
        remoteStore.remoteActions = remote
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer {
            WindowRegistry.shared.unregister(remoteID)
            host.orderOut(nil)
        }
        WindowRegistry.shared.retire(remoteID, window: host)
        WindowRegistry.shared.register(remoteID, window: host)
        WindowRegistry.shared.markPresented(fixture.frontID, window: fixture.hostFront)
        WindowRegistry.shared.markPresented(fixture.backID, window: fixture.hostBack)
        WindowRegistry.shared.markPresented(remoteID, window: host)

        fixture.delegate.queueOpenDirectories([folder.path], cold: true)
        XCTAssertEqual(fixture.library.frontmostWindowID, remoteID)
        fixture.library.frontmostWindowID = fixture.frontID
        fixture.delegate.drainPendingOpenDirectories()

        XCTAssertEqual(fixture.front.workspaces[0].sessions.count, frontCount)
        XCTAssertNotNil(remoteStore.remoteActions)
    }

    func testLinkReplacingAColdLinkWaitsForEveryWindowThenOnlyItSelects() throws {
        let fixture = try LinkFixture()
        defer { fixture.tearDown() }
        let workspace = fixture.back.workspaces[0].id
        let older = try XCTUnwrap(fixture.back.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory(), select: false))
        let newer = try XCTUnwrap(fixture.back.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory(), select: false))
        WindowRegistry.shared.markPresented(fixture.backID, window: fixture.hostBack)

        fixture.delegate.queueSessionLink(older.id, cold: true)
        fixture.delegate.queueSessionLink(newer.id, cold: false)
        XCTAssertNotEqual(fixture.back.selectedSessionID, newer.id)
        XCTAssertNotEqual(fixture.back.selectedSessionID, older.id)
        WindowRegistry.shared.markPresented(fixture.frontID, window: fixture.hostFront)

        let deadline = Date(timeIntervalSinceNow: 10)
        while fixture.back.selectedSessionID != newer.id, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        XCTAssertEqual(fixture.back.selectedSessionID, newer.id)
        XCTAssertEqual(fixture.library.frontmostWindowID, fixture.backID)
    }

    func testSessionLinkOpenedBeforeItsWindowRegistersSelectsOnceItDoes() throws {
        let fixture = try LinkFixture()
        defer { fixture.tearDown() }
        let linked = try XCTUnwrap(fixture.back.addSession(toWorkspace: fixture.back.workspaces[0].id,
                                                           cwd: NSTemporaryDirectory(), select: false))
        WindowRegistry.shared.unregister(fixture.backID)

        fixture.delegate.application(NSApp, open: [try XCTUnwrap(URL(string: "agterm://session/\(linked.id.uuidString)"))])
        XCTAssertNotEqual(fixture.back.selectedSessionID, linked.id)
        WindowRegistry.shared.register(fixture.backID, window: fixture.hostBack)

        let deadline = Date(timeIntervalSinceNow: 10)
        while fixture.back.selectedSessionID != linked.id, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        XCTAssertEqual(fixture.back.selectedSessionID, linked.id)
        XCTAssertEqual(fixture.library.frontmostWindowID, fixture.backID)
    }

    func testAnOlderLinksRetryNeitherSelectsNorConsumesANewerPendingLink() throws {
        let fixture = try LinkFixture()
        defer { fixture.tearDown() }
        let older = try XCTUnwrap(fixture.back.addSession(toWorkspace: fixture.back.workspaces[0].id,
                                                          cwd: NSTemporaryDirectory(), select: false))
        let newer = try XCTUnwrap(fixture.back.addSession(toWorkspace: fixture.back.workspaces[0].id,
                                                          cwd: NSTemporaryDirectory(), select: false))
        WindowRegistry.shared.unregister(fixture.backID)
        fixture.delegate.application(NSApp, open: [try XCTUnwrap(URL(string: "agterm://session/\(older.id.uuidString)"))])
        fixture.delegate.application(NSApp, open: [try XCTUnwrap(URL(string: "agterm://session/\(newer.id.uuidString)"))])
        WindowRegistry.shared.register(fixture.backID, window: fixture.hostBack)

        fixture.delegate.drainPendingSessionLink(request: 1)
        XCTAssertNotEqual(fixture.back.selectedSessionID, newer.id)
        XCTAssertNotEqual(fixture.back.selectedSessionID, older.id)

        let deadline = Date(timeIntervalSinceNow: 10)
        while fixture.back.selectedSessionID != newer.id, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        XCTAssertEqual(fixture.back.selectedSessionID, newer.id)
    }
}

@MainActor
final class LiveDaemons {
    let socketDirectory: String
    private let state: URL
    let zmx = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("agterm/Resources/zmx/zmx")
    private var names: [String] = []
    private var suspended: [pid_t] = []

    init(stateDirectory: URL) {
        state = stateDirectory
        socketDirectory = ZmxSupport.socketDirectory(forStateDirectory: stateDirectory.path)
    }

    func start(paneID: UUID, command: [String]) throws {
        try start(name: ZmxSupport.daemonName(for: paneID), command: command)
    }

    func start(name: String, command: [String]) throws {
        names.append(name)
        _ = try run(["attach", "--detached", name] + command, readsOutput: false)
    }

    func waitForCommands(of sessions: [Session], lookup: ZmxDaemonForeground) throws {
        let deadline = Date().addingTimeInterval(10)
        for session in sessions {
            let view = try XCTUnwrap(session.surface as? GhosttySurfaceView)
            while ForegroundProcess.command(for: view, shellBasename: "zsh", zmxForeground: lookup) == nil {
                guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
    }

    func leaderPID(paneID: UUID) throws -> pid_t {
        let name = ZmxSupport.daemonName(for: paneID)
        return try XCTUnwrap(ZmxListParser.parse(run(["list"])).first { $0.name == name }?.leaderPID)
    }

    func suspend(paneID: UUID) throws {
        try suspend(leader: leaderPID(paneID: paneID))
    }

    func suspend(leader: pid_t) throws {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, leader]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == leader
        else { throw POSIXError(.ESRCH) }
        let daemon = info.kp_eproc.e_ppid
        guard daemon > 1, kill(daemon, SIGSTOP) == 0 else { throw POSIXError(.ESRCH) }
        suspended.append(daemon)
    }

    func stop() {
        for pid in suspended { kill(pid, SIGCONT) }
        if !names.isEmpty { _ = try? run(["kill"] + names + ["--force"], readsOutput: false) }
        try? FileManager.default.removeItem(atPath: socketDirectory)
    }

    private func run(_ arguments: [String], readsOutput: Bool = true) throws -> String {
        let process = Process()
        process.executableURL = zmx
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_DIR"] = socketDirectory
        environment["HOME"] = state.path
        environment["SHELL"] = "/bin/zsh"
        environment.removeValue(forKey: "ZMX_SESSION")
        environment.removeValue(forKey: "ZMX_SESSION_PREFIX")
        environment.removeValue(forKey: "ZDOTDIR")
        process.environment = environment
        process.currentDirectoryURL = state
        let output = Pipe()
        process.standardOutput = readsOutput ? output : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw POSIXError(.ETIMEDOUT)
        }
        return readsOutput ? String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) : ""
    }
}

@MainActor
private struct LinkFixture {
    let state: URL
    let library: WindowLibrary
    let delegate = AppDelegate()
    let frontID: UUID
    let backID: UUID
    let front: AppStore
    let back: AppStore
    let hostFront: NSWindow
    let hostBack: NSWindow

    init() throws {
        state = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-open-url-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: state)
        frontID = try XCTUnwrap(library.activeWindowID)
        backID = library.newWindow(name: "back").id
        library.frontmostWindowID = frontID
        front = try XCTUnwrap(library.store(for: frontID))
        back = try XCTUnwrap(library.store(for: backID))
        hostFront = Self.register(frontID)
        hostBack = Self.register(backID)
        delegate.library = library
        delegate.actions = AppActions(library: library)
    }

    private static func register(_ id: UUID) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(id, window: window)
        return window
    }

    func tearDown() {
        [frontID, backID].forEach { WindowRegistry.shared.unregister($0) }
        [hostFront, hostBack].forEach { $0.orderOut(nil) }
        try? FileManager.default.removeItem(at: state)
    }
}

private final class NoCatalogEffects: RemoteCatalogEffects {
    func attachCommand(host: String, pane: CatalogPane, claim _: Bool) -> String { "attach \(host) \(pane.daemon)" }
    func catalogRowAdded(_: Session) {}
    func catalogRowRemoved(_: UUID) {}
    func catalogRowEnded(_: UUID) {}
    func catalogPaneNeedsAttach(_: UUID, session _: UUID) {}
    func catalogBound(_: UUID) -> Bool { true }
    func catalogStateChanged(_: RemoteCatalogMirror.State) {}
}
