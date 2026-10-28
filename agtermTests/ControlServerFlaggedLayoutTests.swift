import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerFlaggedLayoutTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-flagged-layout-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            let actions = AppActions(library: library)
            server = ControlServer(
                library: library,
                actions: actions,
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            GhosttyApp.shared.setFlaggedViewLayout(.flat)
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testSetsTheLayoutPersistsItAndEchoesTheResult() {
        let response = server.setFlaggedViewLayout(.tree)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(text: "tree")))
        XCTAssertEqual(GhosttyApp.shared.flaggedViewLayout, .tree)
        XCTAssertEqual(SettingsStore(directory: stateDir).load().flaggedViewLayout, "tree")
    }

    func testToggleResolvesFromTheCurrentLayoutBothWays() {
        XCTAssertEqual(server.setFlaggedViewLayout(.toggle).result?.text, "tree")
        XCTAssertEqual(server.setFlaggedViewLayout(.toggle).result?.text, "flat")
        XCTAssertEqual(GhosttyApp.shared.flaggedViewLayout, .flat)
    }

    func testSetsThePlainLayout() {
        let response = server.setFlaggedViewLayout(.plain)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(text: "plain")))
        XCTAssertEqual(GhosttyApp.shared.flaggedViewLayout, .plain)
        XCTAssertEqual(SettingsStore(directory: stateDir).load().flaggedViewLayout, "plain")
    }

    func testToggleLeavesThePlainLayoutForTheTreeAndReturnsToFlat() {
        _ = server.setFlaggedViewLayout(.plain)

        XCTAssertEqual(server.setFlaggedViewLayout(.toggle).result?.text, "tree")
        XCTAssertEqual(server.setFlaggedViewLayout(.toggle).result?.text, "flat")
    }

    func testAnUnchangedLayoutAnswersOkWithoutABroadcast() {
        let posted = expectation(forNotification: .agtermAppearanceChanged, object: nil)
        posted.isInverted = true

        let response = server.setFlaggedViewLayout(.flat)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(text: "flat")))
        wait(for: [posted], timeout: 0.3)
    }

    func testNeedsNoOpenWindow() throws {
        library.closeWindow(try XCTUnwrap(library.activeWindowID))
        XCTAssertNil(library.activeStore)

        XCTAssertEqual(server.setFlaggedViewLayout(.tree).result?.text, "tree")
        XCTAssertEqual(GhosttyApp.shared.flaggedViewLayout, .tree)
    }

    func testTreeReportsTheLayoutInBothSidebarModes() throws {
        let store = try XCTUnwrap(library.activeStore)
        XCTAssertEqual(server.buildTree(in: store).sidebarFlaggedLayout, "flat")

        _ = server.setFlaggedViewLayout(.tree)
        XCTAssertEqual(server.buildTree(in: store).sidebarFlaggedLayout, "tree")

        store.setSidebarMode(.flagged)
        XCTAssertEqual(server.buildTree(in: store).sidebarFlaggedLayout, "tree")
    }

    private func flaggedSessions(in store: AppStore, _ names: [String]) throws -> [Session] {
        let ws = store.addWorkspace(name: "work")
        let sessions = try names.map { try XCTUnwrap(store.addSession(toWorkspace: ws.id, cwd: "/\($0)")) }
        for session in sessions { store.setFlag(true, forSession: session.id) }
        return sessions
    }

    func testMoveFlaggedSessionReordersTheSavedOrderAndTheTreeReadsItBack() throws {
        let store = try XCTUnwrap(library.activeStore)
        let s = try flaggedSessions(in: store, ["a", "b", "c"])

        let response = server.moveFlaggedSession(s[2].id.uuidString, window: nil, anchor: s[0].id.uuidString,
                                                 placement: .before)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(id: s[2].id.uuidString)))
        XCTAssertEqual(server.buildTree(in: store).flaggedOrder, [s[2], s[0], s[1]].map(\.id.uuidString))
    }

    func testMoveFlaggedSessionRefusesAnUnflaggedOrUnknownAnchorAndItself() throws {
        let store = try XCTUnwrap(library.activeStore)
        let s = try flaggedSessions(in: store, ["a", "b"])
        let unflagged = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.workspaces.last).id, cwd: "/u"))

        for anchor in [unflagged.id.uuidString, UUID().uuidString, s[0].id.uuidString] {
            let response = server.moveFlaggedSession(s[0].id.uuidString, window: nil, anchor: anchor, placement: .after)
            XCTAssertFalse(response.ok, "anchor \(anchor) should be refused")
        }
        XCTAssertFalse(server.moveFlaggedSession(unflagged.id.uuidString, window: nil, anchor: s[0].id.uuidString,
                                                 placement: .after).ok)
        XCTAssertEqual(store.orderedFlaggedSessions.map(\.id), s.map(\.id))
    }

    func testMoveFlaggedSessionRefusesAnAnchorInAnotherWindow() throws {
        let store = try XCTUnwrap(library.activeStore)
        let s = try flaggedSessions(in: store, ["a", "b"])
        let other = try XCTUnwrap(library.store(for: library.newWindow(name: "other").id))
        let elsewhere = try flaggedSessions(in: other, ["z"])

        let response = server.moveFlaggedSession(s[1].id.uuidString, window: nil, anchor: elsewhere[0].id.uuidString,
                                                 placement: .before)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(store.orderedFlaggedSessions.map(\.id), s.map(\.id))
    }
}
