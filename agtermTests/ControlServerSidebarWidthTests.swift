import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for `ControlServer.setSidebarWidth`, which resolves `--window` against the real window
/// library before writing the store. The resolution and the echo are app-side, so neither is reachable
/// from `agtermCore`.
@MainActor
final class ControlServerSidebarWidthTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-control-sidebar-width-tests-\(UUID().uuidString)", isDirectory: true)
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
            server = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testSetsTheFrontmostStoreAndEchoesTheStoredWidth() throws {
        let store = try XCTUnwrap(library.activeStore)

        let response = server.setSidebarWidth(271.3, window: nil)

        XCTAssertEqual(response, ControlResponse(ok: true, result: ControlResult(sidebarWidth: 271.3)))
        XCTAssertEqual(store.sidebarWidth, 271.3)
    }

    func testEchoReportsTheClampedWidthRatherThanTheRequestedOne() throws {
        let store = try XCTUnwrap(library.activeStore)

        let response = server.setSidebarWidth(9000, window: nil)

        XCTAssertEqual(response.result?.sidebarWidth, AppStore.sidebarWidthMax,
                       "an out-of-range request answers ok, so only the echo can tell the caller it was clamped")
        XCTAssertEqual(store.sidebarWidth, AppStore.sidebarWidthMax)
    }

    func testWindowSelectorWritesThatWindowAndLeavesTheFrontmostAlone() throws {
        let background = try XCTUnwrap(library.activeStore)
        let backgroundID = try XCTUnwrap(library.activeWindowID)
        let frontmostID = library.newWindow(name: "frontmost").id
        XCTAssertEqual(library.activeWindowID, frontmostID)
        let frontmost = try XCTUnwrap(library.activeStore)
        let frontmostWidthBefore = frontmost.sidebarWidth

        let response = server.setSidebarWidth(340, window: backgroundID.uuidString)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(background.sidebarWidth, 340)
        XCTAssertEqual(frontmost.sidebarWidth, frontmostWidthBefore)
    }

    func testUnknownWindowErrorsAndWritesNothing() throws {
        let store = try XCTUnwrap(library.activeStore)
        let before = store.sidebarWidth

        let response = server.setSidebarWidth(340, window: UUID().uuidString)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(store.sidebarWidth, before)
    }

    func testTreeReportsTheWidthTheCommandWrote() throws {
        _ = server.setSidebarWidth(340, window: nil)

        let tree = server.controlTree(window: nil)

        XCTAssertEqual(tree.result?.tree?.sidebarWidth, 340)
    }
}
