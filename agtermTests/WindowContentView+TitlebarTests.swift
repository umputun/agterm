import AppKit
import SwiftUI
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the OS-title child view: a session or window rename reaches `NSWindow.title` through
/// its own body, with the root view left in place.
@MainActor
final class WindowContentViewTitlebarTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-titlebar-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testTheWindowTitleFollowsSessionAndWindowRenames() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        window.contentView = NSHostingView(rootView: WindowTitleSync(store: store, library: library,
                                                                    windowID: windowID, captureOnExit: nil))
        window.layoutIfNeeded()
        try waitForTitle(session.displayName)

        session.oscTitle = "spin 1"
        try waitForTitle("spin 1")

        store.renameSession(session.id, to: "api")
        try waitForTitle("api")

        library.renameWindow(windowID, to: "work")
        try waitForTitle("api — work")
    }

    private func waitForTitle(_ expected: String) throws {
        let deadline = Date().addingTimeInterval(2)
        while window.title != expected, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(window.title, expected)
    }
}
