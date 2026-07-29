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
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            for id in registeredPickIDs {
                PickRegistry.shared.unregister(id)
            }
            for (id, window) in registeredWindows {
                WindowRegistry.shared.unregister(id)
                window.close()
            }
            registeredPickIDs.removeAll()
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
        XCTAssertEqual(
            server.pickResult("unknown", window: nil),
            ControlResponse(ok: false, error: "unknown pick: unknown")
        )
        XCTAssertEqual(
            server.cancelPick("unknown", window: nil),
            ControlResponse(ok: false, error: "unknown pick: unknown")
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

    private func registerWindow(_ id: WindowInfo.ID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        WindowRegistry.shared.register(id, window: window)
        registeredWindows[id] = window
        return window
    }
}
