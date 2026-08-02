import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `ControlServer`'s session actions, which need the real app target for window
/// resolution and the store registry.
@MainActor
final class ControlServerSessionActionsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-session-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            let actions = AppActions(library: library)
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    private func overlayOptions(follow: Bool, pane: OverlayPane? = nil) -> ControlSessionOverlayOpenOptions {
        ControlSessionOverlayOpenOptions(command: "true", cwd: nil, wait: false, sizePercent: nil,
                                         backgroundColor: nil, follow: follow, pane: pane)
    }

    func testFollowSelectsTheTargetWhenNothingIsSelected() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(nil)

        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                 options: overlayOptions(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    // --follow is documented as a no-op when its target is already active, and it stays one only because
    // a same-value selection leaves the fresh-workspace target alone.
    func testFollowOnTheAlreadyActiveSessionKeepsTheFreshWorkspaceCurrent() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(session.id)
        let fresh = store.addWorkspace(name: "fresh")

        let response = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                 options: overlayOptions(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, session.id)
        XCTAssertEqual(store.currentWorkspaceID, fresh.id, "an already-active follow must not retarget")
    }

    func testFollowOnAnotherSessionSelectsItAndDropsTheFreshWorkspace() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let first = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        let second = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(second.id)
        store.addWorkspace(name: "fresh")

        let response = server.openSessionOverlay(first.id.uuidString, window: nil,
                                                 options: overlayOptions(follow: true))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(store.selectedSessionID, first.id)
        XCTAssertEqual(store.currentWorkspaceID, owner)
    }

    // pins #349. A store-only session never gets a view, so its surface stays nil and the poll always runs
    // to exhaustion — which is what makes this deterministic where the e2e version is not. The pre-#349 code
    // returned "session not realized; use select" immediately; both the wire string and the elapsed time
    // discriminate, so restoring the `guard select` fails on the string and dropping the sleep fails on time.
    // The target is created unselected and a SECOND session holds the selection, so making the select
    // unconditional fails the last assertion; the companion below pins the other side of that branch.
    func testTypeWithoutSelectPollsInsteadOfDemandingSelect() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory(), select: false))
        let other = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(other.id)

        let started = Date()
        let response = await server.injectText("ls\n", into: target.id, store: store, select: false, pane: nil)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(response.ok, "a surface that never comes up must not report a false ok")
        XCTAssertEqual(response.error, "session not realized", "the no-select path no longer tells callers to select")
        XCTAssertGreaterThan(elapsed, 0.3, "it should ride out the full 12 x 30ms realize poll, not fast-fail")
        XCTAssertEqual(store.selectedSessionID, other.id, "typing without select must leave the selection where it was")
    }

    // the true side of that branch: deleting the body of `if select` leaves every other test green while
    // `--select` silently stops selecting, so this asserts the move itself rather than the typed text.
    func testTypeWithSelectStillSelectsWhenTheSurfaceIsNotReady() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let target = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory(), select: false))
        let other = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))
        store.selectSession(other.id)

        let response = await server.injectText("ls\n", into: target.id, store: store, select: true, pane: nil)

        XCTAssertFalse(response.ok, "a store-only session never realizes, so the poll still runs out")
        XCTAssertEqual(store.selectedSessionID, target.id, "--select must select the target when its surface is not up")
    }

    // the two pane rejections come back from the store as an enum this arm maps to wire strings; without
    // asserting both here, swapping the arms of `paneOverlayFailure` leaves every other test green.
    func testPaneOverlayOpenReportsEachRejectionByItsOwnError() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))

        let opened = server.openSessionOverlay(session.id.uuidString, window: nil,
                                               options: overlayOptions(follow: false, pane: .left))
        XCTAssertTrue(opened.ok, opened.error ?? "")

        let again = server.openSessionOverlay(session.id.uuidString, window: nil,
                                              options: overlayOptions(follow: false, pane: .left))
        XCTAssertFalse(again.ok)
        XCTAssertEqual(again.error, "pane overlay already open")

        // the right pane is not laid out on an unsplit session, so its overlay would never realize a surface.
        let unrendered = server.openSessionOverlay(session.id.uuidString, window: nil,
                                                   options: overlayOptions(follow: false, pane: .right))
        XCTAssertFalse(unrendered.ok)
        XCTAssertEqual(unrendered.error, "pane not visible")
    }

    // the pane arm of session.overlay.result: both failure branches, which the hosted e2e only covers on the
    // success path, and the session-wide slot staying untouched by either.
    func testPaneOverlayResultReportsRunningThenMissingThenTheCode() throws {
        let store = try XCTUnwrap(library.activeStore)
        let owner = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: owner, cwd: NSHomeDirectory()))

        let never = server.sessionOverlayResult(session.id.uuidString, window: nil, pane: .left)
        XCTAssertFalse(never.ok)
        XCTAssertEqual(never.error, "no overlay result", "a pane that never ran one has no result")

        XCTAssertNil(store.openPaneOverlay(session.id, pane: .left, command: "true"))
        let running = server.sessionOverlayResult(session.id.uuidString, window: nil, pane: .left)
        XCTAssertFalse(running.ok)
        XCTAssertEqual(running.error, "overlay still running")

        store.recordPaneOverlayExit(session.id, pane: .left, code: 3)
        XCTAssertTrue(store.closePaneOverlay(session.id, pane: .left))
        let done = server.sessionOverlayResult(session.id.uuidString, window: nil, pane: .left)
        XCTAssertTrue(done.ok, done.error ?? "")
        XCTAssertEqual(done.result?.exitCode, 3)

        let sessionWide = server.sessionOverlayResult(session.id.uuidString, window: nil, pane: nil)
        XCTAssertFalse(sessionWide.ok)
        XCTAssertEqual(sessionWide.error, "no overlay result", "a pane overlay must not fill the session slot")
    }
}
