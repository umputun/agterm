import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the title probe's two write paths: a title write touches the OS title alone, while
/// attach and the appearance notification run the full titlebar blend.
@MainActor
final class WindowAccessorTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-window-accessor-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            // over-releases a window the registry may still hold, crashing the host at autorelease-pool pop
            window.isReleasedWhenClosed = false
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window?.close()
            window = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testSetTitleWritesTheTitleAndSkipsTheBlend() throws {
        let probe = try attachedProbe()
        drain()
        window.titlebarSeparatorStyle = .line
        drain()
        XCTAssertEqual(window.titlebarSeparatorStyle, .line,
                       "the attach blends must have drained here, or the assertions below measure them")

        probe.setTitle("spin 1")
        drain()

        XCTAssertEqual(window.title, "spin 1")
        XCTAssertEqual(window.titlebarSeparatorStyle, .line, "a title write must not run the full blend")

        NotificationCenter.default.post(name: .agtermAppearanceChanged, object: nil)
        drain()
        XCTAssertEqual(window.titlebarSeparatorStyle, .none,
                       "the appearance notification must still run the blend, or the sentinel proves nothing")
    }

    func testATitleSetBeforeAttachIsAppliedOnAttach() throws {
        let store = try XCTUnwrap(library.activeStore)
        let probe = WindowAccessor.TitleProbeView(windowID: try XCTUnwrap(library.activeWindowID),
                                                  library: library, store: store)
        probe.setTitle("early")

        window.contentView = probe
        drain()

        XCTAssertEqual(window.title, "early")
    }

    private func attachedProbe() throws -> WindowAccessor.TitleProbeView {
        let store = try XCTUnwrap(library.activeStore)
        let probe = WindowAccessor.TitleProbeView(windowID: try XCTUnwrap(library.activeWindowID),
                                                  library: library, store: store)
        window.contentView = probe
        return probe
    }

    private func drain() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}
