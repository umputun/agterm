import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the app-side picker seam: window resolution, per-window registry lookup,
/// palette coordination, and the optional follow presentation all require the real app target.
@MainActor
final class ControlServerPickTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var server: ControlServer!
    private var registeredPickIDs: Set<WindowInfo.ID> = []
    private var registeredWindows: [WindowInfo.ID: NSWindow] = [:]
    private var registeredZoomIDs: Set<WindowInfo.ID> = []
    private var registeredDashboardIDs: Set<WindowInfo.ID> = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-pick-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
            let settings = SettingsModel(
                library: library,
                settingsStore: SettingsStore(directory: stateDir)
            )
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: settings,
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            for id in registeredPickIDs {
                PickRegistry.shared.unregister(id)
            }
            for id in registeredZoomIDs {
                TerminalZoomRegistry.shared.unregister(id)
            }
            for id in registeredDashboardIDs {
                DashboardControllerRegistry.shared.unregister(id)
            }
            for (id, window) in registeredWindows {
                WindowRegistry.shared.unregister(id)
                window.close()
            }
            registeredPickIDs.removeAll()
            registeredZoomIDs.removeAll()
            registeredDashboardIDs.removeAll()
            registeredWindows.removeAll()
            server = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testOpenRejectsWhenNoWindowIsOpen() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        library.closeWindow(windowID)

        XCTAssertEqual(
            server.openPick(makePick("pick"), window: nil, follow: false),
            ControlResponse(ok: false, error: "no open window")
        )
    }

    func testOpenRejectsWhenTargetWindowHasNoRegisteredPickSurface() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)

        XCTAssertEqual(
            server.openPick(makePick("pick"), window: windowID.uuidString, follow: false),
            ControlResponse(ok: false, error: "no pick surface")
        )
    }

    func testOpenRejectsSecondPendingPickWithoutReplacingFirst() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = registerPick(windowID)
        let first = makePick("first")
        XCTAssertTrue(controller.open(first))

        XCTAssertEqual(
            server.openPick(makePick("second"), window: nil, follow: false),
            ControlResponse(ok: false, error: "pick already pending")
        )
        XCTAssertEqual(controller.pending, first)
    }

    func testOpenOnFrontmostWindowClosesBuiltInPaletteAndReturnsID() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = registerPick(windowID)
        let palette = PaletteController()
        palette.open(.actions)
        actions.palette = palette
        let pick = makePick("frontmost")

        XCTAssertEqual(
            server.openPick(pick, window: nil, follow: false),
            ControlResponse(ok: true, result: ControlResult(id: pick.id))
        )
        XCTAssertEqual(controller.pending, pick)
        XCTAssertNil(palette.mode)
    }

    func testBackgroundOpenWithoutFollowLeavesWindowAndPaletteAlone() throws {
        let backgroundID = try XCTUnwrap(library.activeWindowID)
        let controller = registerPick(backgroundID)
        let frontmostID = library.newWindow(name: "frontmost").id
        let palette = PaletteController()
        palette.open(.actions)
        actions.palette = palette
        let pick = makePick("background")

        XCTAssertEqual(
            server.openPick(pick, window: backgroundID.uuidString, follow: false),
            ControlResponse(ok: true, result: ControlResult(id: pick.id))
        )
        XCTAssertEqual(controller.pending, pick)
        XCTAssertEqual(library.activeWindowID, frontmostID)
        XCTAssertEqual(palette.mode, .actions)
    }

    func testFollowRaisesSelectsAndClosesPaletteForBackgroundWindow() throws {
        let targetID = try XCTUnwrap(library.activeWindowID)
        let controller = registerPick(targetID)
        _ = library.newWindow(name: "frontmost")
        let palette = PaletteController()
        palette.open(.sessions)
        actions.palette = palette
        let window = registerWindow(targetID)
        let pick = makePick("followed")

        XCTAssertEqual(
            server.openPick(pick, window: targetID.uuidString, follow: true),
            ControlResponse(ok: true, result: ControlResult(id: pick.id))
        )
        XCTAssertEqual(controller.pending, pick)
        XCTAssertEqual(library.frontmostWindowID, targetID)
        XCTAssertTrue(window.isVisible)
        XCTAssertNil(palette.mode)
    }

    func testResultAndCancelAreScopedToRegisteredWindowController() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = registerPick(windowID)
        let pick = makePick("result")
        XCTAssertTrue(controller.open(pick))

        XCTAssertEqual(
            server.pickResult(pick.id, window: nil),
            ControlResponse(
                ok: true,
                result: ControlResult(pick: ControlPickResult(result: .pending))
            )
        )
        XCTAssertEqual(server.cancelPick(pick.id, window: nil), ControlResponse(ok: true))
        XCTAssertEqual(
            server.pickResult(pick.id, window: nil),
            ControlResponse(
                ok: true,
                result: ControlResult(pick: ControlPickResult(result: .cancelled))
            )
        )
        let resultBeforeUnknownRequests = controller.recentResults
        XCTAssertEqual(
            server.pickResult("unknown", window: nil),
            ControlResponse(ok: false, error: "unknown pick: unknown")
        )
        XCTAssertEqual(
            server.cancelPick("unknown", window: nil),
            ControlResponse(ok: false, error: "unknown pick: unknown")
        )
        XCTAssertEqual(
            controller.recentResults,
            resultBeforeUnknownRequests,
            "unknown result/cancel requests must not mutate the retained picker results"
        )
    }

    func testUntargetedResultAndCancelFollowPickIDAcrossFrontmostChange() throws {
        let ownerID = try XCTUnwrap(library.activeWindowID)
        let owner = registerPick(ownerID)
        let pick = makePick("globally-routed")
        XCTAssertTrue(owner.open(pick))

        let otherID = library.newWindow(name: "other").id
        _ = registerPick(otherID)
        XCTAssertEqual(library.activeWindowID, otherID)

        XCTAssertEqual(
            server.pickResult(pick.id, window: nil),
            ControlResponse(ok: true, result: ControlResult(
                pick: ControlPickResult(result: .pending)
            ))
        )
        XCTAssertEqual(server.cancelPick(pick.id, window: nil), ControlResponse(ok: true))
        XCTAssertEqual(
            server.pickResult(pick.id, window: nil),
            ControlResponse(ok: true, result: ControlResult(
                pick: ControlPickResult(result: .cancelled)
            ))
        )
    }

    func testPendingPickRejectsControlDrivenCoversButAllowsDismissals() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let pick = registerPick(windowID)
        XCTAssertTrue(pick.open(makePick("modal-owner")))

        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        registeredZoomIDs.insert(windowID)
        let dashboard = DashboardController()
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        registeredDashboardIDs.insert(windowID)
        let sessionID = try XCTUnwrap(library.activeStore?.activeSession?.id)

        XCTAssertEqual(
            server.setQuickTerminal(mode: "show"),
            ControlResponse(ok: false, error: "pick pending")
        )
        XCTAssertEqual(
            server.setSurfaceZoom(nil, window: windowID.uuidString, mode: .on),
            ControlResponse(ok: false, error: "pick pending")
        )
        XCTAssertEqual(
            server.setDashboard(
                targets: [sessionID.uuidString],
                window: windowID.uuidString,
                close: false,
                fontMode: .untouched,
                mru: false
            ),
            ControlResponse(ok: false, error: "pick pending")
        )

        XCTAssertEqual(server.setQuickTerminal(mode: "hide"), ControlResponse(ok: true))
        XCTAssertEqual(
            server.setSurfaceZoom(nil, window: windowID.uuidString, mode: .off),
            ControlResponse(ok: true)
        )
        XCTAssertEqual(
            server.setDashboard(
                targets: [],
                window: windowID.uuidString,
                close: true,
                fontMode: .untouched,
                mru: false
            ),
            ControlResponse(ok: true)
        )
    }

    func testPendingPickRejectsControlSearchNavigationButAllowsClose() async throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let sessionID = try XCTUnwrap(store.activeSession?.id)
        let pick = registerPick(windowID)
        XCTAssertTrue(pick.open(makePick("search-owner")))

        let open = await server.searchSession(sessionID, store: store, text: "needle", to: nil)
        XCTAssertEqual(open, ControlResponse(ok: false, error: "pick pending"))

        let navigate = await server.searchSession(sessionID, store: store, text: nil, to: "next")
        XCTAssertEqual(navigate, ControlResponse(ok: false, error: "pick pending"))

        let close = await server.searchSession(sessionID, store: store, text: nil, to: "close")
        XCTAssertEqual(close, ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString)))
    }

    func testCloseSessionChordCancelsPickAheadOfTerminalZoom() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let controller = registerPick(windowID)
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(windowID, controller: zoom)
        registeredZoomIDs.insert(windowID)
        let pick = makePick("command-w")
        XCTAssertTrue(controller.open(pick))
        zoom.set(.on, target: .session(session.id, .primary))

        XCTAssertTrue(actions.closeActiveSession())

        XCTAssertEqual(
            controller.result(for: pick.id),
            ControlPickResult(result: .cancelled)
        )
        XCTAssertEqual(
            zoom.target,
            .session(session.id, .primary),
            "the terminal zoom behind a pending pick must survive the first close-session chord"
        )
    }

    func testWindowCloseResolvesPendingPickAsCancelled() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = registerPick(windowID)
        let window = try registerLifecycleWindow(windowID)
        let pick = makePick("window-close")
        XCTAssertTrue(controller.open(pick))

        window.close()

        XCTAssertFalse(library.isOpen(windowID))
        XCTAssertNil(PickRegistry.shared.controller(for: windowID))
        XCTAssertEqual(
            server.pickResult(pick.id, window: windowID.uuidString),
            ControlResponse(
                ok: true,
                result: ControlResult(pick: ControlPickResult(result: .cancelled))
            ),
            "a poll after the real window-close path must still observe the terminal cancellation"
        )
        let otherID = library.newWindow(name: "other").id
        XCTAssertEqual(
            server.pickResult(pick.id, window: otherID.uuidString),
            ControlResponse(ok: false, error: "unknown pick: \(pick.id)"),
            "an explicit window selector must match the retained pick's owner"
        )
    }

    func testNextOpenKeepsClosedWindowRetainedResultReadable() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let firstController = registerPick(windowID)
        let first = makePick("old-closed-pick")
        XCTAssertTrue(firstController.open(first))
        PickRegistry.shared.unregister(windowID)
        registeredPickIDs.remove(windowID)

        let replacement = registerPick(windowID)
        let next = makePick("next-pick")
        XCTAssertEqual(
            server.openPick(next, window: windowID.uuidString, follow: false),
            ControlResponse(ok: true, result: ControlResult(id: next.id))
        )
        XCTAssertEqual(replacement.pending, next)
        XCTAssertEqual(
            server.pickResult(first.id, window: nil),
            ControlResponse(ok: true, result: ControlResult(pick: ControlPickResult(result: .cancelled))),
            "a later pick reusing that window must not erase an answer its own poller has not read yet"
        )
    }

    func testResolvedPickStaysReadableAfterTheNextPickOpens() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let controller = registerPick(windowID)
        let first = makePick("answered")
        XCTAssertTrue(controller.open(first))
        let answer = ControlPickResult(result: .picked, id: "one", label: "One", index: 0)
        controller.resolve(answer)

        let second = makePick("opened-before-the-poll-landed")
        XCTAssertEqual(
            server.openPick(second, window: nil, follow: false),
            ControlResponse(ok: true, result: ControlResult(id: second.id))
        )

        XCTAssertEqual(
            server.pickResult(first.id, window: nil),
            ControlResponse(ok: true, result: ControlResult(pick: answer)),
            "a blocking caller must still read its own answer when another pick opened before its poll landed"
        )
        XCTAssertEqual(
            server.pickResult(second.id, window: nil),
            ControlResponse(ok: true, result: ControlResult(pick: ControlPickResult(result: .pending)))
        )
    }

    func testApplicationTerminationCancelsEveryPendingPickWithoutChangingQuitCounts() throws {
        let firstID = try XCTUnwrap(library.activeWindowID)
        let first = registerPick(firstID)
        let secondID = library.newWindow(name: "second").id
        let second = registerPick(secondID)
        let firstPick = makePick("quit-first")
        let secondPick = makePick("quit-second")
        XCTAssertTrue(first.open(firstPick))
        XCTAssertTrue(second.open(secondPick))
        let countsBeforeTermination = library.openCounts()

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)

        XCTAssertEqual(first.result(for: firstPick.id), ControlPickResult(result: .cancelled))
        XCTAssertEqual(second.result(for: secondPick.id), ControlPickResult(result: .cancelled))
        let countsAfterTermination = library.openCounts()
        XCTAssertEqual(
            countsAfterTermination.windows,
            countsBeforeTermination.windows,
            "picker cancellation must not affect the window count that drives quit confirmation"
        )
        XCTAssertEqual(
            countsAfterTermination.sessions,
            countsBeforeTermination.sessions,
            "picker cancellation must not affect the session count that drives quit confirmation"
        )
    }

    private func makePick(_ id: String) -> PendingPick {
        PendingPick(id: id, items: [ControlPickItem(id: "item", label: "Item")])
    }

    private func registerPick(_ id: WindowInfo.ID) -> PickController {
        let controller = PickController()
        PickRegistry.shared.register(id, controller: controller)
        registeredPickIDs.insert(id)
        return controller
    }

    /// `NSWindow`'s designated initializer defaults `isReleasedWhenClosed` to true, so `close()` sends a
    /// release ARC never balances while this test still holds the window (here and in `WindowRegistry`).
    /// The over-release frees it under the surviving references, and the next autorelease-pool pop on the
    /// main queue crashes the test HOST rather than failing a test — nondeterministically, which is why it
    /// only showed up on CI. Every window these tests own is closed in teardown, so all of them opt out.
    private func registerWindow(_ id: WindowInfo.ID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(id, window: window)
        registeredWindows[id] = window
        return window
    }

    private func registerLifecycleWindow(_ id: WindowInfo.ID) throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let store = try XCTUnwrap(library.store(for: id))
        window.contentView = WindowAccessor.TitleProbeView(windowID: id, library: library, store: store)
        registeredWindows[id] = window
        return window
    }
}
