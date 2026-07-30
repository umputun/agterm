import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Focused AppKit coverage for `applicationDockMenu`: these tests build the real `NSMenu`, inspect
/// AppKit's enabled state, and invoke retained `NSMenuItem` targets with a nil sender. Keeping this
/// in-process also lets a test change the frontmost window or modal registry after menu construction,
/// reproducing the stale-action window that a system-Dock XCUITest cannot hold open deterministically.
@MainActor
final class DockMenuTests: XCTestCase {
    private struct CapturedSessionAction {
        let windowID: UUID
        let store: AppStore
        let current: Session
        let item: NSMenuItem
    }

    private struct CapturedTopLevelActions {
        let store: AppStore
        let current: Session
        let quick: QuickTerminalController
        let dashboard: DashboardController
        let zoom: TerminalZoomController
        let menu: NSMenu
        let sessionCount: Int
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var delegate: AppDelegate!
    private var registeredWindowIDs: Set<UUID> = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-dock-menu-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            delegate = AppDelegate()
            delegate.library = library
            delegate.actions = actions
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            delegate.dockMenuActionTargets.removeAll()
            for id in registeredWindowIDs {
                QuickTerminalRegistry.shared.unregister(id)
                DashboardControllerRegistry.shared.unregister(id)
                TerminalZoomRegistry.shared.unregister(id)
            }
            delegate = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    // deliberately does NOT cover the shell-free scene: the only obvious probe
    // (`AppDelegate.controlServer == nil`) rides the scene's async `.task`, so it would pass even with
    // the `isHostedUnitTest` branch deleted.
    func testHostProcessStartsWithIsolatedStateAndSocket() throws {
        let environment = ProcessInfo.processInfo.environment
        let statePath = try XCTUnwrap(environment["AGTERM_STATE_DIR"])
        let socketPath = try XCTUnwrap(environment["AGTERM_CONTROL_SOCKET"])

        XCTAssertEqual(environment["AGTERM_HOSTED_TESTS"], "1")
        XCTAssertTrue(agtermApp.isHostedUnitTest)
        XCTAssertFalse(statePath.contains("$("), "Xcode must expand the state build setting before launch")
        XCTAssertFalse(socketPath.contains("$("), "Xcode must expand the socket build setting before launch")
        XCTAssertNotEqual(
            URL(fileURLWithPath: statePath).standardizedFileURL,
            PersistenceStore.defaultDirectory.standardizedFileURL
        )
        XCTAssertNotEqual(
            socketPath,
            ControlResolve.socketPath(stateDir: nil, appSupport: PersistenceStore.defaultDirectory.path)
        )
    }

    func testContentsEmptyStatesAndEnabledStates() throws {
        let windowID = try activeWindowID()

        var menu = try dockMenu()
        XCTAssertEqual(menu.items.map(\.title), [
            "New Session", "New Window", "Quick Terminal", "Dashboard", "",
            "Recent Sessions", "Sessions Needing Attention",
        ])
        XCTAssertTrue(try item("New Session", in: menu).isEnabled)
        XCTAssertFalse(try item("Quick Terminal", in: menu).isEnabled,
                       "quick terminal requires the captured window's registered controller")
        XCTAssertFalse(try item("Dashboard", in: menu).isEnabled,
                       "dashboard requires the captured window's registered controller")
        XCTAssertEqual(try submenu("Recent Sessions", in: menu).items.map(\.title), ["No Recent Sessions"])
        XCTAssertFalse(try submenu("Recent Sessions", in: menu).items[0].isEnabled)
        XCTAssertEqual(try submenu("Sessions Needing Attention", in: menu).items.map(\.title),
                       ["No Sessions Need Attention"])
        XCTAssertFalse(try submenu("Sessions Needing Attention", in: menu).items[0].isEnabled)

        let quick = QuickTerminalController()
        let dashboard = DashboardController()
        let zoom = TerminalZoomController()
        register(windowID, quick: quick, dashboard: dashboard, zoom: zoom)

        menu = try dockMenu()
        XCTAssertTrue(try item("Quick Terminal", in: menu).isEnabled)
        XCTAssertTrue(try item("Dashboard", in: menu).isEnabled,
                      "the seeded session supplies MRU dashboard content")

        let current = try XCTUnwrap(library.activeStore?.activeSession)
        zoom.set(.on, target: .session(current.id, .primary))
        menu = try dockMenu()
        XCTAssertFalse(try item("New Session", in: menu).isEnabled)
        XCTAssertFalse(try item("Quick Terminal", in: menu).isEnabled)
        XCTAssertFalse(try item("Dashboard", in: menu).isEnabled)

        zoom.clear()
        dashboard.open(members: [DashboardMember(session: current.id, surface: .primary)])
        menu = try dockMenu()
        XCTAssertFalse(try item("New Session", in: menu).isEnabled)
        XCTAssertFalse(try item("Quick Terminal", in: menu).isEnabled)
        XCTAssertTrue(try item("Dashboard", in: menu).isEnabled,
                      "an open dashboard remains enabled so the Dock action can close it")

        // the `dashboardWasOpen == true` half of the staleness guard, which nothing else invokes — every
        // other dashboard case builds the menu while it is closed.
        try invokeWithNilSender(try item("Dashboard", in: menu))
        XCTAssertFalse(dashboard.isOpen, "a Dashboard item built while the dashboard was open should close it")
    }

    // New Window captures no window, so unlike its neighbours it must stay live through every modal
    // state that makes them inert. Discussion #313.
    func testNewWindowStaysEnabledUnderModalsAndOpensAWindow() throws {
        let windowID = try activeWindowID()
        let quick = QuickTerminalController()
        let dashboard = DashboardController()
        let zoom = TerminalZoomController()
        register(windowID, quick: quick, dashboard: dashboard, zoom: zoom)
        let current = try XCTUnwrap(library.activeStore?.activeSession)

        zoom.set(.on, target: .session(current.id, .primary))
        var menu = try dockMenu()
        XCTAssertFalse(try item("New Session", in: menu).isEnabled, "the captured-window items gate on zoom")
        XCTAssertTrue(try item("New Window", in: menu).isEnabled,
                      "creating a window touches no existing window, so terminal zoom must not disable it")

        zoom.clear()
        dashboard.open(members: [DashboardMember(session: current.id, surface: .primary)])
        menu = try dockMenu()
        XCTAssertFalse(try item("New Session", in: menu).isEnabled)
        XCTAssertTrue(try item("New Window", in: menu).isEnabled,
                      "an open dashboard in the last-active window must not disable it either")

        // the opener is the scene's and nil outside a mounted scene, so stand in for it.
        var openedIDs: [UUID] = []
        actions.openWindow = { openedIDs.append($0) }
        let windowsBefore = library.windows.count

        try invokeWithNilSender(try item("New Window", in: menu))

        XCTAssertEqual(library.windows.count, windowsBefore + 1, "the Dock item should create a window")
        XCTAssertEqual(openedIDs.count, 1, "and open exactly the one it created")
        let created = try XCTUnwrap(library.windows.last)
        XCTAssertEqual(openedIDs.first, created.id)
    }

    // `actions` is wired in the scene `.task`, so during the launch window it is nil while the nil library
    // already disables every other item — New Window would be the only enabled one.
    func testNewWindowIsDisabledUntilTheActionHubIsWired() throws {
        delegate.actions = nil

        let menu = try dockMenu()
        let newWindow = try item("New Window", in: menu)
        XCTAssertFalse(newWindow.isEnabled, "with no action hub there is nothing for the item to drive")
        try invokeWithNilSender(newWindow)

        // creating a window needs neither a captured window nor the library reference.
        delegate.actions = actions
        delegate.library = nil
        XCTAssertTrue(try item("New Window", in: try dockMenu()).isEnabled)
    }

    // an orphaned entry would leave the library counting an open window with no NSWindow behind it, which
    // `applicationShouldTerminateAfterLastWindowClosed` reads to decide whether to quit.
    func testNewWindowWithoutAnOpenerCreatesNothing() throws {
        let menu = try dockMenu()
        let windowsBefore = library.windows.count

        XCTAssertNil(actions.openWindow, "precondition: no scene, so no opener")
        try invokeWithNilSender(try item("New Window", in: menu))

        XCTAssertEqual(library.windows.count, windowsBefore,
                       "no opener means no window entry, not an orphaned one")
    }

    func testRecentSessionsUseMRUOrderExcludeCurrentAndShareSwitcherCap() throws {
        let store = try activeStore()
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        store.activeSession?.customName = "seed"

        var added: [Session] = []
        for index in 1...(SessionSwitcher.maxCandidates + 2) {
            added.append(try XCTUnwrap(store.addSession(
                toWorkspace: workspaceID,
                cwd: "/tmp",
                name: "recent-\(index)"
            )))
        }
        let current = try XCTUnwrap(added.last)

        let recent = try submenu("Recent Sessions", in: dockMenu())
        let expected = added.dropLast().reversed().prefix(SessionSwitcher.maxCandidates)
            .map { "\($0.displayName) — workspace 1" }
        XCTAssertEqual(recent.items.map(\.title), Array(expected))
        XCTAssertEqual(recent.items.count, SessionSwitcher.maxCandidates)
        XCTAssertFalse(recent.items.contains { $0.title.contains(current.displayName) },
                       "the current session is not a Dock jump target")
        XCTAssertFalse(recent.items.contains { $0.title.contains("seed") },
                       "the shared cap drops older MRU entries")
    }

    func testAttentionOrderingAndRecentNilSenderInvocationRevealTaggedPane() throws {
        let store = try activeStore()
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "recent-blocked", select: true
        ))
        _ = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "current", select: true
        ))
        let completed = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "completed", select: false
        ))
        let active = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "active", select: false
        ))
        let blockedOld = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "blocked-old", select: false
        ))
        let blockedNew = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "blocked-new", select: false
        ))

        store.setAgentIndicator(AgentIndicator(status: .completed), forSession: completed.id)
        store.setAgentIndicator(AgentIndicator(status: .active), forSession: active.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: blockedOld.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked), forSession: blockedNew.id)
        store.setAgentIndicator(
            AgentIndicator(status: .blocked, statusPane: .scratch),
            forSession: target.id
        )

        let menu = try dockMenu()
        XCTAssertEqual(try submenu("Sessions Needing Attention", in: menu).items.map(\.title), [
            "recent-blocked — workspace 1",
            "blocked-new — workspace 1",
            "blocked-old — workspace 1",
            "active — workspace 1",
            "completed — workspace 1",
        ])

        let recentTarget = try item("recent-blocked — workspace 1",
                                    in: submenu("Recent Sessions", in: menu))
        XCTAssertFalse(target.scratchActive)
        try invokeWithNilSender(recentTarget)
        XCTAssertEqual(store.activeSession?.id, target.id)
        XCTAssertTrue(target.scratchActive,
                      "Recent Sessions must use pane-aware reveal for a non-idle session")
    }

    func testCapturedWindowSelectionPublishesAndTargetsOriginalWindow() throws {
        let windowA = try activeWindowID()
        let storeA = try activeStore()
        let workspaceA = try XCTUnwrap(storeA.currentWorkspaceID)
        let targetA = try XCTUnwrap(storeA.addSession(
            toWorkspace: workspaceA, cwd: "/tmp", name: "window-a-target", select: true
        ))
        let currentA = try XCTUnwrap(storeA.addSession(
            toWorkspace: workspaceA, cwd: "/tmp", name: "window-a-current", select: true
        ))

        let windowB = library.newWindow(name: "window B").id
        register(windowA)
        register(windowB)
        library.frontmostWindowID = windowA
        let capturedMenu = try dockMenu()
        let capturedTarget = try item("window-a-target — workspace 1",
                                      in: submenu("Recent Sessions", in: capturedMenu))

        library.frontmostWindowID = windowB
        try invokeWithNilSender(capturedTarget)

        XCTAssertEqual(library.frontmostWindowID, windowA,
                       "the captured window must publish synchronously before shared actions run")
        XCTAssertEqual(storeA.activeSession?.id, targetA.id)
        XCTAssertNotEqual(storeA.activeSession?.id, currentA.id)
        XCTAssertNotEqual(library.store(for: windowB)?.activeSession?.id, targetA.id)
    }

    func testTopLevelActionsStayWithCapturedWindowWhenAnotherBecomesFrontmost() throws {
        let windowA = try activeWindowID()
        let storeA = try activeStore()
        let windowB = library.newWindow(name: "window B").id
        let storeB = try XCTUnwrap(library.store(for: windowB))
        let quickA = QuickTerminalController()
        let quickB = QuickTerminalController()
        let dashboardA = DashboardController()
        let dashboardB = DashboardController()
        register(windowA, quick: quickA, dashboard: dashboardA, zoom: TerminalZoomController())
        register(windowB, quick: quickB, dashboard: dashboardB, zoom: TerminalZoomController())

        library.frontmostWindowID = windowA
        let capturedMenu = try dockMenu()
        let sessionCountA = storeA.workspaces.flatMap(\.sessions).count
        let sessionCountB = storeB.workspaces.flatMap(\.sessions).count

        dashboardB.open(members: [
            DashboardMember(session: try XCTUnwrap(storeB.activeSession?.id), surface: .primary),
        ])
        library.frontmostWindowID = windowB
        try invokeWithNilSender(try item("New Session", in: capturedMenu))
        XCTAssertEqual(storeA.workspaces.flatMap(\.sessions).count, sessionCountA + 1)
        XCTAssertEqual(storeB.workspaces.flatMap(\.sessions).count, sessionCountB)
        XCTAssertEqual(library.frontmostWindowID, windowA)

        library.frontmostWindowID = windowB
        try invokeWithNilSender(try item("Quick Terminal", in: capturedMenu))
        XCTAssertTrue(quickA.isVisible)
        XCTAssertFalse(quickB.isVisible)
        XCTAssertEqual(library.frontmostWindowID, windowA)

        library.frontmostWindowID = windowB
        try invokeWithNilSender(try item("Dashboard", in: capturedMenu))
        XCTAssertTrue(dashboardA.isOpen)
        XCTAssertTrue(dashboardB.isOpen, "the frontmost window's existing dashboard is untouched")
        XCTAssertEqual(library.frontmostWindowID, windowA)
    }

    func testCapturedTopLevelActionsBecomeInertWhenDashboardOpens() throws {
        let context = try makeCapturedTopLevelActions()
        let windowB = library.newWindow(name: "window B").id
        register(windowB)
        context.dashboard.open(members: [
            DashboardMember(session: context.current.id, surface: .primary),
        ])
        library.frontmostWindowID = windowB

        for title in ["New Session", "Quick Terminal", "Dashboard"] {
            try invokeWithNilSender(try item(title, in: context.menu))
            XCTAssertEqual(library.frontmostWindowID, windowB,
                           "\(title) must reject captured-window modal state before activating that window")
        }

        XCTAssertEqual(context.store.workspaces.flatMap(\.sessions).count, context.sessionCount)
        XCTAssertFalse(context.quick.isVisible)
        XCTAssertTrue(context.dashboard.isOpen,
                      "a Dashboard item built while closed must not close a post-build dashboard")
    }

    func testCapturedTopLevelActionsBecomeInertWhenTerminalZoomBegins() throws {
        let context = try makeCapturedTopLevelActions()
        let windowB = library.newWindow(name: "window B").id
        register(windowB)
        let target = TerminalZoomTarget.session(context.current.id, .primary)
        context.zoom.set(.on, target: target)
        library.frontmostWindowID = windowB

        for title in ["New Session", "Quick Terminal", "Dashboard"] {
            try invokeWithNilSender(try item(title, in: context.menu))
            XCTAssertEqual(library.frontmostWindowID, windowB,
                           "\(title) must reject captured-window zoom before activating that window")
        }

        XCTAssertEqual(context.store.workspaces.flatMap(\.sessions).count, context.sessionCount)
        XCTAssertFalse(context.quick.isVisible)
        XCTAssertFalse(context.dashboard.isOpen)
        XCTAssertEqual(context.zoom.target, target)
    }

    func testBlockedLeftAndOmittedPaneSelectionClearSplitSelectionState() throws {
        let store = try activeStore()
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        let explicitLeft = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "explicit-left", select: true
        ))
        let omittedPane = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "omitted-pane", select: true
        ))
        _ = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "current", select: true
        ))

        for session in [explicitLeft, omittedPane] {
            session.surface = DockMenuTestSurface()
            session.splitSurface = DockMenuTestSurface()
            session.hasSplit = true
            session.isSplit = true
            session.splitFocused = true
        }
        store.setAgentIndicator(
            AgentIndicator(status: .blocked, statusPane: .left),
            forSession: explicitLeft.id
        )
        store.setAgentIndicator(
            AgentIndicator(status: .blocked),
            forSession: omittedPane.id
        )

        // DockMenuTestSurface is not a GhosttySurfaceView, so this windowless hosted test verifies
        // the primary-pane selection intent (`splitFocused`) rather than AppKit first-responder movement.
        let recent = try submenu("Recent Sessions", in: dockMenu())
        try invokeWithNilSender(try item("explicit-left — workspace 1", in: recent))
        XCTAssertFalse(explicitLeft.splitFocused, "an explicit left status must target the primary pane")

        omittedPane.splitFocused = true
        try invokeWithNilSender(try item("omitted-pane — workspace 1", in: recent))
        XCTAssertFalse(omittedPane.splitFocused, "an omitted status pane defaults to the primary pane")
    }

    func testBlockedRightPaneSelectionSetsSplitSelectionState() throws {
        let store = try activeStore()
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "right-target", select: true
        ))
        _ = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "current", select: true
        ))
        target.surface = DockMenuTestSurface()
        target.splitSurface = DockMenuTestSurface()
        target.hasSplit = true
        target.isSplit = true
        target.splitFocused = false
        store.setAgentIndicator(
            AgentIndicator(status: .blocked, statusPane: .right),
            forSession: target.id
        )

        let recent = try submenu("Recent Sessions", in: dockMenu())
        try invokeWithNilSender(try item("right-target — workspace 1", in: recent))

        XCTAssertTrue(target.splitFocused,
                      "a blocked right-pane status must select the split focus target")
    }

    func testAutoResetAttentionSelectionUsesCapturedRightAndScratchPanes() throws {
        let store = try activeStore()
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        let right = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "auto-reset-right", select: true
        ))
        let scratch = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "auto-reset-scratch", select: true
        ))
        _ = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "current", select: true
        ))
        right.surface = DockMenuTestSurface()
        right.splitSurface = DockMenuTestSurface()
        right.hasSplit = true
        right.isSplit = true
        right.splitFocused = false
        scratch.surface = DockMenuTestSurface()
        store.setAgentIndicator(
            AgentIndicator(status: .completed, autoReset: true, statusPane: .right),
            forSession: right.id
        )
        store.setAgentIndicator(
            AgentIndicator(status: .completed, autoReset: true, statusPane: .scratch),
            forSession: scratch.id
        )

        let recent = try submenu("Recent Sessions", in: dockMenu())
        try invokeWithNilSender(try item("auto-reset-right — workspace 1", in: recent))
        XCTAssertEqual(right.agentIndicator.status, .idle,
                       "visiting an auto-reset session must still clear its status")
        XCTAssertTrue(right.splitFocused,
                      "Dock selection must preserve the right-pane target captured before auto-reset")

        try invokeWithNilSender(try item("auto-reset-scratch — workspace 1", in: recent))
        XCTAssertEqual(scratch.agentIndicator.status, .idle)
        XCTAssertTrue(scratch.scratchActive,
                      "Dock selection must preserve the scratch target captured before auto-reset")
    }

    func testNavigationUsesIndicatorCapturedBySharedSelectionBeforeAutoReset() throws {
        let store = try activeStore()
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "shared-auto-reset", select: true
        ))
        target.surface = DockMenuTestSurface()
        target.splitSurface = DockMenuTestSurface()
        target.hasSplit = true
        target.isSplit = true
        _ = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "current", select: true
        ))
        store.setAgentIndicator(
            AgentIndicator(status: .completed, autoReset: true, statusPane: .right),
            forSession: target.id
        )

        actions.selectPreviousSession()

        XCTAssertEqual(store.activeSession?.id, target.id)
        XCTAssertEqual(target.agentIndicator.status, .idle)
        XCTAssertTrue(target.splitFocused,
                      "non-Dock selection must retain the pre-reset right-pane routing value")
    }

    func testActiveStatusUsesOrdinarySelectionWithoutPaneReveal() throws {
        let store = try activeStore()
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        let left = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "active-left", select: true
        ))
        let scratch = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "active-scratch", select: true
        ))
        _ = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "current", select: true
        ))
        for session in [left, scratch] {
            session.surface = DockMenuTestSurface()
            session.splitSurface = DockMenuTestSurface()
            session.hasSplit = true
            session.isSplit = true
        }
        left.splitFocused = true
        store.setAgentIndicator(
            AgentIndicator(status: .active, statusPane: .left),
            forSession: left.id
        )
        store.setAgentIndicator(
            AgentIndicator(status: .active, statusPane: .scratch),
            forSession: scratch.id
        )

        let recent = try submenu("Recent Sessions", in: dockMenu())
        try invokeWithNilSender(try item("active-left — workspace 1", in: recent))
        XCTAssertTrue(left.splitFocused,
                      "an active status must preserve the user's existing pane selection")

        XCTAssertFalse(scratch.scratchActive)
        try invokeWithNilSender(try item("active-scratch — workspace 1", in: recent))
        XCTAssertFalse(scratch.scratchActive,
                       "an active status must not reveal the status-tagged scratch pane")
    }

    func testCapturedSessionActionRechecksDashboardState() throws {
        let context = try makeCapturedSessionAction()
        let dashboard = DashboardController()
        register(context.windowID, dashboard: dashboard)
        dashboard.open(members: [DashboardMember(session: context.current.id, surface: .primary)])

        try invokeWithNilSender(context.item)

        XCTAssertEqual(context.store.activeSession?.id, context.current.id,
                       "a menu item captured before the dashboard opened must become inert")
    }

    func testCapturedSessionActionRechecksTerminalZoomState() throws {
        let context = try makeCapturedSessionAction()
        let zoom = TerminalZoomController()
        register(context.windowID, zoom: zoom)
        zoom.set(.on, target: .session(context.current.id, .primary))

        try invokeWithNilSender(context.item)

        XCTAssertEqual(context.store.activeSession?.id, context.current.id,
                       "a menu item captured before terminal zoom began must become inert")
    }

    func testCapturedActionsBecomeInertAfterWindowCloses() throws {
        let windowA = try activeWindowID()
        var retainedStore: AppStore? = try activeStore()
        weak let weakStore = retainedStore
        let workspaceID = try XCTUnwrap(retainedStore?.currentWorkspaceID)
        var retainedSession: Session? = try XCTUnwrap(retainedStore?.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "closed-target", select: true
        ))
        weak let weakSession = retainedSession
        var retainedSurface: DockMenuTestSurface? = DockMenuTestSurface()
        weak let weakSurface = retainedSurface
        retainedSession?.surface = retainedSurface
        _ = try XCTUnwrap(retainedStore?.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "closed-current", select: true
        ))
        let windowB = library.newWindow(name: "window B").id
        let windowBSession = try XCTUnwrap(library.store(for: windowB)?.activeSession?.id)
        let quick = QuickTerminalController()
        let dashboard = DashboardController()
        register(windowA, quick: quick, dashboard: dashboard, zoom: TerminalZoomController())
        library.frontmostWindowID = windowA

        let menu = try dockMenu()
        let sessionItem = try item(
            "closed-target — workspace 1",
            in: submenu("Recent Sessions", in: menu)
        )
        let sessionCount = retainedStore?.workspaces.flatMap(\.sessions).count
        library.closeWindow(windowA)
        XCTAssertNil(library.store(for: windowA))

        for title in ["New Session", "Quick Terminal", "Dashboard"] {
            try invokeWithNilSender(try item(title, in: menu))
        }
        XCTAssertEqual(retainedStore?.workspaces.flatMap(\.sessions).count, sessionCount)
        XCTAssertFalse(quick.isVisible)
        XCTAssertFalse(dashboard.isOpen)
        XCTAssertEqual(library.frontmostWindowID, windowB)

        retainedStore?.cancelPendingSave()
        retainedStore = nil
        retainedSession = nil
        retainedSurface = nil
        XCTAssertNil(weakStore, "Dock targets must not retain a closed window's store")
        XCTAssertNil(weakSession, "Dock targets must capture a session id, not retain the session")
        XCTAssertNil(weakSurface, "Dock targets must not prolong a closed session's surface lifetime")
        try invokeWithNilSender(sessionItem)
        XCTAssertEqual(library.store(for: windowB)?.activeSession?.id, windowBSession)
    }

    func testContentsBeforeLibraryWiringUseDisabledAndEmptyStates() throws {
        let sessionCount = try activeStore().workspaces.flatMap(\.sessions).count
        delegate.library = nil

        let menu = try dockMenu()
        for title in ["New Session", "Quick Terminal", "Dashboard"] {
            let topLevelItem = try item(title, in: menu)
            XCTAssertFalse(topLevelItem.isEnabled)
            try invokeWithNilSender(topLevelItem)
        }
        XCTAssertEqual(try submenu("Recent Sessions", in: menu).items.map(\.title),
                       ["No Recent Sessions"])
        XCTAssertEqual(try submenu("Sessions Needing Attention", in: menu).items.map(\.title),
                       ["No Sessions Need Attention"])
        XCTAssertEqual(try activeStore().workspaces.flatMap(\.sessions).count, sessionCount)
    }

    func testMenuRebuildInvalidatesTargetsFromPreviousMenu() throws {
        let firstMenu = try dockMenu()
        let staleItem = try item("New Session", in: firstMenu)
        let staleAction = try XCTUnwrap(staleItem.action)
        let staleTarget = try XCTUnwrap(staleItem.target)
        let sessionCount = try activeStore().workspaces.flatMap(\.sessions).count

        let replacementMenu = try dockMenu()
        let replacementItem = try item("New Session", in: replacementMenu)

        XCTAssertTrue(NSApp.sendAction(staleAction, to: staleTarget, from: nil),
                      "an already-loaded stale target must still accept an in-flight nil-sender dispatch")
        XCTAssertEqual(try activeStore().workspaces.flatMap(\.sessions).count, sessionCount,
                       "an in-flight item from a replaced Dock menu must be inert after invalidation")

        try invokeWithNilSender(replacementItem)
        XCTAssertEqual(try activeStore().workspaces.flatMap(\.sessions).count, sessionCount + 1)
    }

    private func makeCapturedTopLevelActions() throws -> CapturedTopLevelActions {
        let windowID = try activeWindowID()
        let store = try activeStore()
        let current = try XCTUnwrap(store.activeSession)
        let quick = QuickTerminalController()
        let dashboard = DashboardController()
        let zoom = TerminalZoomController()
        register(windowID, quick: quick, dashboard: dashboard, zoom: zoom)
        let menu = try dockMenu()
        for title in ["New Session", "Quick Terminal", "Dashboard"] {
            XCTAssertTrue(try item(title, in: menu).isEnabled)
        }
        return CapturedTopLevelActions(
            store: store,
            current: current,
            quick: quick,
            dashboard: dashboard,
            zoom: zoom,
            menu: menu,
            sessionCount: store.workspaces.flatMap(\.sessions).count
        )
    }

    private func makeCapturedSessionAction() throws -> CapturedSessionAction {
        let windowID = try activeWindowID()
        let store = try activeStore()
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        _ = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "stale-target", select: true
        ))
        let current = try XCTUnwrap(store.addSession(
            toWorkspace: workspaceID, cwd: "/tmp", name: "stale-current", select: true
        ))
        register(windowID)
        let menu = try dockMenu()
        let target = try item("stale-target — workspace 1",
                              in: submenu("Recent Sessions", in: menu))
        XCTAssertTrue(target.isEnabled)
        return CapturedSessionAction(
            windowID: windowID,
            store: store,
            current: current,
            item: target
        )
    }

    private func register(
        _ windowID: UUID,
        quick: QuickTerminalController? = nil,
        dashboard: DashboardController? = nil,
        zoom: TerminalZoomController? = nil
    ) {
        registeredWindowIDs.insert(windowID)
        if let quick { QuickTerminalRegistry.shared.register(windowID, controller: quick) }
        if let dashboard { DashboardControllerRegistry.shared.register(windowID, controller: dashboard) }
        if let zoom { TerminalZoomRegistry.shared.register(windowID, controller: zoom) }
    }

    private func dockMenu() throws -> NSMenu {
        try XCTUnwrap(delegate.applicationDockMenu(NSApp))
    }

    private func activeStore() throws -> AppStore {
        try XCTUnwrap(library.activeStore)
    }

    private func activeWindowID() throws -> UUID {
        try XCTUnwrap(library.activeWindowID)
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, "missing menu item '\(title)'")
    }

    private func submenu(_ title: String, in menu: NSMenu) throws -> NSMenu {
        try XCTUnwrap(try item(title, in: menu).submenu, "missing submenu '\(title)'")
    }

    private func invokeWithNilSender(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action)
        let target = try XCTUnwrap(item.target)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: nil),
                      "AppKit should dispatch the retained Dock target with a nil sender")
    }
}

@MainActor
private final class DockMenuTestSurface: TerminalSurface {
    let paneToken = ""

    func teardown() {}
    func promoteToPrimaryPane() {}
}
