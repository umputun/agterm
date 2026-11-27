import AppKit
import GhosttyKit
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

    func testAQuitDrainsRetiredSurfacesWhenItsLastWindowCloses() throws {
        let (pending, _) = try closeWindowHoldingALiveSurface(terminating: true)

        XCTAssertEqual(SurfaceRetirement.shared.pendingCount, pending)
    }

    func testAWindowClosedBeforeQuitLeavesTheDrainToTermination() throws {
        let (pending, group) = try closeWindowHoldingALiveSurface(terminating: false)
        defer { killpg(group, SIGCONT) }
        XCTAssertEqual(SurfaceRetirement.shared.pendingCount, pending + 1)
        killpg(group, SIGCONT)

        SurfaceRetirement.shared.drainForQuitOnceWindowless()

        XCTAssertEqual(SurfaceRetirement.shared.pendingCount, pending)
    }

    /// closeWindowHoldingALiveSurface closes the probe's window with a running `/bin/cat` as its session's
    /// surface and returns the retirement count from before the close, plus cat's process group. No run-loop
    /// turn follows the close, so the 20 ms sweep cannot free the surface behind the drain's back. A close
    /// outside a quit stops the group first, so the surface cannot free inside the close; the caller resumes it.
    private func closeWindowHoldingALiveSurface(terminating: Bool) throws -> (pending: Int, group: pid_t) {
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.orderOut(nil) }
        let terminal = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        terminal.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.contentView?.addSubview(terminal)
        terminal.createSurface()
        defer { terminal.destroySurface() }
        let surface = try XCTUnwrap(terminal.surface)
        let deadline = Date().addingTimeInterval(30)
        while !Self.runsCat(pid_t(ghostty_surface_foreground_pid(surface))), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let foreground = pid_t(ghostty_surface_foreground_pid(surface))
        // fatal: killpg(0, SIGSTOP) would stop the test runner itself
        let group = try XCTUnwrap(Self.runsCat(foreground) ? foreground : nil, "the drain budget would cover the spawn")
        session.surface = terminal
        window.contentView = WindowAccessor.TitleProbeView(windowID: windowID, library: library, store: store)
        drain()
        XCTAssertEqual(WindowRegistry.shared.registeredCount, 1, "another registered window would hold the drain")
        let pending = SurfaceRetirement.shared.pendingCount
        library.isTerminating = terminating
        if !terminating { XCTAssertEqual(killpg(group, SIGSTOP), 0) }

        window.close()

        XCTAssertNil(terminal.surface)
        return (pending, group)
    }

    private static func runsCat(_ group: pid_t) -> Bool {
        guard group > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: 32)
        _ = proc_listpgrppids(group, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.filter { $0 > 0 }.contains { pid in
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "cat"
        }
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
