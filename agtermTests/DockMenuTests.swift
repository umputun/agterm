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

    func testContentsEmptyStatesAndEnabledStates() throws {
        let windowID = try activeWindowID()

        var menu = try dockMenu()
        XCTAssertEqual(menu.items.map(\.title), [
            "New Session", "Quick Terminal", "Dashboard", "",
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
