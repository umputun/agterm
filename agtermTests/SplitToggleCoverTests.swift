import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `AppActions.toggleSplit`'s cover rung — ⌘D / the toolbar button / View ▸ Split /
/// the palette all funnel through it — and for `closeSplit`, the palette's teardown beside it.
/// Lives here rather than in `agtermUITests` for the same reasons as
/// `SessionNavRevealTests`: it reaches `AppActions` through `@testable import agterm`, observes MODEL flags
/// (`isSplit`, `scratchActive`) that need no terminal surface, and runs on every push via `scripts/test-app.sh`.
@MainActor
final class SplitToggleCoverTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-split-cover-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func activeSession() throws -> Session {
        let store = try XCTUnwrap(library.activeStore)
        return try XCTUnwrap(store.activeSession)
    }

    func testUncoveredSessionStillSplits() throws {
        let session = try activeSession()

        actions.toggleSplit()

        XCTAssertTrue(session.isSplit, "the cover rung must not disarm the ordinary split toggle")
        XCTAssertTrue(session.hasSplit)
    }

    func testShownScratchIsDismissedInsteadOfSplitting() throws {
        let session = try activeSession()
        session.scratchActive = true

        actions.toggleSplit()

        XCTAssertFalse(session.scratchActive, "⌘D over the scratch is the way back to the panes")
        XCTAssertFalse(session.hasSplit, "no split may be created behind the cover")
    }

    // the layout the user left must be the one he comes back to: a shown split stays shown.
    func testDismissingTheScratchLeavesAShownSplitAlone() throws {
        let session = try activeSession()
        actions.toggleSplit()
        session.scratchActive = true

        actions.toggleSplit()

        XCTAssertFalse(session.scratchActive)
        XCTAssertTrue(session.isSplit, "the split must survive the press that dismissed the scratch")
    }

    // a second press, now uncovered, is an ordinary toggle again — so the rung is a detour, not a swap.
    func testPressAfterTheScratchIsGoneSplits() throws {
        let session = try activeSession()
        session.scratchActive = true

        actions.toggleSplit()
        actions.toggleSplit()

        XCTAssertFalse(session.scratchActive)
        XCTAssertTrue(session.isSplit)
    }

    func testFullOverlayMakesThePressInert() throws {
        let session = try activeSession()
        session.overlayActive = true
        session.overlaySizePercent = nil
        session.scratchActive = true

        actions.toggleSplit()

        XCTAssertTrue(session.scratchActive, "a full overlay hides the scratch too, so it is not what ⌘D dismisses")
        XCTAssertFalse(session.hasSplit, "the panes are invisible under a full overlay and must not be rearranged")
    }

    func testFloatingOverlayLeavesThePanesReachable() throws {
        let session = try activeSession()
        session.overlayActive = true
        session.overlaySizePercent = 40

        actions.toggleSplit()

        XCTAssertTrue(session.isSplit, "a floating panel leaves the panes on screen, so the toggle is visible")
    }

    // a HUD is a message, not a cover: `fullOverlayActive` excludes it even with no size percent.
    func testHudLeavesThePanesReachable() throws {
        let session = try activeSession()
        session.overlayActive = true
        session.overlaySizePercent = nil
        session.hudSpec = HudSpec(message: "gathering options…", position: .center)

        actions.toggleSplit()

        XCTAssertTrue(session.isSplit)
    }

    func testCloseSplitTearsTheShownPaneDown() throws {
        let session = try activeSession()
        actions.toggleSplit()
        session.splitRatio = 0.7

        actions.closeSplit()

        XCTAssertFalse(session.isSplit)
        XCTAssertFalse(session.hasSplit, "closing is what clears the flag a hide leaves set")
        XCTAssertFalse(session.splitFocused)
        XCTAssertNil(session.splitRatio)
    }

    func testCloseSplitReachesAHiddenPane() throws {
        let session = try activeSession()
        actions.toggleSplit()
        actions.toggleSplit()
        XCTAssertFalse(session.isSplit)
        XCTAssertTrue(session.hasSplit)

        actions.closeSplit()

        XCTAssertFalse(session.hasSplit)
    }

    func testCloseSplitWithoutASplitLeavesEveryOtherSessionAlone() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let sibling = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(sibling.id)
        actions.toggleSplit()
        let plain = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(plain.id)

        actions.closeSplit()

        XCTAssertTrue(sibling.hasSplit, "the split belongs to another session and must survive")
        XCTAssertNotNil(store.session(withID: plain.id), "an inert action must not remove the session")
        XCTAssertEqual(store.selectedSessionID, plain.id)
        XCTAssertFalse(plain.hasSplit)
    }

    func testShownScratchIsDismissedInsteadOfClosingTheSplit() throws {
        let session = try activeSession()
        actions.toggleSplit()
        session.scratchActive = true

        actions.closeSplit()

        XCTAssertFalse(session.scratchActive, "the cover goes first, as it does for ⌘D and ⌘W")
        XCTAssertTrue(session.hasSplit, "a live pane must not be destroyed behind a cover that hides it")
    }

    func testPressAfterTheScratchIsGoneClosesTheSplit() throws {
        let session = try activeSession()
        actions.toggleSplit()
        session.scratchActive = true

        actions.closeSplit()
        actions.closeSplit()

        XCTAssertFalse(session.scratchActive)
        XCTAssertFalse(session.hasSplit)
    }

    func testFullOverlayMakesCloseSplitInert() throws {
        let session = try activeSession()
        actions.toggleSplit()
        session.overlayActive = true
        session.overlaySizePercent = nil

        actions.closeSplit()

        XCTAssertTrue(session.hasSplit, "the panes are invisible under a full overlay and must not be torn down")
    }
}
