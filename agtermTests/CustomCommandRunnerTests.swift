import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Coverage for the built-in bindings a `map` line puts beyond its menu key equivalent: they ride
/// `CustomCommandRunner`'s key monitor and dispatch through `AppActions.perform(_:)`, while the menu-bound
/// alternative stays AppKit's. `FullScreenChordTests` covers the same monitor's `toggle_fullscreen` special
/// case; the custom-command half of the matcher is pinned host-free in `CustomCommandEngineTests`.
@MainActor
final class CustomCommandRunnerTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var window: NSWindow!
    private var windowID: WindowInfo.ID!
    private var started: [CustomCommandRunner] = []

    /// A menu chord deliberately unlike `toggle_sidebar`'s shipped one, so the monitor cannot appear to work
    /// by accident, plus the leader alternative every case below drives.
    private static let sidebarKeymap = "map cmd+ctrl+shift+s|ctrl+a>s toggle_sidebar\n"

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-runner-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            // `NSWindow` defaults isReleasedWhenClosed to true; see the hosted-test rule in ui-tests.md.
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // the monitor fires only for an agterm terminal window, which the registry is what decides.
            // `WindowRegistry.shared` is process-global, so the id is retained for tearDown to unregister.
            windowID = UUID()
            WindowRegistry.shared.register(windowID, window: window)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            started.forEach { $0.stop() }
            started = []
            WindowRegistry.shared.unregister(windowID)
            windowID = nil
            window.orderOut(nil)
            window = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private var configDir: URL { stateDir.appendingPathComponent("config", isDirectory: true) }

    private func write(keymap: String) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try keymap.write(to: ConfigPaths.keymapPath(configDirectory: configDir), atomically: true, encoding: .utf8)
    }

    private struct Fixture {
        let runner: CustomCommandRunner
        let settings: SettingsModel
        let actions: AppActions
        let store: AppStore
        let sidebarBefore: Bool
    }

    /// A started runner over `keymap` written into an isolated config directory — the matcher is built from
    /// the parsed keymap, so a seeded file is the only way to reach it — plus the store and the sidebar state
    /// the chord is expected to flip. The settings model comes back so a test can rewrite the file and drive
    /// the reload path; the runner is stopped at teardown.
    private func fixture(keymap: String = CustomCommandRunnerTests.sidebarKeymap) throws -> Fixture {
        try write(keymap: keymap)
        let settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        settings.setConfigDirectory(configDir.path)
        let actions = AppActions(library: library)
        actions.settingsModel = settings
        let runner = CustomCommandRunner(library: library, settings: settings, actions: actions,
                                         socketProvider: { "" })
        runner.start()
        started.append(runner)
        let store = try XCTUnwrap(library.activeStore)
        return Fixture(runner: runner, settings: settings, actions: actions, store: store,
                       sidebarBefore: store.sidebarVisible)
    }

    /// An OPEN dashboard grid over the active window — the modal cover whose menu items stay live for some
    /// actions and not others. Unregistered by the returned closure.
    private func openDashboard() throws -> (controller: DashboardController, close: () -> Void) {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let dashboard = DashboardController()
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        dashboard.open(members: [DashboardMember(session: UUID(), surface: .primary)])
        XCTAssertTrue(dashboard.isOpen)
        return (dashboard, { DashboardControllerRegistry.shared.unregister(windowID) })
    }

    private func keyDown(_ key: String, keyCode: UInt16, mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil,
                         characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
    }

    private var leader: NSEvent { keyDown("a", keyCode: 0, mods: [.control]) }
    private var sidebarTail: NSEvent { keyDown("s", keyCode: 1, mods: []) }

    func testBuiltinSequenceAlternativeRunsTheActionAndIsConsumed() throws {
        let fix = try fixture()

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window), "ctrl+a should arm the leader")
        XCTAssertTrue(fix.runner.handleKeyDown(sidebarTail, in: window),
                      "the completing chord must be consumed, not passed to the terminal")
        XCTAssertEqual(fix.store.sidebarVisible, !fix.sidebarBefore)
    }

    // the menu-bound alternative belongs to AppKit, so the monitor must leave it alone — registering it in
    // both places is the double dispatch the menu/monitor split exists to prevent.
    func testTheMenuBoundAlternativeIsNotAlsoDispatchedByTheMonitor() throws {
        let fix = try fixture()

        let menuChord = keyDown("s", keyCode: 1, mods: [.command, .control, .shift])
        XCTAssertFalse(fix.runner.handleKeyDown(menuChord, in: window), "the menu carries this one")
        XCTAssertEqual(fix.store.sidebarVisible, fix.sidebarBefore)
    }

    // the reason `.firedBuiltin` routes through the palette rather than calling the action directly: with a
    // picker pending, the key is still consumed but the action must not run.
    func testBuiltinAlternativeInheritsThePalettesModalGate() throws {
        let fix = try fixture()
        let modalWindow = try XCTUnwrap(library.activeWindowID)
        let pick = PickController()
        PickRegistry.shared.register(modalWindow, controller: pick)
        defer { PickRegistry.shared.unregister(modalWindow) }
        XCTAssertTrue(pick.open(PendingPick(id: "gate", items: [ControlPickItem(id: "item", label: "Item")])))

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(sidebarTail, in: window),
                      "the chord is consumed either way; only the action is gated")
        XCTAssertEqual(fix.store.sidebarVisible, fix.sidebarBefore, "a pending picker must block the palette action")
    }

    // Navigate ▸ Dashboard keeps its key equivalent live over the open grid, so its alternative must close the
    // grid too — the blanket palette gate would leave the user's second binding inert behind its own cover.
    func testDashboardAlternativeClosesTheOpenGridLikeItsMenuChord() throws {
        let fix = try fixture(keymap: "map cmd+ctrl+shift+d|ctrl+a>d dashboard\n")
        let dashboard = try openDashboard()
        defer { dashboard.close() }

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(keyDown("d", keyCode: 2, mods: []), in: window))
        XCTAssertFalse(dashboard.controller.isOpen, "the alternative must reach its own escape hatch")
    }

    // the mirror case: Navigate ▸ Command Palette IS disabled over the grid, so its alternative must not open
    // the palette the menu item refuses to open.
    func testPaletteLauncherAlternativeStaysShutOverTheDashboardLikeItsMenuItem() throws {
        let fix = try fixture(keymap: "map cmd+ctrl+shift+p|ctrl+a>p command_palette\n")
        let palette = PaletteController()
        fix.actions.palette = palette
        let dashboard = try openDashboard()

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(keyDown("p", keyCode: 35, mods: []), in: window))
        XCTAssertNil(palette.mode, "a launcher must not open over the dashboard grid")

        dashboard.controller.close()
        dashboard.close()
        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(keyDown("p", keyCode: 35, mods: []), in: window))
        XCTAssertEqual(palette.mode, .actions, "with the cover gone the same alternative opens it")
    }

    // View ▸ Show Flagged Sessions is disabled with nothing flagged, so its alternative must not switch the
    // sidebar into an empty flagged view either.
    func testFlaggedViewAlternativeStaysInertWithNothingFlaggedLikeItsMenuItem() throws {
        let fix = try fixture(keymap: "map cmd+ctrl+shift+f|ctrl+a>f toggle_flagged_view\n")
        let tail = keyDown("f", keyCode: 3, mods: [])

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(tail, in: window), "the chord is consumed either way")
        XCTAssertEqual(fix.store.sidebarMode, .tree, "an empty flagged view is what the menu item refuses")

        let workspace = try XCTUnwrap(fix.store.currentWorkspaceID)
        let session = try XCTUnwrap(fix.store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        fix.store.setFlag(true, forSession: session.id)

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(tail, in: window))
        XCTAssertEqual(fix.store.sidebarMode, .flagged, "with something to show the same alternative flips it")
    }

    // File ▸ Rename Session is disabled with no session, and its `AppActions` method is not the only thing
    // saying so: the alternative must be inert on exactly the same term the menu item spells.
    func testRenameAlternativeIsInertWithoutASessionLikeItsMenuItem() throws {
        let fix = try fixture(keymap: "map cmd+ctrl+shift+r|ctrl+a>r rename_session\n")
        let tail = keyDown("r", keyCode: 15, mods: [])
        fix.store.selectSession(nil)

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(tail, in: window), "the chord is consumed either way")
        XCTAssertFalse(fix.actions.renamePending, "no session is what the menu item disables on")

        let workspace = try XCTUnwrap(fix.store.currentWorkspaceID)
        let session = try XCTUnwrap(fix.store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory()))
        fix.store.selectSession(session.id)

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(tail, in: window))
        XCTAssertTrue(fix.actions.renamePending, "with a session the same alternative renames")
    }

    // File ▸ Close Session carries no modal term at all — ⌘W is how the cover itself is dismissed — while
    // View ▸ Show Sidebar carries the whole one. Under the same cover the two alternatives must part company.
    func testCloseSessionAlternativeDismissesTheCoverTheSidebarAlternativeIsBlockedBy() throws {
        let fix = try fixture(keymap: "map cmd+ctrl+shift+w|ctrl+a>w close_session\n"
            + CustomCommandRunnerTests.sidebarKeymap)
        let dashboard = try openDashboard()
        defer { dashboard.close() }

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(sidebarTail, in: window))
        XCTAssertEqual(fix.store.sidebarVisible, fix.sidebarBefore, "View ▸ Show Sidebar is disabled here")

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(keyDown("w", keyCode: 13, mods: []), in: window))
        XCTAssertFalse(dashboard.controller.isOpen, "close session reaches the grid its menu chord does")
    }

    // File ▸ Close Session closes the key window once there is no cover and no session left; an alternative
    // fired in that same zero-session window must not be swallowed and do nothing.
    func testCloseSessionAlternativeClosesTheWindowWithNothingLeftToClose() throws {
        let fix = try fixture(keymap: "map cmd+ctrl+shift+w|ctrl+a>w close_session\n")
        fix.store.selectSession(nil)
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)

        XCTAssertTrue(fix.runner.handleKeyDown(leader, in: window))
        XCTAssertTrue(fix.runner.handleKeyDown(keyDown("w", keyCode: 13, mods: []), in: window))
        XCTAssertFalse(window.isVisible, "the menu's fallback rung must be the alternative's too")
    }

    // keymap.md requires the reload path, not only a seeded file: the matcher rebuilds on
    // `.agtermKeymapChanged`, so a built-in alternative added by an edit must start firing without a restart.
    func testKeymapReloadRebindsTheBuiltinAlternatives() throws {
        let fix = try fixture(keymap: "map cmd+shift+l toggle_split\n")
        XCTAssertFalse(fix.runner.handleKeyDown(leader, in: window), "nothing is bound to ctrl+a yet")

        try write(keymap: Self.sidebarKeymap)
        fix.settings.reloadKeymap()
        // the rebuild rides a main-queue notification block, so run the loop in slices until it lands.
        let deadline = Date().addingTimeInterval(5)
        var armed = false
        while !armed, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            armed = fix.runner.handleKeyDown(leader, in: window)
        }
        XCTAssertTrue(armed, "the reloaded keymap should arm ctrl+a")

        XCTAssertTrue(fix.runner.handleKeyDown(sidebarTail, in: window))
        XCTAssertEqual(fix.store.sidebarVisible, !fix.sidebarBefore)
    }

    /// Runs `command` from `surface` and returns what it wrote, or nil if it never wrote anything. The spawn
    /// is a detached `/bin/sh`, so the file is the only channel back.
    private func fired(_ runner: CustomCommandRunner, from surface: GhosttySurfaceView,
                       writing body: String) throws -> String? {
        let probe = stateDir.appendingPathComponent("probe-\(UUID().uuidString).txt")
        runner.runFromKeybind(CustomCommand(name: "probe", command: "printf '%s' \(body) > \(probe.path)",
                                            shortcut: "ctrl+a>p"),
                              focusedSurface: surface)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if let written = try? String(contentsOf: probe, encoding: .utf8) { return written }
        }
        return nil
    }

    // #434: an overlay view is sessionless, so a chord fired inside one took the palette path's FOCUSED pane.
    func testAChordFiredInsideAPaneOverlayNamesThePaneThatOverlayCovers() throws {
        let fix = try fixture()
        let owner = try XCTUnwrap(fix.store.currentWorkspaceID)
        let session = try XCTUnwrap(fix.store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        session.splitSurface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        session.hasSplit = true
        session.isSplit = true
        session.splitFocused = true
        XCTAssertEqual(session.focusedPane, .right, "focus sits in the split, which is what makes this a trap")
        XCTAssertNil(fix.store.openPaneOverlay(session.id, pane: .left, command: "true"))
        let overlay = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        session.setPaneOverlaySurface(overlay, pane: .left)
        XCTAssertNil(overlay.session, "an overlay view is sessionless; that is what routed it to the palette path")

        let written = try fired(fix.runner, from: overlay, writing: "\"$AGT_PANE $AGT_SESSION_ID\"")

        XCTAssertEqual(written, "left \(session.id.uuidString)",
                       "the chord must name the covered pane and stay on the overlay's own session")
    }

    // the session-wide slot takes the same rung, and there it names the pane focus returns to on close.
    func testAChordFiredInsideTheSessionWideOverlayStaysOnTheFocusedPane() throws {
        let fix = try fixture()
        let owner = try XCTUnwrap(fix.store.currentWorkspaceID)
        let session = try XCTUnwrap(fix.store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let overlay = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        session.overlaySurface = overlay
        session.overlayActive = true

        XCTAssertEqual(try fired(fix.runner, from: overlay, writing: "\"$AGT_PANE\""), "left")

        session.splitSurface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        session.hasSplit = true
        session.isSplit = true
        session.splitFocused = true

        XCTAssertEqual(try fired(fix.runner, from: overlay, writing: "\"$AGT_PANE $AGT_SESSION_ID\""),
                       "right \(session.id.uuidString)", "it follows the focused pane, not a fixed left")
    }

    // `topmostSurface` puts the scratch above both panes and a pane overlay, and a session-wide overlay above
    // the scratch — so whichever overlay closes, focus returns to the scratch and the pane name would send
    // the reply into a surface the user cannot see.
    func testAChordFiredInsideAnOverlayOverAShownScratchNamesTheScratch() throws {
        let fix = try fixture()
        let owner = try XCTUnwrap(fix.store.currentWorkspaceID)
        let session = try XCTUnwrap(fix.store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        session.scratchSurface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        session.scratchActive = true

        let sessionWide = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        session.overlaySurface = sessionWide
        session.overlayActive = true
        XCTAssertEqual(try fired(fix.runner, from: sessionWide, writing: "\"$AGT_PANE\""), "scratch")

        session.overlaySurface = nil
        session.overlayActive = false
        XCTAssertNil(fix.store.openPaneOverlay(session.id, pane: .left, command: "true"))
        let paneOverlay = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        session.setPaneOverlaySurface(paneOverlay, pane: .left)
        XCTAssertEqual(try fired(fix.runner, from: paneOverlay, writing: "\"$AGT_PANE\""), "scratch")

        session.scratchActive = false
        XCTAssertEqual(try fired(fix.runner, from: paneOverlay, writing: "\"$AGT_PANE\""), "left",
                       "with the scratch hidden the pane overlay names its own pane again")
    }

    // the quick terminal is nobody's pane, so it keeps falling through to the plain active-session path.
    func testAChordFiredFromAnUnrelatedSessionlessSurfaceStillTakesTheActiveSessionPath() throws {
        let fix = try fixture()
        let owner = try XCTUnwrap(fix.store.currentWorkspaceID)
        let session = try XCTUnwrap(fix.store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let stray = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())

        let written = try fired(fix.runner, from: stray, writing: "\"$AGT_PANE $AGT_SESSION_ID\"")

        XCTAssertEqual(written, "left \(session.id.uuidString)")
    }

    func testAChordFiredInSplitPaneResolvesSplitPaneWorkingDirectory() throws {
        let fix = try fixture()
        let leftDir = stateDir.appendingPathComponent("left-cwd")
        let rightDir = stateDir.appendingPathComponent("right-cwd")
        try FileManager.default.createDirectory(at: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)

        let owner = try XCTUnwrap(fix.store.currentWorkspaceID)
        let session = try XCTUnwrap(fix.store.addSession(toWorkspace: owner, cwd: leftDir.path))
        let split = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        split.session = session
        session.splitSurface = split
        session.splitCwd = rightDir.path
        session.hasSplit = true
        session.isSplit = true
        session.splitFocused = true

        let written = try fired(fix.runner, from: split, writing: "\"$AGT_SESSION_PWD\"")
        XCTAssertEqual(written, rightDir.path)
    }
}
