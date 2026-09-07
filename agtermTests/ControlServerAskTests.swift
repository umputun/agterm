import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerAskTests: XCTestCase {
    func testTargetedTerminalAskOpensOnBackgroundSessionWithoutSelectingIt() throws {
        let store = try XCTUnwrap(library.activeStore)
        let selectedID = try XCTUnwrap(store.selectedSessionID)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let background = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp"))
        configureSplit(background)
        store.selectSession(selectedID)
        for pane: OverlayPane? in [nil, .right] {
            let ask = makeTerminalAsk()
            XCTAssertEqual(open(ask, target: background.id.uuidString, placement: ControlAskPlacement(pane: pane)),
                           ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: pane?.rawValue)))
            XCTAssertEqual(store.selectedSessionID, selectedID)
            XCTAssertEqual(background.askPending, ask)
            XCTAssertEqual(server.askResult(ask.id, window: nil).result?.ask?.result, .pending)
            let tree = try XCTUnwrap(server.controlTree(window: nil).result?.tree)
            XCTAssertNil(tree.askPending)
            XCTAssertEqual(tree.workspaces.flatMap(\.sessions).first { $0.id == background.id.uuidString }?.ask,
                           ControlSessionAsk(id: ask.id, pane: pane?.rawValue))
            let input = SessionAskInput(session: background, store: store, actions: actions, windowID: windowID,
                                        askID: ask.id, frame: CGRect(x: 0, y: 0, width: 300, height: 200))
            XCTAssertFalse(input.visible)
            XCTAssertTrue(server.cancelAsk(ask.id, window: nil).ok)
        }
        background.isSplit = false
        background.splitFocused = false
        XCTAssertEqual(open(makeTerminalAsk(), target: background.id.uuidString, placement: ControlAskPlacement(pane: .right)),
                       ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible))
    }

    func testTerminalOpenUsesSelectedSessionAndPaneWithoutWindowController() throws {
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let windowID = try XCTUnwrap(library.activeWindowID)
        configureSplit(session)
        let ask = makeTerminalAsk()
        XCTAssertEqual(open(ask, placement: ControlAskPlacement(pane: .right)),
                       ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: "right")))
        XCTAssertEqual(session.askPending, ask)
        XCTAssertEqual(session.askPaneIdentity, session.splitPaneIdentity)
        XCTAssertEqual(AskRegistry.shared.owner(for: ask.id), .session(session.id, window: windowID))
        let tree = try XCTUnwrap(server.controlTree(window: nil).result?.tree)
        XCTAssertNil(tree.askPending)
        XCTAssertEqual(tree.workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }?.ask,
                       ControlSessionAsk(id: ask.id, pane: "right"))
        XCTAssertEqual(open(makeTerminalAsk()), ControlResponse(ok: false, error: "ask already pending"))
    }

    func testTerminalAskCoexistsWithGUIAskAndPickWithoutClosingPalette() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let controller = register(windowID)
        let gui = makeAsk()
        XCTAssertTrue(open(gui).ok)
        let terminal = makeTerminalAsk()
        XCTAssertTrue(open(terminal).ok)
        XCTAssertEqual(controller.pendingAsk?.id, gui.id)
        XCTAssertEqual(session.askPending?.id, terminal.id)
        XCTAssertTrue(server.cancelAsk(gui.id, window: nil).ok)
        XCTAssertTrue(controller.open(PendingPick(id: "picker", items: [ControlPickItem(id: "one", label: "One")])))
        XCTAssertTrue(server.cancelAsk(terminal.id, window: nil).ok)
        let palette = PaletteController()
        actions.palette = palette
        palette.open(.actions)
        XCTAssertTrue(open(makeTerminalAsk()).ok)
        XCTAssertEqual(palette.mode, .actions)
        XCTAssertNotNil(controller.pending)
        XCTAssertNotNil(session.askPending)
    }

    func testTerminalResultsKeepWindowScopeAcrossSelectionAndWindowClose() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let first = makeTerminalAsk()
        XCTAssertTrue(open(first).ok)
        let secondSession = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp"))
        store.selectSession(secondSession.id)
        let second = makeTerminalAsk()
        XCTAssertTrue(open(second).ok)
        let otherID = library.newWindow(name: "other").id
        for ask in [first, second] {
            XCTAssertEqual(server.askResult(ask.id, window: nil).result?.ask?.result, .pending)
            XCTAssertFalse(server.askResult(ask.id, window: otherID.uuidString).ok)
            XCTAssertFalse(server.cancelAsk(ask.id, window: otherID.uuidString).ok)
        }
        XCTAssertTrue(server.cancelAsk(first.id, window: windowID.uuidString).ok)
        library.closeWindow(windowID)
        for ask in [first, second] {
            XCTAssertEqual(server.askResult(ask.id, window: windowID.uuidString).result?.ask?.result, .cancelled)
            XCTAssertFalse(server.askResult(ask.id, window: otherID.uuidString).ok)
            XCTAssertFalse(server.cancelAsk(ask.id, window: otherID.uuidString).ok)
            XCTAssertTrue(server.cancelAsk(ask.id, window: windowID.uuidString).ok)
        }
        library.removeWindow(windowID)
        XCTAssertEqual(server.askResult(second.id, window: nil).result?.ask?.result, .cancelled)
    }

    func testTerminalOpenUnderZoomAndDashboardKeepsPendingSessionState() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        _ = register(windowID)
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        zoom.set(.on, target: .session(session.id, .primary))
        let first = makeTerminalAsk()
        XCTAssertTrue(open(first, target: session.id.uuidString).ok)
        XCTAssertEqual(server.askResult(first.id, window: nil).result?.ask?.result, .pending)
        XCTAssertTrue(server.cancelAsk(first.id, window: nil).ok)
        zoom.clear()
        let dashboard = DashboardController()
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        dashboard.open(members: [DashboardMember(session: session.id, surface: .primary)])
        let second = makeTerminalAsk()
        XCTAssertTrue(open(second, target: session.id.uuidString).ok)
        XCTAssertEqual(session.askPending?.id, second.id)
        XCTAssertTrue(dashboard.isOpen)
    }

    func testTerminationCancelsTerminalAskWithoutARegisteredWindowController() {
        let ask = makeTerminalAsk()
        XCTAssertTrue(open(ask).ok)
        library.isTerminating = true
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        XCTAssertEqual(server.askResult(ask.id, window: nil).result?.ask?.result, .cancelled)
        XCTAssertNil(library.activeStore?.activeSession?.askPending)
    }

    private func makeTerminalAsk() -> PendingAsk {
        PendingAsk(id: UUID().uuidString, title: "Continue?", buttons: [ControlAskButton(id: "yes", label: "Yes")])
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var server: ControlServer!
    private var registeredIDs: Set<UUID> = []
    private var windows: [UUID: NSWindow] = [:]

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-ask-\(UUID().uuidString)")
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            server = ControlServer(library: library, actions: actions, settingsModel: settings,
                                   identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                                   socketPath: stateDir.appendingPathComponent("control.sock").path)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            actions.cancelAllPendingModals()
            for id in registeredIDs {
                PickRegistry.shared.unregister(id)
                TerminalZoomRegistry.shared.unregister(id)
                DashboardControllerRegistry.shared.unregister(id)
            }
            for (id, window) in windows {
                WindowRegistry.shared.unregister(id)
                window.close()
            }
            registeredIDs.removeAll()
            windows.removeAll()
            server = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testOpenWithoutRegisteredControllerFails() {
        XCTAssertEqual(open(makeAsk()), ControlResponse(ok: false, error: "no ask surface"))
    }

    func testUnanchoredOpenReservesTheWindowAndClosesItsPalette() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = register(windowID)
        let palette = PaletteController()
        palette.open(.actions)
        actions.palette = palette
        let ask = makeAsk()

        XCTAssertEqual(open(ask), ControlResponse(ok: true, result: ControlResult(id: ask.id)))
        XCTAssertEqual(controller.pendingAsk, ask)
        XCTAssertNil(controller.pendingAsk?.anchor)
        XCTAssertNil(palette.mode)
        XCTAssertEqual(server.controlTree(window: nil).result?.tree?.askPending, ask.id)
        XCTAssertNil(server.controlTree(window: nil).result?.tree?.pickPending)
    }

    func testSessionTargetPinsOwnerAcrossFrontmostWindowChange() throws {
        let ownerID = try XCTUnwrap(library.activeWindowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let controller = register(ownerID)
        let frontmostID = library.newWindow(name: "frontmost").id
        let palette = PaletteController()
        palette.open(.actions)
        actions.palette = palette
        let ask = makeAsk()

        XCTAssertEqual(open(ask, target: session.id.uuidString), ControlResponse(ok: true, result: ControlResult(id: ask.id)))
        XCTAssertEqual(controller.pendingAsk?.anchor, AskAnchor(sessionID: session.id))
        XCTAssertEqual(library.activeWindowID, frontmostID)
        XCTAssertEqual(palette.mode, .actions)
        XCTAssertEqual(server.controlTree(window: ownerID.uuidString).result?.tree?.askPending, ask.id)
        XCTAssertNil(server.controlTree(window: frontmostID.uuidString).result?.tree?.askPending)
    }

    func testFollowRaisesOwnerAndClosesPalette() throws {
        let ownerID = try XCTUnwrap(library.activeWindowID)
        _ = register(ownerID)
        _ = library.newWindow(name: "frontmost")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows[ownerID] = window
        WindowRegistry.shared.register(ownerID, window: window)
        let palette = PaletteController()
        palette.open(.sessions)
        actions.palette = palette

        XCTAssertTrue(open(makeAsk(), window: ownerID.uuidString, follow: true).ok)
        XCTAssertEqual(library.frontmostWindowID, ownerID)
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(palette.mode)
    }

    func testHiddenSessionRejectsWithoutSelectingIt() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let hidden = try XCTUnwrap(store.activeSession)
        let workspace = try XCTUnwrap(store.workspaces.first)
        let selected = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let controller = register(windowID)

        XCTAssertEqual(open(makeAsk(), target: hidden.id.uuidString),
                       ControlResponse(ok: false, error: "session not visible"))
        XCTAssertEqual(store.selectedSessionID, selected.id)
        XCTAssertNil(controller.pendingAsk)
    }

    func testPaneTokenOverridesRoleAndCapturesStableIdentity() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = register(windowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        configureSplit(session)
        let ask = makeAsk()
        let response = open(ask, target: session.id.uuidString,
                            placement: ControlAskPlacement(pane: .left, paneID: "right-token"))

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: "right")))
        XCTAssertEqual(controller.pendingAsk?.anchor,
                       AskAnchor(sessionID: session.id, pane: .right, paneIdentity: session.splitPaneIdentity))
        XCTAssertEqual(controller.pendingAsk?.title, ask.title)
        XCTAssertEqual(controller.pendingAsk?.message, ask.message)
        XCTAssertEqual(controller.pendingAsk?.buttons, ask.buttons)
        XCTAssertEqual(controller.pendingAsk?.defaultID, ask.defaultID)
        XCTAssertEqual(controller.pendingAsk?.style, .gui)
        XCTAssertEqual(controller.pendingAsk?.align, .left)
        XCTAssertEqual(controller.pendingAsk?.width, 50)
        XCTAssertEqual(controller.pendingAsk?.destructiveID, ask.destructiveID)
    }

    func testHiddenPaneRejectsButVisibleMaximizedPaneOpens() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = register(windowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        configureSplit(session)
        session.isSplit = false
        session.splitFocused = false
        let placement = ControlAskPlacement(pane: .right)

        XCTAssertEqual(open(makeAsk(), target: session.id.uuidString, placement: placement),
                       ControlResponse(ok: false, error: "pane not visible"))
        XCTAssertNil(controller.pendingAsk)
        session.splitFocused = true
        XCTAssertTrue(open(makeAsk(), target: session.id.uuidString, placement: placement).ok)
        XCTAssertEqual(controller.pendingAsk?.anchor?.paneIdentity, session.splitPaneIdentity)
    }

    func testUnknownAndScratchTokensRejectWithoutTakingSlot() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = register(windowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        session.scratchSurface = AskTestSurface(token: "scratch-token")

        XCTAssertEqual(open(makeAsk(), target: session.id.uuidString, placement: ControlAskPlacement(paneID: "missing")),
                       ControlResponse(ok: false, error: "unknown pane id: missing"))
        XCTAssertEqual(open(makeAsk(), target: session.id.uuidString, placement: ControlAskPlacement(paneID: "scratch-token")),
                       ControlResponse(ok: false, error: "ask pane must be left or right"))
        XCTAssertNil(controller.pendingAsk)
    }

    func testUnresolvedTokenUsesExplicitRoleFallback() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = register(windowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let ask = makeAsk()

        XCTAssertEqual(open(ask, target: session.id.uuidString, placement: ControlAskPlacement(pane: .left, paneID: "old")),
                       ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: "left")))
        XCTAssertEqual(controller.pendingAsk?.anchor?.paneIdentity, session.paneIdentity)
    }

    func testAnchoredOpenRejectsZoomWhileUnanchoredOpenRemainsAvailable() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        _ = register(windowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        zoom.set(.on, target: .session(session.id, .primary))

        XCTAssertEqual(open(makeAsk(), target: session.id.uuidString),
                       ControlResponse(ok: false, error: "session not visible"))
        XCTAssertTrue(open(makeAsk()).ok)
        XCTAssertEqual(zoom.target, .session(session.id, .primary))
    }

    func testAnchoredOpenRejectsDashboardWhileUnanchoredOpenRemainsAvailable() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        _ = register(windowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let dashboard = DashboardController()
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        dashboard.open(members: [DashboardMember(session: session.id, surface: .primary)])

        XCTAssertEqual(open(makeAsk(), target: session.id.uuidString),
                       ControlResponse(ok: false, error: "session not visible"))
        XCTAssertTrue(open(makeAsk()).ok)
        XCTAssertTrue(dashboard.isOpen)
    }

    func testOpenRejectsEitherExistingModalOwner() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = register(windowID)
        let pick = PendingPick(id: "pick", items: [ControlPickItem(id: "one", label: "One")])
        XCTAssertTrue(controller.open(pick))
        XCTAssertEqual(open(makeAsk()), ControlResponse(ok: false, error: "pick already pending"))
        XCTAssertEqual(controller.pending, pick)
        controller.cancel()
        let ask = makeAsk()
        XCTAssertTrue(open(ask).ok)
        XCTAssertEqual(open(makeAsk()), ControlResponse(ok: false, error: "ask already pending"))
        XCTAssertEqual(controller.pendingAsk?.id, ask.id)
    }

    func testResultsAndCancellationFollowIDAndRejectWindowMismatch() throws {
        let ownerID = try XCTUnwrap(library.activeWindowID)
        let owner = register(ownerID)
        let ask = makeAsk()
        XCTAssertTrue(open(ask).ok)
        let otherID = library.newWindow(name: "other").id
        _ = register(otherID)

        XCTAssertEqual(server.askResult(ask.id, window: nil).result?.ask, ControlAskResult(result: .pending))
        XCTAssertEqual(server.askResult(ask.id, window: otherID.uuidString),
                       ControlResponse(ok: false, error: "unknown ask: \(ask.id)"))
        XCTAssertFalse(server.cancelAsk(ask.id, window: otherID.uuidString).ok)
        XCTAssertEqual(owner.pendingAsk?.id, ask.id)
        XCTAssertTrue(server.cancelAsk(ask.id, window: nil).ok)
        XCTAssertEqual(server.askResult(ask.id, window: ownerID.uuidString).result?.ask, ControlAskResult(result: .cancelled))
        XCTAssertTrue(server.cancelAsk(ask.id, window: ownerID.uuidString).ok)
        XCTAssertNil(server.controlTree(window: ownerID.uuidString).result?.tree?.askPending)
        XCTAssertFalse(server.askResult("unknown", window: nil).ok)
        XCTAssertFalse(server.cancelAsk("unknown", window: nil).ok)
    }

    func testRetainedResultSurvivesClosingAllWindows() throws {
        let ownerID = try XCTUnwrap(library.activeWindowID)
        _ = register(ownerID)
        let ask = makeAsk()
        XCTAssertTrue(open(ask).ok)
        PickRegistry.shared.unregister(ownerID)
        library.closeWindow(ownerID)

        XCTAssertNil(library.activeStore)
        XCTAssertEqual(server.askResult(ask.id, window: nil).result?.ask, ControlAskResult(result: .cancelled))
        XCTAssertEqual(server.askResult(ask.id, window: ownerID.uuidString).result?.ask, ControlAskResult(result: .cancelled))
        XCTAssertTrue(server.cancelAsk(ask.id, window: nil).ok)
        XCTAssertTrue(server.cancelAsk(ask.id, window: ownerID.uuidString).ok)
        let otherID = library.newWindow(name: "other").id
        XCTAssertFalse(server.askResult(ask.id, window: otherID.uuidString).ok)
        XCTAssertFalse(server.cancelAsk(ask.id, window: otherID.uuidString).ok)
    }

    func testCancellingAnAnsweredAskLeavesTheNextPendingAskAlone() throws {
        let ownerID = try XCTUnwrap(library.activeWindowID)
        let controller = register(ownerID)
        let first = makeAsk()
        XCTAssertTrue(open(first).ok)
        let answer = ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0)
        controller.resolveAsk(answer)
        let next = makeAsk()
        XCTAssertTrue(open(next).ok)

        XCTAssertTrue(server.cancelAsk(first.id, window: nil).ok)
        XCTAssertEqual(server.askResult(first.id, window: nil).result?.ask, answer)
        XCTAssertEqual(controller.pendingAsk?.id, next.id)
    }

    func testAskBlocksControlCoversAndSearchButAllowsDismissals() async throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        configureSplit(session)
        let controller = register(windowID)
        TerminalZoomRegistry.shared.register(windowID, controller: TerminalZoomController())
        DashboardControllerRegistry.shared.register(windowID, controller: DashboardController())
        let ask = makeAsk()
        XCTAssertTrue(open(ask).ok)
        let blocked = ControlResponse(ok: false, error: "ask pending")

        XCTAssertEqual(server.setQuickTerminal(mode: "show"), blocked)
        XCTAssertEqual(server.setSurfaceZoom(nil, window: windowID.uuidString, mode: .on), blocked)
        XCTAssertEqual(server.setSurfaceZoom(TerminalZoomTarget.session(session.id, .primary).controlID,
                                             window: windowID.uuidString, mode: .on), blocked)
        XCTAssertEqual(server.setDashboard(targets: [session.id.uuidString], window: windowID.uuidString,
                                           close: false, fontMode: .untouched, mru: false), blocked)
        let searchOpen = await server.searchSession(session.id, store: store, text: "needle", to: nil)
        XCTAssertEqual(searchOpen, blocked)
        let searchNext = await server.searchSession(session.id, store: store, text: nil, to: "next")
        XCTAssertEqual(searchNext, blocked)
        let searchClose = await server.searchSession(session.id, store: store, text: nil, to: "close")
        XCTAssertTrue(searchClose.ok)
        XCTAssertTrue(server.setQuickTerminal(mode: "hide").ok)
        XCTAssertTrue(server.setSurfaceZoom(nil, window: windowID.uuidString, mode: .off).ok)
        XCTAssertTrue(server.setDashboard(targets: [], window: windowID.uuidString,
                                          close: true, fontMode: .untouched, mru: false).ok)
        XCTAssertEqual(controller.pendingAsk?.id, ask.id)
    }

    func testCommandWEscapesWithoutClosingSessionOrZoom() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = register(windowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        zoom.set(.on, target: .session(session.id, .primary))
        let ask = makeAsk()
        XCTAssertTrue(open(ask).ok)

        XCTAssertTrue(actions.closeActiveSession())

        XCTAssertEqual(controller.askResult(for: ask.id),
                       ControlAskResult(result: .escaped))
        XCTAssertEqual(zoom.target, .session(session.id, .primary))
        XCTAssertEqual(library.activeStore?.activeSession?.id, session.id)
    }

    func testUnmountedTerminalAskDoesNotInterceptCommandW() throws {
        let sessionID = try XCTUnwrap(library.activeStore?.activeSession?.id)
        let ask = PendingAsk(id: UUID().uuidString, title: "Continue?", buttons: [ControlAskButton(id: "yes", label: "Yes")])
        XCTAssertTrue(open(ask).ok)
        XCTAssertTrue(actions.closeActiveSession())
        XCTAssertEqual(server.askResult(ask.id, window: nil).result?.ask, ControlAskResult(result: .cancelled))
        XCTAssertNil(library.activeStore?.session(withID: sessionID))
    }

    func testEscapeReleasesTheModalSlot() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = register(windowID)
        let ask = makeAsk()
        XCTAssertTrue(open(ask).ok)
        XCTAssertTrue(actions.escapePendingAsk(for: windowID))
        XCTAssertEqual(controller.askResult(for: ask.id), ControlAskResult(result: .escaped))
    }

    func testTerminationCancelsBothFamiliesAcrossWindows() throws {
        let ownerID = try XCTUnwrap(library.activeWindowID)
        let controller = register(ownerID)
        let ask = makeAsk()
        XCTAssertTrue(open(ask).ok)
        let otherID = library.newWindow(name: "other").id
        let pick = register(otherID)
        XCTAssertTrue(pick.open(PendingPick(id: "termination-pick", items: [ControlPickItem(id: "one", label: "One")])))
        let counts = library.openCounts()

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)

        XCTAssertEqual(controller.askResult(for: ask.id), ControlAskResult(result: .cancelled))
        XCTAssertEqual(pick.result(for: "termination-pick"), ControlPickResult(result: .cancelled))
        XCTAssertEqual(library.openCounts().windows, counts.windows)
        XCTAssertEqual(library.openCounts().sessions, counts.sessions)
    }

    func testAskUsesSharedMenuAndWindowFocusGates() throws {
        let ownerID = try XCTUnwrap(library.activeWindowID)
        _ = register(ownerID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows[ownerID] = window
        WindowRegistry.shared.register(ownerID, window: window)
        let ask = makeAsk()
        XCTAssertTrue(open(ask).ok)

        XCTAssertFalse(actions.uiActionsEnabled)
        XCTAssertTrue(actions.paletteContext.modalActive)
        XCTAssertTrue(actions.pickActive(for: ownerID))
        XCTAssertTrue(GhosttySurfaceView.pickOwnsFocus(in: window))
        XCTAssertFalse(actions.pickActive(for: UUID()))
        XCTAssertTrue(server.cancelAsk(ask.id, window: nil).ok)
        XCTAssertTrue(actions.uiActionsEnabled)
        XCTAssertFalse(actions.paletteContext.modalActive)
        XCTAssertFalse(GhosttySurfaceView.pickOwnsFocus(in: window))
    }

    private func register(_ windowID: UUID) -> PickController {
        let controller = PickController()
        PickRegistry.shared.register(windowID, controller: controller)
        registeredIDs.insert(windowID)
        return controller
    }

    private func configureSplit(_ session: Session) {
        session.hasSplit = true
        session.isSplit = true
        session.splitPaneIdentity = UUID()
        session.surface = AskTestSurface(token: "left-token")
        session.splitSurface = AskTestSurface(token: "right-token")
    }

    private func makeAsk() -> PendingAsk {
        PendingAsk(id: UUID().uuidString, title: "Continue?", message: "Choose an action.", buttons: [
            ControlAskButton(id: "yes", label: "Yes"), ControlAskButton(id: "no", label: "No"),
            ControlAskButton(id: "delete", label: "Delete"),
        ], defaultID: "yes", destructiveID: "delete", style: .gui, align: .left, width: 50)
    }

    private func open(_ ask: PendingAsk, target: String? = nil, window: String? = nil,
                      placement: ControlAskPlacement = ControlAskPlacement(), follow: Bool = false) -> ControlResponse {
        server.openAsk(ask, target: target, window: window, placement: placement, follow: follow)
    }
}

@MainActor
private final class AskTestSurface: TerminalSurface {
    let paneToken: String
    let isRealized = true

    init(token: String) { paneToken = token }
    func teardown() {}
    func promoteToPrimaryPane() {}
}
