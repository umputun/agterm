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
}
