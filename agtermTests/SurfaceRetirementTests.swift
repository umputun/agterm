import AppKit
import GhosttyKit
import XCTest
@testable import agterm

@MainActor
final class SurfaceRetirementTests: XCTestCase {
    private var window: NSWindow!
    private var terminal: GhosttySurfaceView!
    private var retirement: SurfaceRetirement!
    private var stoppedGroup: pid_t = 0

    override func setUp() async throws {
        try await super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        terminal = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat",
                                      env: ["AGTERM_RETIREMENT_TEST": "1"])
        terminal.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        window.contentView?.addSubview(terminal)
        terminal.createSurface()
        retirement = SurfaceRetirement()
    }

    override func tearDown() async throws {
        if stoppedGroup > 0 { killpg(stoppedGroup, SIGCONT) }
        await waitUntil { self.retirement.pendingCount == 0 }
        terminal.teardown()
        window.orderOut(nil)
        try await super.tearDown()
    }

    /// Stops the surface's child process group: the SIGHUP the io thread sends on stop stays pending, so its
    /// exit, and with it the free, waits until `resumeChild`.
    private func stopChild() throws -> ghostty_surface_t {
        let surface = try XCTUnwrap(terminal.surface)
        let deadline = Date().addingTimeInterval(30)
        while !Self.group(pid_t(ghostty_surface_foreground_pid(surface)), runs: "cat"), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        let group = pid_t(ghostty_surface_foreground_pid(surface))
        XCTAssertTrue(Self.group(group, runs: "cat"), "the child never reached cat")
        XCTAssertEqual(killpg(group, SIGSTOP), 0)
        stoppedGroup = group
        return surface
    }

    private static func group(_ group: pid_t, runs name: String) -> Bool {
        guard group > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: 32)
        _ = proc_listpgrppids(group, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.filter { $0 > 0 }.contains { pid in
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            return String(cString: buffer) == name
        }
    }

    private func resumeChild() {
        killpg(stoppedGroup, SIGCONT)
        stoppedGroup = 0
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(60)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testARetiredSurfaceKeepsItsLayerConfigAndEnvUntilItIsFreed() async throws {
        _ = try stopChild()
        XCTAssertFalse(terminal.configCStrings.isEmpty)
        XCTAssertFalse(terminal.envVars.isEmpty)
        let ghosttyLayer = try XCTUnwrap(terminal.layer)

        terminal.retireSurface(into: retirement)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(terminal.surface)
        XCTAssertEqual(retirement.pendingCount, 1)
        XCTAssertFalse(terminal.configCStrings.isEmpty)
        XCTAssertFalse(terminal.envVars.isEmpty)
        XCTAssertTrue(terminal.layer === ghosttyLayer)

        resumeChild()
        await waitUntil { self.retirement.pendingCount == 0 }

        XCTAssertEqual(retirement.pendingCount, 0)
        XCTAssertTrue(terminal.configCStrings.isEmpty)
        XCTAssertTrue(terminal.envVars.isEmpty)
        XCTAssertFalse(terminal.layer === ghosttyLayer)
    }

    func testCallbacksForARetiredSurfaceAreIgnored() async throws {
        let surface = try stopChild()
        var exited = false
        var searchEnded = false
        terminal.onExit = { exited = true }
        terminal.onSearchEnd = { searchEnded = true }

        terminal.retireSurface(into: retirement)
        let callbacks = GhosttyCallbacks()
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = surface
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_END_SEARCH
        XCTAssertTrue(callbacks.action(target: target, action: action))
        callbacks.closeSurface(ud: Unmanaged.passUnretained(terminal).toOpaque())
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(exited)
        XCTAssertFalse(searchEnded)
        XCTAssertEqual(retirement.pendingCount, 1)
    }
}
