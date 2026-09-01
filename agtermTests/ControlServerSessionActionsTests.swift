import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `ControlServer`'s session actions, which need the real app target for window
/// resolution and the store registry.
@MainActor
final class ControlServerSessionActionsTests: XCTestCase {
    private final class RigidSurface: TerminalSurface {
        var isRealized = true
        var paneToken = "rigid"
        func teardown() {}
        func promoteToPrimaryPane() {}
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-session-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private func overlayOptions(follow: Bool, pane: OverlayPane? = nil) -> ControlSessionOverlayOpenOptions {
        ControlSessionOverlayOpenOptions(command: "true", cwd: nil, wait: false, sizePercent: nil,
                                         backgroundColor: nil, follow: follow, pane: pane)
    }

    private func addSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        return (store, try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory())))
    }

    private func parkSwappablePanes(on session: Session) -> (GhosttySurfaceView, GhosttySurfaceView) {
        let primary = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                         env: ["AGTERM_PANE_ID": "primary"])
        let split = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                       env: ["AGTERM_PANE_ID": "split"])
        split.setPaneRole(.split)
        session.surface = primary
        session.splitSurface = split
        session.hasSplit = true
        return (primary, split)
    }

    func testSwapReportsEachImmediatePrimitiveRefusal() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let missingID = UUID()
        let missing = await actions.swapSessionPanes(missingID, in: store)

        let (_, noSplitSession) = try addSession()
        let noSplit = await actions.swapSessionPanes(noSplitSession.id, in: store)

        let (_, rigidSession) = try addSession()
        rigidSession.surface = RigidSurface()
        rigidSession.splitSurface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        rigidSession.hasSplit = true
        let rigid = await actions.swapSessionPanes(rigidSession.id, in: store)

        XCTAssertEqual(missing.error, "session closed during swap")
        XCTAssertEqual(noSplit.error, "session has no split pane")
        XCTAssertEqual(rigid.error, "session panes do not support swapping")
        XCTAssertEqual(Set([missing.error, noSplit.error, rigid.error]).count, 3)
    }

    func testSwapWaitsForSlotsThenReportsNotRealized() async throws {
        let (_, session) = try addSession()
        session.hasSplit = true
        let started = Date()

        let response = await server.swapSessionPanes(session.id.uuidString, window: nil)

        XCTAssertEqual(response.error, "session not realized")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.3)
    }

    func testSwapImmediatelyAfterSplitOnWaitsForBothSlots() async throws {
        let (_, session) = try addSession()
        XCTAssertTrue(server.splitSession(session.id.uuidString, window: nil, mode: "on").ok)
        let primary = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        let split = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        split.setPaneRole(.split)
        let realize = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            session.surface = primary
            session.splitSurface = split
        }

        let response = await server.swapSessionPanes(session.id.uuidString, window: nil)
        await realize.value

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertTrue(session.surface === split)
        XCTAssertTrue(session.splitSurface === primary)
    }

    func testSwapClearsAnInvalidZoomBeforeAcknowledging() async throws {
        let (store, session) = try addSession()
        _ = parkSwappablePanes(on: session)
        session.setPaneOverlay(PaneOverlay(command: "true"), pane: .left)
        let windowID = try XCTUnwrap(library.windowID(forSession: session.id))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        zoom.set(.on, target: .session(session.id, .overlayLeft))
        XCTAssertNotNil(zoom.target)

        let response = await server.swapSessionPanes(session.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNil(zoom.target)
        XCTAssertNil(session.leftOverlay)
        XCTAssertNotNil(session.rightOverlay)
    }

    func testSwapKeepsAValidZoomTarget() async throws {
        let (_, session) = try addSession()
        _ = parkSwappablePanes(on: session)
        let windowID = try XCTUnwrap(library.windowID(forSession: session.id))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        let target = TerminalZoomTarget.session(session.id, .primary)
        zoom.set(.on, target: target)

        let response = await server.swapSessionPanes(session.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(zoom.target, target)
    }

    func testSwapDoesNotClearAnotherSessionsInvalidZoom() async throws {
        let (_, swapped) = try addSession()
        _ = parkSwappablePanes(on: swapped)
        let (_, other) = try addSession()
        let windowID = try XCTUnwrap(library.windowID(forSession: swapped.id))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        let foreignTarget = TerminalZoomTarget.session(other.id, .split)
        zoom.set(.on, target: foreignTarget)
        XCTAssertFalse(TerminalZoomController.isTargetValid(foreignTarget, in: try XCTUnwrap(library.activeStore)))

        let response = await server.swapSessionPanes(swapped.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(zoom.target, foreignTarget)
    }

    func testSetSessionContextReachesTheStoreAndClears() throws {
        let (store, session) = try addSession()

        let set = server.setSessionContext(session.id.uuidString, window: nil, context: "PR #517")
        XCTAssertTrue(set.ok, set.error ?? "")
        XCTAssertEqual(set.result?.id, session.id.uuidString)
        XCTAssertEqual(store.session(withID: session.id)?.context, "PR #517")

        let cleared = server.setSessionContext(session.id.uuidString, window: nil, context: nil)
        XCTAssertTrue(cleared.ok, cleared.error ?? "")
        XCTAssertNil(store.session(withID: session.id)?.context)
    }

    func testSetSessionContextReportsAnUnknownTarget() throws {
        _ = try addSession()

        let response = server.setSessionContext(UUID().uuidString, window: nil, context: "PR #517")

        XCTAssertFalse(response.ok)
    }

    func testFollowSelectsTheTargetWhenNothingIsSelected() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(nil)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                 options: overlayOptions(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    // --follow is documented as a no-op when its target is already active, and it stays one only because
    // a same-value selection leaves the fresh-workspace target alone.
    func testFollowOnTheAlreadyActiveSessionKeepsTheFreshWorkspaceCurrent() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")

        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                 options: overlayOptions(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.currentWorkspaceID, fresh.id, "an already-active follow must not retarget")
    }

    func testFollowOnAnotherSessionSelectsItAndDropsTheFreshWorkspace() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let first = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let second = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(second.id)
        store.addWorkspace(name: "fresh")

        let response = server.openSessionOverlay(first.id.uuidString, window: nil,
                                                 options: overlayOptions(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, first.id)
        XCTAssertEqual(store.currentWorkspaceID, owner)
    }

    // pins #349. A store-only session never gets a view, so its surface stays nil and the poll always runs
    // to exhaustion — which is what makes this deterministic where the e2e version is not. The pre-#349 code
    // returned "session not realized; use select" immediately; both the wire string and the elapsed time
    // discriminate, so restoring the `guard select` fails on the string and dropping the sleep fails on time.
    // The target is created unselected and a SECOND session holds the selection, so making the select
    // unconditional fails the last assertion; the companion below pins the other side of that branch.
    func testTypeWithoutSelectPollsInsteadOfDemandingSelect() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory(), select: false))
        let other = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(other.id)

        let started = Date()
        let response = await server.injectText("ls\n", into: target.id, store: store, select: false, pane: nil)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(response.ok, "a surface that never comes up must not report a false ok")
        XCTAssertEqual(response.error, "session not realized", "the no-select path no longer tells callers to select")
        XCTAssertGreaterThan(elapsed, 0.3, "it should ride out the full 12 x 30ms realize poll, not fast-fail")
        XCTAssertEqual(store.selectedSessionID, other.id, "typing without select must leave the selection where it was")
    }

    // a pane parked in the slot with no libghostty surface is the state a display-asleep create leaves
    // behind (#416). It used to answer `failed to read surface buffer`, naming a cause that never happened,
    // while every sibling command called the same state `session not realized`.
    func testTextOnAnUnrealizedPaneReportsNotRealizedRatherThanAReadFailure() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let parked = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        target.surface = parked
        XCTAssertFalse(parked.isRealized, "a detached view never runs createSurface, which is the point here")

        let response = server.readSessionText(target.id.uuidString, window: nil,
                                              options: ControlSessionTextOptions(pane: nil, all: false, lines: nil))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "session not realized",
                       "an empty slot and a parked-but-unrealized view are one state to a caller")
    }

    // MARK: - launch queue preemption

    /// A pane parked in the launch queue: registered with an armed pacer behind a head that never asks, and
    /// already denied once. Only an expedite can grant it, so a granted key proves the command promoted it.
    /// The host never realizes a surface, so every command still answers `session not realized`; what is
    /// under test is whether the pane's turn was spent before that answer.
    @MainActor private struct QueuedPane {
        let view: GhosttySurfaceView
        let registry: SpawnRegistry
        let key: UUID
        var granted: Bool { registry.view(for: key) == nil }
    }

    private func queuePane(in session: Session, split: Bool = false) -> QueuedPane {
        let registry = SpawnRegistry(pacer: SpawnPacer())
        let key = UUID()
        registry.pacer.arm(order: [UUID(), key], burst: [])
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        registry.enqueue(view, key: key, provider: LaunchSeedProvider(shouldPace: true) { _ in
            LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        })
        XCTAssertFalse(view.requestSpawnPermit(), "the fixture must start queued")
        if split { session.splitSurface = view } else { session.surface = view }
        return QueuedPane(view: view, registry: registry, key: key)
    }

    func testTypeExpeditesAQueuedPaneBeforeItsPoll() async throws {
        let (store, target) = try addSession()
        let queued = queuePane(in: target)

        let response = await server.injectText("ls\n", into: target.id, store: store, select: true, pane: nil)

        XCTAssertEqual(response.error, "session not realized")
        XCTAssertTrue(queued.granted, "the pane must be granted before the poll runs, not after it")
    }

    func testTypeOnAQueuedShownSplitExpeditesItAndAnAbsentSplitFailsFast() async throws {
        let (store, target) = try addSession()
        store.setSplitVisibility(target.id, shown: true)
        let queued = queuePane(in: target, split: true)
        let (_, bare) = try addSession()

        let shown = await server.injectText("ls\n", into: target.id, store: store, select: false, pane: "right")
        let started = Date()
        let absent = await server.injectText("ls\n", into: bare.id, store: store, select: false, pane: "right")

        XCTAssertEqual(shown.error, "session not realized")
        XCTAssertTrue(queued.granted)
        XCTAssertEqual(absent.error, "session has no split pane")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "an absent split has nothing to wait for")
    }

    func testSearchOpenExpeditesAQueuedPane() async throws {
        let (store, target) = try addSession()
        let queued = queuePane(in: target)

        let response = await server.searchSession(target.id, store: store, text: nil, to: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertTrue(queued.granted)
    }

    func testSynchronousMutatorsExpediteAQueuedPane() throws {
        let cases: [(name: String, split: Bool, run: (Session) -> ControlResponse)] = [
            ("session.paste", false, { self.server.pasteSession($0.id.uuidString, window: nil) }),
            ("session.selectall", false, { self.server.selectAllSession($0.id.uuidString, window: nil) }),
            ("font.inc left", false, { self.server.font($0.id.uuidString, window: nil, pane: nil, action: "increase_font_size:1") }),
            ("font.inc right", true, { self.server.font($0.id.uuidString, window: nil, pane: "right", action: "increase_font_size:1") }),
        ]
        for testCase in cases {
            let (store, target) = try addSession()
            if testCase.split { store.setSplitVisibility(target.id, shown: true) }
            let queued = queuePane(in: target, split: testCase.split)

            let response = testCase.run(target)

            XCTAssertEqual(response.error, "session not realized", testCase.name)
            XCTAssertTrue(queued.granted, "\(testCase.name) must grant the pane before acting on it")
        }
    }

    func testReadsLeaveAQueuedPaneQueued() throws {
        let (_, target) = try addSession()
        let queued = queuePane(in: target)
        let id = target.id.uuidString

        let text = server.readSessionText(id, window: nil,
                                          options: ControlSessionTextOptions(pane: nil, all: false, lines: nil))
        let copy = server.copySelection(id, window: nil)
        let cursor = server.readSurfaceCursor("surface:\(id):left", window: nil)

        XCTAssertEqual(text.error, "session not realized")
        XCTAssertEqual(copy.error, "session not realized")
        XCTAssertEqual(cursor.error, "surface not realized")
        XCTAssertFalse(queued.granted, "a read must not spend the pane's turn")
        XCTAssertTrue(queued.view.awaitingSpawnPermit)
    }

    func testTextPaneIDResolvesTheLiveSlotAndOverridesPane() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        session.surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                             env: ["AGTERM_PANE_ID": "left-token"])
        session.splitSurface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                                  env: ["AGTERM_PANE_ID": "right-token"])
        session.hasSplit = true

        XCTAssertEqual(ControlServer.resolvedSessionTextPane(in: session, pane: "left", paneID: "right-token"),
                       "right")
        XCTAssertEqual(ControlServer.resolvedSessionTextPane(in: session, pane: "scratch", paneID: "unknown"),
                       "scratch", "an unknown token falls back to the explicit role")
    }

    func testTextPaneIDFollowsItsSurfaceAfterSwap() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        session.surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                             env: ["AGTERM_PANE_ID": "moving-token"])
        session.splitSurface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(),
                                                  env: ["AGTERM_PANE_ID": "other-token"])
        session.hasSplit = true

        XCTAssertNil(store.swapPanes(session.id))

        XCTAssertEqual(ControlServer.resolvedSessionTextPane(in: session, pane: "left", paneID: "moving-token"),
                       "right")
    }

    // the same parked pane, one command over: `surfaceBindingAction`'s cast proves only that the SLOT is
    // filled, so both used to discard `performBindingAction`'s false and answer ok with nothing pasted or
    // selected, while their neighbours called that state `session not realized`.
    func testPasteAndSelectAllOnAnUnrealizedPaneReportNotRealized() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let parked = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        target.surface = parked
        XCTAssertFalse(parked.isRealized, "a detached view never runs createSurface, which is the point here")

        let paste = server.pasteSession(target.id.uuidString, window: nil)
        XCTAssertFalse(paste.ok, "session.paste pasted nothing and must not report a false ok")
        XCTAssertEqual(paste.error, "session not realized")

        let selectAll = server.selectAllSession(target.id.uuidString, window: nil)
        XCTAssertFalse(selectAll.ok, "session.selectall selected nothing and must not report a false ok")
        XCTAssertEqual(selectAll.error, "session not realized")
    }

    // `session.copy` is `session.selectall`'s documented read-back, so the pair has to name this state the
    // same way. `readSelection` returns nil for an unrealized pane exactly as it does for an empty buffer,
    // which the arm used to report as `no selection`.
    func testCopyOnAnUnrealizedPaneReportsNotRealizedRatherThanNoSelection() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let parked = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        target.surface = parked
        XCTAssertFalse(parked.isRealized, "a detached view never runs createSurface, which is the point here")

        let response = server.copySelection(target.id.uuidString, window: nil)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "session not realized",
                       "`no selection` blames an empty buffer for a pane that has no terminal")
    }

    // the true side of that branch: deleting the body of `if select` leaves every other test green while
    // `--select` silently stops selecting, so this asserts the move itself rather than the typed text.
    func testTypeWithSelectStillSelectsWhenTheSurfaceIsNotReady() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory(), select: false))
        let other = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(other.id)

        let response = await server.injectText("ls\n", into: target.id, store: store, select: true, pane: nil)

        XCTAssertFalse(response.ok, "a store-only session never realizes, so the poll still runs out")
        XCTAssertEqual(store.selectedSessionID, target.id, "--select must select the target when its surface is not up")
    }

    // the two pane rejections come back from the store as an enum this arm maps to wire strings; without
    // asserting both here, swapping the arms of `paneOverlayFailure` leaves every other test green.
    func testPaneOverlayOpenReportsEachRejectionByItsOwnError() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))

        let opened = server.openSessionOverlay(session.id.uuidString, window: nil,
                                               options: overlayOptions(follow: false, pane: .left))
        XCTAssertTrue(opened.ok, opened.error ?? "")

        let again = server.openSessionOverlay(session.id.uuidString, window: nil,
                                              options: overlayOptions(follow: false, pane: .left))
        XCTAssertFalse(again.ok)
        XCTAssertEqual(again.error, "pane overlay already open")

        // the right pane is not laid out on an unsplit session, so its overlay would never realize a surface.
        let unrendered = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                   options: overlayOptions(follow: false, pane: .right))
        XCTAssertFalse(unrendered.ok)
        XCTAssertEqual(unrendered.error, "pane not visible")
    }

    // the pane arm of session.overlay.result: both failure branches, which the hosted e2e only covers on the
    // success path, and the session-wide slot staying untouched by either.
    func testPaneOverlayResultReportsRunningThenMissingThenTheCode() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))

        let never = server.sessionOverlayResult(session.id.uuidString, window: nil, pane: .left)
        XCTAssertFalse(never.ok)
        XCTAssertEqual(never.error, "no overlay result", "a pane that never ran one has no result")

        XCTAssertNil(store.openPaneOverlay(session.id, pane: .left, command: "true"))
        let running = server.sessionOverlayResult(session.id.uuidString, window: nil, pane: .left)
        XCTAssertFalse(running.ok)
        XCTAssertEqual(running.error, "overlay still running")

        store.recordPaneOverlayExit(session.id, pane: .left, code: 3)
        XCTAssertTrue(store.closePaneOverlay(session.id, pane: .left))
        let done = server.sessionOverlayResult(session.id.uuidString, window: nil, pane: .left)
        XCTAssertTrue(done.ok, done.error ?? "")
        XCTAssertEqual(done.result?.exitCode, 3)

        let sessionWide = server.sessionOverlayResult(session.id.uuidString, window: nil, pane: nil)
        XCTAssertFalse(sessionWide.ok)
        XCTAssertEqual(sessionWide.error, "no overlay result", "a pane overlay must not fill the session slot")
    }

    // MARK: - session.overlay.copy / .text

    // #434: an empty slot and a filled-but-unrealized one are different answers.
    func testOverlayReadsSeparateAnEmptySlotFromAnUnrealizedSurface() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let sessionWide = ControlSessionOverlayTextOptions(pane: nil, all: false, lines: nil)
        let leftPane = ControlSessionOverlayTextOptions(pane: .left, all: false, lines: nil)

        XCTAssertEqual(server.copySessionOverlaySelection(session.id.uuidString, window: nil, pane: nil).error,
                       "no overlay")
        XCTAssertEqual(server.readSessionOverlayText(session.id.uuidString, window: nil, options: sessionWide).error,
                       "no overlay")
        XCTAssertEqual(server.copySessionOverlaySelection(session.id.uuidString, window: nil, pane: .left).error,
                       "no overlay")

        XCTAssertNil(store.openPaneOverlay(session.id, pane: .left, command: "true"))
        XCTAssertEqual(server.copySessionOverlaySelection(session.id.uuidString, window: nil, pane: .left).error,
                       "overlay not realized", "the slot is filled; it is the cover that has no terminal yet")
        XCTAssertEqual(server.readSessionOverlayText(session.id.uuidString, window: nil, options: leftPane).error,
                       "overlay not realized")

        // the other half of that branch: a view parked in the slot whose libghostty surface never came up
        session.setPaneOverlaySurface(GhosttySurfaceView(workingDirectory: NSTemporaryDirectory()), pane: .left)
        XCTAssertEqual(server.copySessionOverlaySelection(session.id.uuidString, window: nil, pane: .left).error,
                       "overlay not realized")
        XCTAssertEqual(server.copySessionOverlaySelection(session.id.uuidString, window: nil, pane: .right).error,
                       "no overlay", "the sibling slot is independent, not borrowed from the open one")
    }

    // MARK: - session.hud.*

    private func makeHudSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: ControlServer.bodyFile(for: session.id)) }
        return (store, session)
    }

    private func bodyText(_ session: Session) -> String? {
        try? String(contentsOfFile: ControlServer.bodyFile(for: session.id), encoding: .utf8)
    }

    /// The pid the helper watches. These tests run inside the app process, so asserting against it is what
    /// pins that the header names the WRITER — a pid from anywhere else would never die with the app.
    private static var ownerPid: Int32 { ProcessInfo.processInfo.processIdentifier }

    /// The body these tests expect: nothing is laid out here, so the pane measures zero and the header's
    /// grid falls back to the content box. A measured pane's grid is `HudLayout`'s to get right.
    private func expectedBody(_ spec: HudSpec) -> String {
        HudLayout.renderedBody(for: spec, grid: HudLayout.box(for: spec), ownerPid: Self.ownerPid)
    }

    func testHudOpenPointsTheSlotAtTheBundledHelperAndWritesTheBody() throws {
        let (_, session) = try makeHudSession()
        let spec = HudSpec(message: "gathering options", detail: "scanning 4 repositories", spinner: .braille)

        let response = server.openHud(session.id.uuidString, window: nil, spec: spec)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(session.hudSpec, spec)
        XCTAssertEqual(session.hudFile, ControlServer.bodyFile(for: session.id))
        XCTAssertEqual(bodyText(session), expectedBody(spec))
        // the command is eval'd by the overlay wrapper, so the bundled path must arrive shell-escaped
        let command = try XCTUnwrap(session.overlayCommand)
        XCTAssertEqual(command, ControlServer.helperCommand())
        let helper = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("hud/hud.sh").path)
        XCTAssertEqual(command, "/bin/sh " + ShellEscape.path(helper), "the eval'd path must arrive escaped")
        XCTAssertTrue(session.hudActive)
        XCTAssertFalse(session.programOverlayActive, "a HUD must never read back as a caller's program")
    }

    // the panel is sized from the measured pane; a session with nothing laid out measures zero, which
    // `HudLayout` resolves to the clamp's maximum, and an explicit --size-percent skips measuring entirely.
    func testHudSizeUsesTheMeasuredPaneUnlessTheCallerOverridesIt() throws {
        let (_, session) = try makeHudSession()

        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "working")).ok)
        XCTAssertEqual(session.overlaySizePercent, HudLayout.maxSizePercent)

        let sized = HudSpec(message: "working", sizePercent: 25)
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: sized).ok)
        XCTAssertEqual(session.overlaySizePercent, 25)
    }

    // a hud must never cover the session it is about, which is why `overlay resize --full` is refused; a
    // caller's 100 is the same state by another door, so it takes the same bound.
    func testAnOversizedCallerRequestIsBoundedRatherThanCoveringThePane() throws {
        let (store, session) = try makeHudSession()

        let full = HudSpec(message: "working", sizePercent: 100)
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: full).ok)
        XCTAssertEqual(session.overlaySizePercent, HudLayout.maxSizePercent)

        XCTAssertTrue(server.updateHud(session.id.uuidString, window: nil, spec: full).ok)
        XCTAssertEqual(session.overlaySizePercent, HudLayout.maxSizePercent)

        XCTAssertTrue(store.resizeOverlay(session.id, sizePercent: 100))
        XCTAssertEqual(session.overlaySizePercent, HudLayout.maxSizePercent,
                       "session.overlay.resize must not grow a hud into a cover either")
    }

    // the cell the panel is sized from: a real monospaced face measures a plausible advance, and an
    // unresolvable family falls back to the system face rather than to the 1-point floor.
    func testCellSizeMeasuresTheConfiguredFontAndFallsBackWhenItCannot() {
        let menlo = ControlServer.cellSize(family: "Menlo", size: 13)
        XCTAssertGreaterThan(menlo.width, 1, "a real face must measure wider than the floor")
        XCTAssertLessThan(menlo.width, 13, "a monospaced advance is narrower than the point size")
        XCTAssertGreaterThan(menlo.height, menlo.width, "the line box is taller than one cell is wide")

        let missing = ControlServer.cellSize(family: "no such face at all", size: 13)
        XCTAssertEqual(missing.width, ControlServer.cellSize(family: nil, size: 13).width, accuracy: 0.001)
        XCTAssertGreaterThan(missing.width, 1)

        // the advance scales with the point size, so a wrong unit would show up here
        XCTAssertEqual(ControlServer.cellSize(family: "Menlo", size: 26).width, menlo.width * 2, accuracy: 0.01)
    }

    // an unwritable body means the panel would paint nothing or stale text, so neither open nor update may
    // leave the store claiming a message the helper cannot read.
    func testAFailedBodyWriteRollsTheStoreBack() throws {
        let (_, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "first")).ok)
        let live = try XCTUnwrap(session.hudSpec)
        let painted = bodyText(session)

        // an immutable body file is a write the app cannot complete: the atomic rename onto it fails, and it
        // outlives the removal a replacing open runs, which is what keeps the open arm below reachable
        let path = ControlServer.bodyFile(for: session.id)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        addTeardownBlock { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }

        let update = server.updateHud(session.id.uuidString, window: nil, spec: HudSpec(message: "unwritable"))
        XCTAssertFalse(update.ok)
        XCTAssertEqual(update.error, OverlayHudError.writeFailed)
        XCTAssertEqual(session.hudSpec, live, "a failed update must leave the live message in the tree")

        let size = try XCTUnwrap(session.overlaySizePercent)
        let resize = server.resizeSessionOverlay(session.id.uuidString, window: nil, sizePercent: 20)
        XCTAssertFalse(resize.ok)
        XCTAssertEqual(resize.error, OverlayHudError.writeFailed)
        XCTAssertEqual(session.overlaySizePercent, size,
                       "a panel whose header cannot be rewritten must not move away from it")

        let open = server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "also unwritable"))
        XCTAssertFalse(open.ok)
        XCTAssertEqual(open.error, OverlayHudError.writeFailed)
        XCTAssertFalse(session.hudActive, "a failed open must roll the slot back rather than leave it empty")
        XCTAssertFalse(session.overlayActive)
        XCTAssertEqual(bodyText(session), painted,
                       "the panel keeps painting the message it last read, so nothing may claim another one")
    }

    // the no-blink contract: an update rewrites the same file and resizes the same surface, so the slot
    // generation (which drives the panel's SwiftUI identity) must not move.
    func testHudUpdateRewritesTheBodyInPlaceWithoutRespawning() throws {
        let (_, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "first")).ok)
        let generation = session.overlaySlotGeneration
        let file = session.hudFile

        let update = HudSpec(message: "a considerably longer second message", sizePercent: 40)
        let response = server.updateHud(session.id.uuidString, window: nil, spec: update)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(session.overlaySlotGeneration, generation, "an update must not re-open the slot")
        XCTAssertEqual(session.hudFile, file)
        XCTAssertEqual(bodyText(session), expectedBody(update))
        XCTAssertEqual(session.overlaySizePercent, 40)
        // the grid rides in the body's header line, which is what lets a running helper re-centre. The
        // trailing `-` is the no-text-color sentinel, spelled out because this pins the wire format.
        XCTAssertEqual(bodyText(session)?.split(separator: "\n").first.map(String.init),
                       "\(HudLayout.box(for: update).columns) \(HudLayout.box(for: update).rows) 0 "
                           + "\(Self.ownerPid) \(HudSpinner.staticInterval) -")
    }

    // the text color rides that same header, so an update recolors the live panel without re-opening the
    // slot — the half of a HUD's color an update can change, unlike the surface-read background.
    func testHudUpdateRecolorsTheTextThroughTheHeaderInPlace() throws {
        let (_, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil,
                                     spec: HudSpec(message: "first", textColor: "#e0e0e0")).ok)
        let generation = session.overlaySlotGeneration

        let update = HudSpec(message: "second", textColor: "#7ec07e")
        XCTAssertTrue(server.updateHud(session.id.uuidString, window: nil, spec: update).ok)

        XCTAssertEqual(session.overlaySlotGeneration, generation, "a recolor must not re-open the slot")
        XCTAssertEqual(bodyText(session)?.split(separator: "\n").first.map(String.init)?
            .hasSuffix(" 38;2;126;192;126"), true)
        XCTAssertEqual(session.hudSpec?.textColor, "#7ec07e")
    }

    func testHudCloseClearsTheSlotAndRemovesTheBodyFile() throws {
        let (_, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "working")).ok)
        let file = try XCTUnwrap(session.hudFile)

        let response = server.closeHud(session.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNil(session.hudSpec)
        XCTAssertFalse(session.overlayActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "the body file must not outlive the hud")
    }

    func testHudUpdateAndCloseWithoutAHudReportNoHud() throws {
        let (store, session) = try makeHudSession()

        XCTAssertEqual(server.updateHud(session.id.uuidString, window: nil, spec: HudSpec(message: "x")).error,
                       "no hud")
        XCTAssertEqual(server.closeHud(session.id.uuidString, window: nil).error, "no hud")

        XCTAssertTrue(store.openOverlay(session.id, command: "true"))
        XCTAssertEqual(server.updateHud(session.id.uuidString, window: nil, spec: HudSpec(message: "x")).error,
                       "no hud", "a caller's program is not a hud's to rewrite")
        XCTAssertEqual(server.closeHud(session.id.uuidString, window: nil).error, "no hud")
        XCTAssertTrue(session.overlayActive, "a refused hud command must leave the program overlay alone")
    }

    func testHudOverALiveProgramOverlayIsRefusedAndWritesNothing() throws {
        let (store, session) = try makeHudSession()
        XCTAssertTrue(store.openOverlay(session.id, command: "true"))

        let response = server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "working"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "overlay already open")
        XCTAssertNil(bodyText(session), "a refused open must leave no temp file behind")
    }

    // a replacement tears the first helper's surface down, and that teardown deletes the body file at this
    // same per-session path — so the body must be written after the store call, never before.
    func testASecondHudReplacesTheFirstAndKeepsItsBody() throws {
        let (_, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "first")).ok)
        let generation = session.overlaySlotGeneration

        let second = HudSpec(message: "second")
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: second).ok)

        XCTAssertEqual(session.hudSpec, second)
        XCTAssertEqual(bodyText(session), expectedBody(second))
        XCTAssertGreaterThan(session.overlaySlotGeneration, generation, "a replacement must remount the panel")
    }

    // MARK: - session.overlay.* against a hud

    // the slot is shared, so `overlayActive` alone answers "overlay still running" for a panel that will
    // never report a status; the refusal has to name the hud.
    func testOverlayResultRefusesAHudByName() throws {
        let (store, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "working")).ok)

        let response = server.sessionOverlayResult(session.id.uuidString, window: nil, pane: nil)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no overlay result: the slot holds a hud")
        XCTAssertTrue(session.hudActive, "a refused result must leave the panel up")
        // the pane-scoped arm reads its own slots, so a session hud must not colour its answer
        XCTAssertEqual(server.sessionOverlayResult(session.id.uuidString, window: nil, pane: .left).error,
                       "no overlay result")
        XCTAssertTrue(store.closeHud(session.id))
        XCTAssertEqual(server.sessionOverlayResult(session.id.uuidString, window: nil, pane: nil).error,
                       "no overlay result", "a closed hud records no exit code either")
    }

    // `overlayActive` is true for a hud too, so the refusal has to name it.
    func testOverlayReadsRefuseAHudByName() throws {
        let (store, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "working")).ok)
        let options = ControlSessionOverlayTextOptions(pane: nil, all: false, lines: nil)

        XCTAssertEqual(server.copySessionOverlaySelection(session.id.uuidString, window: nil, pane: nil).error,
                       "no overlay to read: the slot holds a hud")
        XCTAssertEqual(server.readSessionOverlayText(session.id.uuidString, window: nil, options: options).error,
                       "no overlay to read: the slot holds a hud")
        XCTAssertTrue(session.hudActive, "a refused read must leave the panel up")
        XCTAssertEqual(server.copySessionOverlaySelection(session.id.uuidString, window: nil, pane: .left).error,
                       "no overlay", "the pane-scoped arm reads its own slot, uncoloured by a session hud")
        XCTAssertTrue(store.closeHud(session.id))
        XCTAssertEqual(server.copySessionOverlaySelection(session.id.uuidString, window: nil, pane: nil).error,
                       "no overlay")
    }

    func testOverlayCloseClosesAHudAndRemovesItsBody() throws {
        let (_, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "working")).ok)
        let file = try XCTUnwrap(session.hudFile)

        let response = server.closeSessionOverlay(session.id.uuidString, window: nil, pane: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNil(session.hudSpec)
        XCTAssertFalse(session.overlayActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "the body file must not outlive the hud")
        XCTAssertEqual(server.closeSessionOverlay(session.id.uuidString, window: nil, pane: nil).error, "no overlay")
    }

    // a hud resizes like any floating panel but never to full: it must not cover the session it is about.
    func testOverlayResizeMovesAHudPanelButRefusesFull() throws {
        let (_, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "working")).ok)
        let spec = try XCTUnwrap(session.hudSpec)

        let resized = server.resizeSessionOverlay(session.id.uuidString, window: nil, sizePercent: 35)
        XCTAssertTrue(resized.ok, resized.error ?? "")
        XCTAssertEqual(session.overlaySizePercent, 35)
        XCTAssertEqual(session.hudSpec, spec, "a resize must not disturb the message")
        XCTAssertTrue(session.hudActive)

        let full = server.resizeSessionOverlay(session.id.uuidString, window: nil, sizePercent: nil)
        XCTAssertFalse(full.ok)
        XCTAssertEqual(full.error, "a hud is always floating: pass --size-percent, not --full")
        XCTAssertEqual(session.overlaySizePercent, 35, "a refused resize must leave the panel where it was")
    }

    private func splitSession() throws -> (AppStore, Session) {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.toggleSplit(session.id)
        return (store, session)
    }

    func testSplitVisibilityDefaultsLeftRightAndAcceptsHorizontalAxis() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))

        XCTAssertTrue(server.splitSession(session.id.uuidString, window: nil, mode: "on", axis: nil).ok)
        XCTAssertTrue(session.isSplit)
        XCTAssertEqual(session.splitAxis, .leftRight)

        XCTAssertTrue(server.splitSession(session.id.uuidString, window: nil, mode: "on", axis: .topBottom).ok)
        XCTAssertTrue(session.isSplit, "on with another axis transposes rather than hides")
        XCTAssertEqual(session.splitAxis, .topBottom)
    }

    func testAxisSpecificControlToggleUsesTheSameHideTransposeMatrixAsTheGui() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))

        XCTAssertTrue(server.splitSession(session.id.uuidString, window: nil,
                                          mode: "toggle", axis: .topBottom).ok)
        XCTAssertTrue(session.isSplit)
        XCTAssertEqual(session.splitAxis, .topBottom)

        XCTAssertTrue(server.splitSession(session.id.uuidString, window: nil,
                                          mode: "toggle", axis: .leftRight).ok)
        XCTAssertTrue(session.isSplit)
        XCTAssertEqual(session.splitAxis, .leftRight)

        XCTAssertTrue(server.splitSession(session.id.uuidString, window: nil,
                                          mode: "toggle", axis: .leftRight).ok)
        XCTAssertFalse(session.isSplit)
        XCTAssertTrue(session.hasSplit)
        XCTAssertEqual(session.splitAxis, .leftRight)
    }

    func testSplitCloseTearsThePaneDown() throws {
        let (_, session) = try splitSession()
        session.splitRatio = 0.7

        let response = server.closeSessionSplit(session.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, session.id.uuidString)
        XCTAssertFalse(session.hasSplit)
        XCTAssertFalse(session.isSplit)
        XCTAssertFalse(session.splitFocused)
        XCTAssertNil(session.splitRatio)
    }

    func testSplitCloseReachesAHiddenPane() throws {
        let (store, session) = try splitSession()
        store.toggleSplit(session.id)
        XCTAssertTrue(session.hasSplit)

        let response = server.closeSessionSplit(session.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertFalse(session.hasSplit)
    }

    func testSplitCloseWithoutASplitAnswersOk() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))

        let response = server.closeSessionSplit(session.id.uuidString, window: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertFalse(session.hasSplit)
    }

    func testSplitCloseRejectsAnUnknownSession() throws {
        let response = server.closeSessionSplit(UUID().uuidString, window: nil)

        XCTAssertFalse(response.ok)
    }

    // the helper centers on the grid in the body's header, so a resize that changes the panel must rewrite
    // that file rather than wait for the next `hud.update` to re-center the message.
    func testOverlayResizeRewritesTheHudBody() throws {
        let (_, session) = try makeHudSession()
        XCTAssertTrue(server.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "working")).ok)
        let body = try XCTUnwrap(bodyText(session))
        try "stale".write(toFile: ControlServer.bodyFile(for: session.id), atomically: true, encoding: .utf8)

        let resized = server.resizeSessionOverlay(session.id.uuidString, window: nil, sizePercent: 35)

        XCTAssertTrue(resized.ok, resized.error ?? "")
        XCTAssertEqual(bodyText(session), body, "a resize must rewrite the header the helper reads")
    }
    func testRestoreReportsThePaneItActuallyWrote() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        session.hasSplit = true
        let splitSurface = SessionRestoreTestSurface(paneToken: "split-token")
        session.splitSurface = splitSurface

        let toSplit = server.setSessionRestore(
            session.id.uuidString, window: nil,
            update: ControlSessionRestoreUpdate(pin: .pin("echo split"), pane: nil,
                                                paneID: splitSurface.paneToken))
        XCTAssertTrue(toSplit.ok, toSplit.error ?? "")
        XCTAssertEqual(toSplit.result?.pane, "right")
        XCTAssertEqual(session.splitRestoreCommand, "echo split")

        let toMain = server.setSessionRestore(
            session.id.uuidString, window: nil,
            update: ControlSessionRestoreUpdate(pin: .pin("echo main"), pane: nil, paneID: nil))
        XCTAssertTrue(toMain.ok, toMain.error ?? "")
        XCTAssertEqual(toMain.result?.pane, "left")
        XCTAssertEqual(session.restoreCommand, "echo main")
    }

    func testRestoreSetAndNoneSavePolicyWithANoteOutsideRerun() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let liveServer = makeServer(launchMode: .live)

        let set = liveServer.setSessionRestore(
            session.id.uuidString, window: nil,
            update: ControlSessionRestoreUpdate(pin: .pin("echo later")))
        XCTAssertTrue(set.ok, set.error ?? "")
        XCTAssertEqual(set.result?.text, "saved for rerun mode; active restore mode is live")
        XCTAssertEqual(session.restoreCommand, "echo later")

        let none = liveServer.setSessionRestore(
            session.id.uuidString, window: nil,
            update: ControlSessionRestoreUpdate(pin: .pinNone))
        XCTAssertTrue(none.ok, none.error ?? "")
        XCTAssertEqual(none.result?.text, "saved for rerun mode; active restore mode is live")
        XCTAssertEqual(session.restoreCommand, "")

        let clear = liveServer.setSessionRestore(
            session.id.uuidString, window: nil,
            update: ControlSessionRestoreUpdate(pin: .unpin))
        XCTAssertTrue(clear.ok, clear.error ?? "")
        XCTAssertNil(clear.result?.text)
        XCTAssertNil(session.restoreCommand)
    }

    private func makeServer(launchMode: RestoreMode) -> ControlServer {
        ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            launchRestoreMode: launchMode,
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path
        )
    }

}

@MainActor
private final class SessionRestoreTestSurface: TerminalSurface {
    let paneToken: String
    let isRealized = true

    init(paneToken: String) {
        self.paneToken = paneToken
    }

    func teardown() {}
    func promoteToPrimaryPane() {}
}
