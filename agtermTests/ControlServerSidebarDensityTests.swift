import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerSidebarDensityTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-sidebar-density-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            server = ControlServer(
                library: library,
                actions: AppActions(library: library),
                settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                socketPath: stateDir.appendingPathComponent("control.sock").path
            )
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            GhosttyApp.shared.setSidebarDensity(.standard)
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testSetsTheDensityPersistsItAndEchoesTheResult() {
        let response = server.setSidebarDensity(.compact)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(text: "compact")))
        XCTAssertEqual(GhosttyApp.shared.sidebarDensity, .compact)
        XCTAssertEqual(SettingsStore(directory: stateDir).load().sidebarDensity, "compact")
    }

    func testToggleResolvesFromTheCurrentDensityBothWays() {
        XCTAssertEqual(server.setSidebarDensity(.toggle).result?.text, "compact")
        XCTAssertEqual(server.setSidebarDensity(.toggle).result?.text, "default")
        XCTAssertEqual(GhosttyApp.shared.sidebarDensity, .standard)
        XCTAssertNil(SettingsStore(directory: stateDir).load().sidebarDensity)
    }

    func testAnUnchangedDensityAnswersOkWithoutABroadcast() {
        let posted = expectation(forNotification: .agtermAppearanceChanged, object: nil)
        posted.isInverted = true

        let response = server.setSidebarDensity(.standard)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(text: "default")))
        wait(for: [posted], timeout: 0.3)
    }

    func testNeedsNoOpenWindow() throws {
        library.closeWindow(try XCTUnwrap(library.activeWindowID))
        XCTAssertNil(library.activeStore)

        XCTAssertEqual(server.setSidebarDensity(.compact).result?.text, "compact")
        XCTAssertEqual(GhosttyApp.shared.sidebarDensity, .compact)
    }

    func testTreeReportsTheDensityInBothSidebarModes() throws {
        let store = try XCTUnwrap(library.activeStore)
        XCTAssertEqual(server.buildTree(in: store).sidebarDensity, "default")

        _ = server.setSidebarDensity(.compact)
        XCTAssertEqual(server.buildTree(in: store).sidebarDensity, "compact")

        store.setSidebarMode(.flagged)
        XCTAssertEqual(server.buildTree(in: store).sidebarDensity, "compact")
    }
}
