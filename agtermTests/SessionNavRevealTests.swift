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

    // `next` wraps within the filtered set, so a one-element set re-selects the current session, and
    // `selectSession` does not short-circuit a same-target select — it still returns an indicator, and
    // revealing on it would clear `splitFocused` on a keystroke that moved nothing. An UNTAGGED `blocked`
    // routes to the `.left`/nil arm, the arm that does the clearing.
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

    // the other direction, so the test above cannot pass by the reveal being dead everywhere: the same
    // untagged `blocked` shape runs the same `.left`/nil arm, which here must clear `splitFocused`.
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

    // workspace nav has to route pane reveal exactly as session nav does, which is only true while
    // `selectWorkspace` returns the destination's indicator AND `selectNextWorkspace` hands it on. Both are
    // invisible to a test asserting selection alone: passing nil still selects the right session, and only
    // the reveal's `.left`/nil arm clears `splitFocused`.
    func testWorkspaceNavRunsTheRevealOnTheStepsIndicator() throws {
        let store = try XCTUnwrap(library.activeStore)
        let first = try XCTUnwrap(store.activeSession)
        let second = store.addWorkspace(name: "second")
        let away = try XCTUnwrap(store.addSession(toWorkspace: second.id, cwd: NSHomeDirectory()))

        store.selectSession(first.id)
        away.agentIndicator = AgentIndicator(status: .blocked)
        away.splitFocused = true

        actions.selectNextWorkspace()

        XCTAssertEqual(store.selectedSessionID, away.id, "the step should land on the next workspace's first session")
        XCTAssertFalse(away.splitFocused, "the step must reveal the untagged block's primary pane")
    }

    // the auto-reset case is what makes the indicator have to travel WITH the step: selecting the session
    // clears its status, so an `AppActions` that read the indicator back off the store afterwards would see
    // idle and skip the reveal entirely.
    func testWorkspaceNavRevealsAnAutoResetStatusClearedByTheSelect() throws {
        let store = try XCTUnwrap(library.activeStore)
        let first = try XCTUnwrap(store.activeSession)
        let second = store.addWorkspace(name: "second")
        let away = try XCTUnwrap(store.addSession(toWorkspace: second.id, cwd: NSHomeDirectory()))

        // the status goes on AFTER the selection settles: creating a session selects it, and selecting away
        // from an auto-reset session is itself one of the two clears, so seeding it earlier would arrive idle
        store.selectSession(first.id)
        away.agentIndicator = AgentIndicator(status: .completed, autoReset: true)
        away.splitFocused = true

        actions.selectNextWorkspace()

        XCTAssertEqual(store.selectedSessionID, away.id, "the step should land on the next workspace's first session")
        XCTAssertEqual(away.agentIndicator.status, .idle, "selecting an auto-reset session clears its status")
        XCTAssertFalse(away.splitFocused, "the reveal must run off the indicator captured BEFORE that clear")
    }
}
