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

    func testRapidTitleChangesAreCoalescedIntoOneTrailingWrite() throws {
        let probe = try attachedProbe()
        drain()
        window.titlebarSeparatorStyle = .line
        drain()
        XCTAssertEqual(window.titlebarSeparatorStyle, .line,
                       "the attach blends must have drained here, or the assertions below measure them")

        probe.setTitle("a")
        XCTAssertEqual(window.title, "a", "the first change after a quiet interval must land at once")

        probe.setTitle("b")
        probe.setTitle("c")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(window.title, "a", "changes within the interval must wait for the trailing write")

        let deadline = Date().addingTimeInterval(2)
        while window.title != "c", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(window.title, "c", "the trailing write must carry the latest title")
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

    func testOnlyAnOpenEventBeforeLaunchFinishesIsALaunchHandoff() {
        let url = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                         targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                         transactionID: AETransactionID(kAnyTransactionID))
        let documents = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
        let cases: [(NSAppleEventDescriptor?, Bool, Bool)] = [
            (url, false, true), (url, true, false), (documents, false, true), (documents, true, false), (nil, false, false),
        ]
        for (event, finished, expected) in cases {
            XCTAssertEqual(WindowAccessor.TitleProbeView.isLaunchHandoff(event: event, launchFinished: finished), expected)
        }
    }

    func testClosingARetiredLaunchWindowKeepsItsWindowOpen() throws {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        window.contentView = WindowAccessor.TitleProbeView(windowID: windowID, library: library, store: store)
        drain()
        XCTAssertTrue(WindowRegistry.shared.isRegistered(windowID))
        WindowRegistry.shared.retire(windowID, window: window)

        window.close()

        XCTAssertTrue(library.isOpen(windowID))
        XCTAssertTrue(store.session(withID: session.id) === session)
        XCTAssertFalse(WindowRegistry.shared.isRegistered(windowID))
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
