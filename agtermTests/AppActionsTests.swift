import AppKit
import WebKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppActionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-actions-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            library = WindowLibrary(directory: stateDir)
            settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            actions = AppActions(library: library)
            actions.settingsModel = settings
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            HtmlOverlayRegistry.shared.setZoom(1)
            HtmlOverlayRegistry.shared.closePageSession = nil
            actions = nil
            settings = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    // a window step must never reach the `openWindow` hub: for a target still attaching its raise fails, the
    // hub falls back to enqueueClaim + a fresh scene, and one store ends up with two windows. No NSWindow is
    // registered under XCTest, so every raise here fails — the state the guard exists for.
    func testWindowStepNeverOpensASceneForAnUnattachedTarget() throws {
        _ = library.newWindow(name: "second")
        XCTAssertTrue(library.canStepWindows, "two open windows are needed for a step to have a target")
        let before = library.frontmostWindowID
        var opened: [WindowInfo.ID] = []
        actions.openWindow = { opened.append($0) }

        actions.selectNextWindow()
        actions.selectPreviousWindow()

        XCTAssertEqual(opened, [], "an unraisable step must drop, not spawn a second scene for the store")
        XCTAssertEqual(library.frontmostWindowID, before, "a step that did not raise must not move frontmost")
    }

    private func coveredSession() throws -> Session {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: "/tmp"))
        let page = HtmlOverlay(source: .file(path: "/tmp/a/report.html", grantRoot: nil))
        XCTAssertNil(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil))
        store.selectSession(session.id)
        return session
    }

    func testAPageOwnsTheFontKeysWhenFocusIsInsideIt() {
        let webView = HtmlOverlayWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let inner = NSView()
        webView.addSubview(inner)

        XCTAssertTrue(AppActions.htmlPageOwnsKeys(responder: webView, session: nil))
        XCTAssertTrue(AppActions.htmlPageOwnsKeys(responder: inner, session: nil))
    }

    func testACoveringPageOwnsTheFontKeysOnlyWhileNoTerminalHasFocus() throws {
        let session = try coveredSession()

        XCTAssertTrue(AppActions.htmlPageOwnsKeys(responder: nil, session: session))
        XCTAssertTrue(AppActions.htmlPageOwnsKeys(responder: NSView(), session: session))
        XCTAssertFalse(AppActions.htmlPageOwnsKeys(responder: GhosttySurfaceView(workingDirectory: NSTemporaryDirectory()),
                                                   session: session))
        XCTAssertTrue(try XCTUnwrap(library.activeStore).closeOverlay(session.id))
        XCTAssertFalse(AppActions.htmlPageOwnsKeys(responder: nil, session: session))
    }

    func testAnAskCatcherOverACoveringPageLeavesTheKeysWithThePage() throws {
        let session = try coveredSession()
        let catcher = AskKeyCatcher.KeyCatcherView()

        XCTAssertTrue(AppActions.htmlPageOwnsKeys(responder: catcher, session: session))
    }

    func testFontKeysUnderAnOpenDashboardLeaveThePageZoomAlone() throws {
        let session = try coveredSession()
        let dashboard = DashboardController()
        dashboard.open(members: [DashboardMember(session: session.id, surface: .primary)])
        let windowID = try XCTUnwrap(library.activeWindowID)
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        defer { DashboardControllerRegistry.shared.unregister(windowID) }

        actions.increaseFontSize()

        XCTAssertNil(settings.settings.htmlOverlayZoom)
        XCTAssertEqual(HtmlOverlayRegistry.shared.zoom, 1)
    }

    func testFontKeysOverACoveringPageStepThePageZoom() throws {
        _ = try coveredSession()

        actions.increaseFontSize()
        actions.decreaseFontSize()
        actions.decreaseFontSize()

        XCTAssertEqual(settings.settings.htmlOverlayZoom, 0.85)
        XCTAssertEqual(HtmlOverlayRegistry.shared.zoom, 0.85)
        actions.resetFontSize()
        XCTAssertNil(settings.settings.htmlOverlayZoom)
    }

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private func remoteActiveSession(reportedCwd: String) throws -> Session {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: home, remoteHost: "user@box"))
        session.currentCwd = reportedCwd
        return session
    }

    func testNewSessionCwdFollowsTheCurrentSessionThroughTheLocalRule() throws {
        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.currentSession.rawValue)
        let local = try XCTUnwrap(library.activeStore?.activeSession)
        local.currentCwd = "/nowhere/local"
        XCTAssertEqual(actions.resolvedNewSessionCwd(), "/nowhere/local")

        let remote = try remoteActiveSession(reportedCwd: stateDir.appendingPathComponent("only-on-the-remote").path)
        XCTAssertEqual(actions.resolvedNewSessionCwd(), home)
        remote.currentCwd = stateDir.path
        XCTAssertEqual(actions.resolvedNewSessionCwd(), stateDir.path)
    }

    func testNewSessionCwdKeepsTheFocusedSplitPaneAndTheEmptyCwdFallback() throws {
        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.currentSession.rawValue)
        let local = try XCTUnwrap(library.activeStore?.activeSession)
        local.currentCwd = "/nowhere/primary"
        let split = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        local.splitSurface = split
        local.splitCwd = "/nowhere/split"
        local.hasSplit = true
        local.isSplit = true
        local.splitFocused = true
        XCTAssertEqual(actions.resolvedNewSessionCwd(), "/nowhere/split")

        local.splitFocused = false
        local.currentCwd = ""
        XCTAssertEqual(actions.resolvedNewSessionCwd(), home)
    }

    func testNewSessionCwdCustomModeIgnoresTheActiveSessionsRemoteness() throws {
        settings.setNewSessionDirectory(AppSettings.NewSessionDirectory.custom.rawValue)
        settings.setNewSessionCustomDirectory("/nowhere/custom")
        _ = try remoteActiveSession(reportedCwd: stateDir.appendingPathComponent("only-on-the-remote").path)
        XCTAssertEqual(actions.resolvedNewSessionCwd(), "/nowhere/custom")
    }

    func testNewSessionAfterCurrentLandsBehindTheSelectedSession() throws {
        settings.setNewSessionPlacement(AppSettings.NewSessionPlacement.afterCurrent.rawValue)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let first = try XCTUnwrap(store.activeSession)
        _ = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: home))
        store.selectSession(first.id)

        actions.newSession()

        let sessions = try XCTUnwrap(store.workspaces.first { $0.id == workspace }).sessions
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[1].id, store.selectedSessionID)
    }

    func testOpenedDirectoryAppendsUnderAfterCurrent() throws {
        settings.setNewSessionPlacement(AppSettings.NewSessionPlacement.afterCurrent.rawValue)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let first = try XCTUnwrap(store.activeSession)
        _ = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: home))
        store.selectSession(first.id)

        XCTAssertTrue(actions.openSession(atDirectory: home))

        let sessions = try XCTUnwrap(store.workspaces.first { $0.id == workspace }).sessions
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.last?.id, store.selectedSessionID)
    }

    func testNewSessionAfterCurrentAppendsWhenTheSelectionIsInAnotherWorkspace() throws {
        settings.setNewSessionPlacement(AppSettings.NewSessionPlacement.afterCurrent.rawValue)
        let store = try XCTUnwrap(library.activeStore)
        let selected = try XCTUnwrap(store.selectedSessionID)
        actions.newWorkspace()
        let target = try XCTUnwrap(store.currentWorkspaceID)
        for _ in 0..<2 { _ = try XCTUnwrap(store.addSession(toWorkspace: target, cwd: home, select: false)) }
        XCTAssertEqual(store.currentWorkspaceID, target)
        XCTAssertNotEqual(store.sessionLocation(ofSession: selected)?.workspace, target)

        actions.newSession()

        let sessions = try XCTUnwrap(store.workspaces.first { $0.id == target }).sessions
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.last?.id, store.selectedSessionID)
    }

    private func pageRow(in store: AppStore) throws -> Session {
        let anchor = try XCTUnwrap(store.workspaces.first?.sessions.first)
        let overlay = HtmlOverlay(source: .file(path: "/tmp/agterm-missing-\(UUID().uuidString).html", grantRoot: nil), javascript: true)
        return try store.addPageSession(after: anchor.id, overlay: overlay, select: false).get()
    }

    private func waitFor(_ what: String, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("\(what) not reached within 5s") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAPageCloseRunsUnderAZoomInItsOwnWindow() throws {
        let store = try XCTUnwrap(library.activeStore)
        let windowID = try XCTUnwrap(library.windowID(for: store))
        let row = try pageRow(in: store)
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(windowID) }
        zoom.set(.on, target: .session(try XCTUnwrap(store.workspaces.first?.sessions.first).id, .primary))
        XCTAssertFalse(actions.uiActionsEnabled(for: windowID))

        XCTAssertTrue(actions.closePageSession(row.id, in: store))

        XCTAssertNotNil(store.pendingCloseSession(withID: row.id))
    }

    func testAPageCloseRunsUnderADashboardInItsOwnWindow() throws {
        let store = try XCTUnwrap(library.activeStore)
        let windowID = try XCTUnwrap(library.windowID(for: store))
        let row = try pageRow(in: store)
        let dashboard = DashboardController()
        dashboard.open(members: [DashboardMember(session: try XCTUnwrap(store.workspaces.first?.sessions.first).id, surface: .primary)])
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        defer { DashboardControllerRegistry.shared.unregister(windowID) }
        XCTAssertFalse(actions.uiActionsEnabled(for: windowID))

        XCTAssertTrue(actions.closePageSession(row.id, in: store))

        XCTAssertNotNil(store.pendingCloseSession(withID: row.id))
    }

    func testAnotherWindowsZoomAndPickLeaveAPageCloseInADifferentWindowAlone() throws {
        let back = try XCTUnwrap(library.activeStore)
        let row = try pageRow(in: back)
        let front = library.newWindow(name: "front").id
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(front, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(front) }
        zoom.set(.on, target: .session(UUID(), .primary))
        let pick = PickController()
        XCTAssertTrue(pick.open(PendingPick(id: "front", items: [])))
        PickRegistry.shared.register(front, controller: pick)
        defer { PickRegistry.shared.unregister(front) }
        XCTAssertNotEqual(library.windowID(for: back), front)

        XCTAssertTrue(actions.closePageSession(row.id, in: back))

        XCTAssertNotNil(back.pendingCloseSession(withID: row.id))
    }

    func testAPageCloseWithGraceUndoOffClosesWithoutAnUndo() throws {
        settings.setCloseGraceUndoEnabled(false)
        let store = try XCTUnwrap(library.activeStore)
        let row = try pageRow(in: store)

        XCTAssertTrue(actions.closePageSession(row.id, in: store))

        XCTAssertNil(store.session(withID: row.id))
        XCTAssertNil(store.pendingCloseSession(withID: row.id))
    }

    func testAPagesWindowCloseIsKeptWhileItsPickerIsPendingAndRunsOnceThePickerIsDismissed() async throws {
        let registry = HtmlOverlayRegistry.shared
        registry.install()
        var asked = 0
        registry.closePageSession = { [actions] store, id in
            asked += 1
            return actions?.closePageSession(id, in: store) ?? false
        }
        let store = try XCTUnwrap(library.activeStore)
        let windowID = try XCTUnwrap(library.windowID(for: store))
        let row = try pageRow(in: store)
        let selected = store.selectedSessionID
        let live = registry.page(for: try XCTUnwrap(row.htmlOverlay), store: store)
        let pick = PickController()
        XCTAssertTrue(pick.open(PendingPick(id: "busy", items: [])))
        PickRegistry.shared.register(windowID, controller: pick)
        defer { PickRegistry.shared.unregister(windowID) }

        live.webViewDidClose(live.webView)
        try await waitFor("the refused close was asked") { asked == 1 }
        XCTAssertNotNil(store.session(withID: row.id))
        XCTAssertNil(store.pendingCloseSession(withID: row.id))

        pick.cancel()
        registry.retryPageCloses(in: store)
        try await waitFor("the kept close ran") { store.pendingCloseSession(withID: row.id) != nil }
        registry.retryPageCloses(in: store)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(asked, 2)
        XCTAssertEqual(store.selectedSessionID, selected)
        store.finalizeAllPendingCloses()
    }
}
