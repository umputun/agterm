import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the window-scoped predicate used by both terminal focus retry loops. The
/// registry is app-side state, so this cannot live in agtermCore's host-free tests.
@MainActor
final class PickFocusGuardTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var registeredWindowIDs: Set<UUID> = []

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
        XCTAssertFalse(actions.pickActive(for: backgroundID),
                       "a pick must not suppress session-addressed focus in another window")

        controller.cancel()
        XCTAssertFalse(actions.pickActive(for: activeID))
    }

    func testMissingWindowOrRegistrationDoesNotGuardFocus() {
        XCTAssertFalse(actions.pickActive(for: nil))
        XCTAssertFalse(actions.pickActive(for: UUID()))
    }

    private func registerPick(_ windowID: UUID) -> PickController {
        let controller = PickController()
        PickRegistry.shared.register(windowID, controller: controller)
        registeredWindowIDs.insert(windowID)
        return controller
    }
}
