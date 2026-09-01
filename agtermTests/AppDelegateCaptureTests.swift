import AppKit
import Darwin
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppDelegateCaptureTests: XCTestCase {
    func testLivePrimaryAndHiddenSplitUseOneFreshSnapshot() throws {
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
        var timeout: TimeInterval?
        let resolver = ZmxForegroundResolver(
            leaderProvider: {
                timeout = $0
                return [ZmxSupport.daemonName(for: primaryID): 10, ZmxSupport.daemonName(for: splitID): 20]
            },
            leaderProbe: { .foreground($0 + 1) })

        let count = AppDelegate.captureForegroundCommands(
            sessions: [session], zmxResolver: resolver,
            commandReader: { view, _, snapshot in
                let name = try? XCTUnwrap(view.zmxSessionName)
                let pid = name.flatMap { snapshot?.foregroundPID(sessionName: $0) }
                return pid.map { ["worker", String($0)] }
            })

        XCTAssertEqual(count, 2)
        XCTAssertEqual(timeout, ZmxClient.captureInvocationTimeout)
        XCTAssertEqual(session.foregroundCommand, ["worker", "11"])
        XCTAssertEqual(session.splitForegroundCommand, ["worker", "21"])
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
            sessions: [shown], commandReader: { view, _, snapshot in
                XCTAssertNil(snapshot)
                return [view.isSplitPane ? "split" : "primary"]
            })

        XCTAssertEqual(shown.foregroundCommand, ["primary"])
        XCTAssertEqual(shown.splitForegroundCommand, ["split"])
    }

    func testFreshSnapshotFailureAndMidLoopExpiryNeverUseStaleLeaders() {
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let first = liveSession(paneID: firstID)
        let second = liveSession(paneID: secondID)
        var fail = false
        let resolver = ZmxForegroundResolver(
            leaderProvider: { _ in
                fail ? nil : [ZmxSupport.daemonName(for: firstID): 10,
                              ZmxSupport.daemonName(for: secondID): 20]
            },
            leaderProbe: { .foreground($0 + 1) })
        resolver.refreshIfNeeded(now: Date(timeIntervalSince1970: 100))
        fail = true
        first.foregroundCommand = ["stale"]

        _ = AppDelegate.captureForegroundCommands(
            sessions: [first], zmxResolver: resolver,
            commandReader: { _, _, _ in XCTFail("failed refresh must not read a command"); return nil })

        XCTAssertNil(first.foregroundCommand)
        fail = false
        first.foregroundCommand = nil
        second.foregroundCommand = ["stale"]
        var checks = 0
        _ = AppDelegate.captureForegroundCommands(
            sessions: [first, second], zmxResolver: resolver,
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
        let session = try XCTUnwrap(store.activeSession)
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
        let capture = AppDelegate.makeExitCapture(settingsModel: settings, zmxResolver: nil)
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
        var snapshotTimeout: TimeInterval?
        let resolver = ZmxForegroundResolver(
            leaderProvider: {
                snapshotTimeout = $0
                return [ZmxSupport.daemonName(for: session.paneIdentity): worker.processIdentifier]
            },
            leaderProbe: { _ in .foreground(worker.processIdentifier) })
        let capture = AppDelegate.makeExitCapture(settingsModel: settings, zmxResolver: resolver)
        XCTAssertTrue(settings.setRestoreMode(.rerun))
        let delegate = AppDelegate()
        delegate.library = library
        delegate.captureOnExit = capture

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let persisted = PersistenceStore(
            directory: state.appendingPathComponent("windows"), fileName: "\(windowID.uuidString).json").load()
        XCTAssertEqual(snapshotTimeout, ZmxClient.captureInvocationTimeout)
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
            captureOnExit: AppDelegate.makeExitCapture(settingsModel: settings, zmxResolver: nil))

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
            sessions: [session], zmxResolver: nil, preserveUnconsumedPending: true,
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
            sessions: [session], zmxResolver: nil, preserveUnconsumedPending: true,
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
            sessions: [session], zmxResolver: nil, preserveUnconsumedPending: true,
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
        let resolver = ZmxForegroundResolver(leaderProvider: { _ in [:] }, leaderProbe: { .foreground($0) })

        _ = AppDelegate.captureForegroundCommands(
            sessions: [live], zmxResolver: resolver, preserveUnconsumedPending: true)

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
            sessions: [session], zmxResolver: nil, commandReader: { _, _, _ in nil })

        XCTAssertNil(session.splitForegroundCommand)
        XCTAssertEqual(session.takePendingForegroundCommand(pane: .right), ["tail", "-f", "log"])
    }
}
