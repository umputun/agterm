import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the guards on the terminal focus retry loops: the window-scoped picker predicate
/// both loops read, and the selection gate that keeps a control-addressed background session from taking
/// first responder. The registries and the window library are app-side state, so this cannot live in
/// agtermCore's host-free tests.
@MainActor
final class PickFocusGuardTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var registeredWindowIDs: Set<UUID> = []
    private var registeredWindows: [UUID: NSWindow] = [:]

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-pick-focus-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            for id in registeredWindowIDs {
                PickRegistry.shared.unregister(id)
            }
            for (id, window) in registeredWindows {
                WindowRegistry.shared.unregister(id)
                window.orderOut(nil)
            }
            registeredWindows.removeAll()
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testPendingPickGuardsOnlyItsOwningWindow() throws {
        let activeID = try XCTUnwrap(library.activeWindowID)
        let backgroundID = library.newWindow(name: "background").id
        let controller = registerPick(activeID)

        XCTAssertFalse(actions.pickActive(for: activeID))
        XCTAssertFalse(actions.pickActive(for: backgroundID))

        XCTAssertTrue(controller.open(PendingPick(
            id: "focus-guard",
            items: [ControlPickItem(id: "one", label: "One")]
        )))

        XCTAssertTrue(actions.pickActive(for: activeID))
        XCTAssertFalse(actions.uiActionsEnabled(for: activeID),
                       "a pending picker must participate in the shared modal action gate")
        XCTAssertFalse(actions.pickActive(for: backgroundID),
                       "a pick must not suppress session-addressed focus in another window")

        controller.cancel()
        XCTAssertFalse(actions.pickActive(for: activeID))
    }

    func testMissingWindowOrRegistrationDoesNotGuardFocus() {
        XCTAssertFalse(actions.pickActive(for: nil))
        XCTAssertFalse(actions.pickActive(for: UUID()))
    }

    func testSelectionGuardReadsTheSessionsOwnWindowNotTheFrontmostOne() throws {
        let frontStore = try XCTUnwrap(library.activeStore)
        let frontWorkspace = try XCTUnwrap(frontStore.currentWorkspaceID)
        let front = try XCTUnwrap(frontStore.addSession(toWorkspace: frontWorkspace, cwd: NSHomeDirectory()))
        frontStore.selectSession(front.id)

        let backgroundID = library.newWindow(name: "background").id
        let backStore = try XCTUnwrap(library.store(for: backgroundID))
        let backWorkspace = try XCTUnwrap(backStore.currentWorkspaceID)
        let shown = try XCTUnwrap(backStore.addSession(toWorkspace: backWorkspace, cwd: NSHomeDirectory()))
        let hidden = try XCTUnwrap(backStore.addSession(toWorkspace: backWorkspace, cwd: NSHomeDirectory()))
        backStore.selectSession(shown.id)

        XCTAssertTrue(actions.sessionIsSelected(front))
        XCTAssertTrue(actions.sessionIsSelected(shown),
                      "selected in its own window is enough; being in a background window is not a block")
        XCTAssertFalse(actions.sessionIsSelected(hidden),
                       "a mounted-but-hidden session must not take first responder")

        backStore.selectSession(hidden.id)
        XCTAssertTrue(actions.sessionIsSelected(hidden))
        XCTAssertFalse(actions.sessionIsSelected(shown), "the guard follows the selection, both ways")
    }

    func testSelectionGuardDoesNotBlockASessionWithNoResolvableWindow() {
        let orphan = Session(initialCwd: NSHomeDirectory())

        XCTAssertTrue(actions.sessionIsSelected(orphan),
                      "unresolvable ownership must not block, matching the window-scoped cover gates")
    }

    func testTerminalRetryGuardTracksPickerForOwningAppKitWindow() throws {
        let ownerID = try XCTUnwrap(library.activeWindowID)
        let otherID = library.newWindow(name: "other").id
        let ownerWindow = registerWindow(ownerID)
        let otherWindow = registerWindow(otherID)
        let controller = registerPick(ownerID)

        XCTAssertFalse(GhosttySurfaceView.pickOwnsFocus(in: ownerWindow))
        XCTAssertTrue(controller.open(PendingPick(
            id: "in-flight-focus",
            items: [ControlPickItem(id: "one", label: "One")]
        )))

        XCTAssertTrue(GhosttySurfaceView.pickOwnsFocus(in: ownerWindow),
                      "an already-running focus retry must stop once this window gains a picker")
        XCTAssertFalse(GhosttySurfaceView.pickOwnsFocus(in: otherWindow),
                       "a picker must not stop a retry in another window")
        XCTAssertFalse(GhosttySurfaceView.pickOwnsFocus(in: nil))
    }

    func testDeferredPickFocusRestorationWaitsForOwningWindowToBecomeFrontmost() {
        var state = PickFocusRestorationState()

        XCTAssertFalse(state.pickerResolved(isFrontmost: false),
                       "resolving a background picker must not steal focus")
        XCTAssertTrue(state.isDeferred)
        XCTAssertFalse(state.windowBecameFrontmost(pickPending: true),
                       "a replacement picker must retain focus when the window activates")
        XCTAssertTrue(state.isDeferred)
        XCTAssertTrue(state.windowBecameFrontmost(pickPending: false),
                      "the owning window should restore its underlying cover once it is frontmost")
        XCTAssertFalse(state.isDeferred)
        XCTAssertFalse(state.windowBecameFrontmost(pickPending: false),
                       "the deferred restoration must be consumed exactly once")
    }

    private func registerPick(_ windowID: UUID) -> PickController {
        let controller = PickController()
        PickRegistry.shared.register(windowID, controller: controller)
        registeredWindowIDs.insert(windowID)
        return controller
    }

    /// Opt out of `isReleasedWhenClosed` for the same reason `ControlServerPickTests` does: this suite only
    /// hides its windows today, but a window it holds must not be released out from under ARC if one ever
    /// gets closed.
    private func registerWindow(_ windowID: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(windowID, window: window)
        registeredWindows[windowID] = window
        return window
    }
}
