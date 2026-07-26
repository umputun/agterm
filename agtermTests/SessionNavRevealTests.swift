import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the plain-session-nav pane reveal (`AppActions.navigatePlain(_:)`). This lives in
/// the app-hosted target rather than `agtermUITests` on purpose: it reaches `AppActions` directly through
/// `@testable import agterm`, needs no terminal surface to observe the outcome (the reveal's `.left`/nil
/// arm writes the MODEL flag `splitFocused` before it ever touches first responder), and — unlike the
/// XCUITest suite, which CI does not run — it runs on every push via `scripts/test-app.sh`.
@MainActor
final class SessionNavRevealTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-session-nav-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    // A plain nav step that resolves to the session ALREADY selected must not run the pane reveal. `next`
    // wraps within the filtered set, so a one-element set re-selects the current session, and
    // `selectSession` does not short-circuit a same-target select — it still returns an indicator. Revealing
    // on that indicator would clear `splitFocused` and pull the user onto the primary pane on a keystroke
    // that moved nothing. An UNTAGGED `blocked` is the shape a plain `agtermctl session status blocked`
    // sends and routes to the `.left`/nil arm, which is the arm that does the clearing.
    func testPlainNavThatMovesNothingKeepsSplitFocus() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        XCTAssertEqual(store.navigableSessions.count, 1, "the wrap-onto-self case needs a one-element set")

        session.agentIndicator = AgentIndicator(status: .blocked)
        session.splitFocused = true

        actions.selectNextSession()

        XCTAssertEqual(store.selectedSessionID, session.id, "wrapping in a one-element set re-selects it")
        XCTAssertTrue(session.splitFocused,
                      "a nav step that moved nothing must leave the user on the split pane he was typing in")
    }

    // The other direction, so the test above cannot pass by the reveal being dead everywhere: a step that
    // DOES move still reveals the moved-to session's tagged pane. Same untagged `blocked` shape, so the
    // same `.left`/nil arm runs — here it should clear `splitFocused`, targeting the primary pane.
    func testPlainNavThatMovesRunsTheReveal() throws {
        let store = try XCTUnwrap(library.activeStore)
        let first = try XCTUnwrap(store.activeSession)
        let workspaceID = try XCTUnwrap(store.currentWorkspaceID)
        let second = try XCTUnwrap(store.addSession(toWorkspace: workspaceID, cwd: NSHomeDirectory()))

        second.agentIndicator = AgentIndicator(status: .blocked)
        second.splitFocused = true
        store.selectSession(first.id)
        XCTAssertEqual(store.navigableSessions.count, 2)

        actions.selectNextSession()

        XCTAssertEqual(store.selectedSessionID, second.id, "the step should move to the second session")
        XCTAssertFalse(second.splitFocused,
                       "a step that moved should reveal the untagged block's primary pane")
    }
}
