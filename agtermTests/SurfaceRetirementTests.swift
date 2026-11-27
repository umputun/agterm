import AppKit
import GhosttyKit
import os
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SurfaceRetirementTests: XCTestCase {
    private var window: NSWindow!
    private var terminal: GhosttySurfaceView!
    private var retirement: SurfaceRetirement!
    private var stoppedGroup: pid_t = 0
    private var stateDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        terminal = makeTerminal(env: ["AGTERM_RETIREMENT_TEST": "1"])
        retirement = SurfaceRetirement()
    }

    private func makeTerminal(env: [String: String], backedByZmx: Bool = false) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat", env: env,
                                      backedByZmx: backedByZmx)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        window.contentView?.addSubview(view)
        view.createSurface()
        return view
    }

    override func tearDown() async throws {
        if stoppedGroup > 0 { killpg(stoppedGroup, SIGCONT) }
        await waitUntil { self.retirement.pendingCount == 0 }
        terminal.destroySurface()
        window.orderOut(nil)
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
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
        let foreground = pid_t(ghostty_surface_foreground_pid(surface))
        // fatal: killpg(0, SIGSTOP) would stop the test runner itself
        let group = try XCTUnwrap(Self.group(foreground, runs: "cat") ? foreground : nil, "the child never reached cat")
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
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == name
        }
    }

    private func resumeChild() {
        killpg(stoppedGroup, SIGCONT)
        stoppedGroup = 0
    }

    /// resumeAfterTenSeconds resumes the stopped child off the main thread, so a call that blocks on it fails
    /// its assertion instead of hanging the test host.
    private func resumeAfterTenSeconds() -> (item: DispatchWorkItem, fired: OSAllocatedUnfairLock<Bool>) {
        let fired = OSAllocatedUnfairLock(initialState: false)
        let group = stoppedGroup
        let item = DispatchWorkItem { @Sendable in
            fired.withLock { $0 = true }
            killpg(group, SIGCONT)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: item)
        return (item, fired)
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

    func testTeardownRetiresASurfaceWhoseChildHasNotExited() async throws {
        _ = try stopChild()
        let fallback = resumeAfterTenSeconds()
        defer { fallback.item.cancel() }

        terminal.teardown()

        XCTAssertFalse(fallback.fired.withLock { $0 }, "teardown waited for the stopped child")
        XCTAssertNil(terminal.surface)
        XCTAssertFalse(terminal.configCStrings.isEmpty, "a stopped child keeps the surface retired, not freed")

        resumeChild()
        await waitUntil { self.terminal.configCStrings.isEmpty }
        XCTAssertTrue(terminal.configCStrings.isEmpty)
    }

    func testARetiredSurfaceHandsOffItsExitCodeAndDropsItsFilesAtOnce() async throws {
        _ = try stopChild()
        let dir = FileManager.default.temporaryDirectory
        let codeFile = dir.appendingPathComponent("agterm-retire-code-\(UUID().uuidString)").path
        let bodyFile = dir.appendingPathComponent("agterm-retire-hud-\(UUID().uuidString)").path
        try "7\n".write(toFile: codeFile, atomically: true, encoding: .utf8)
        try "body".write(toFile: bodyFile, atomically: true, encoding: .utf8)
        terminal.overlayCodeFile = codeFile
        terminal.hudBodyFile = bodyFile
        var captured: Int?
        terminal.onExitCodeCaptured = { captured = $0 }
        terminal.onExit = {}

        terminal.retireSurface(into: retirement)

        XCTAssertEqual(retirement.pendingCount, 1)
        XCTAssertEqual(captured, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codeFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyFile), "a replacement HUD writes this same path")
        XCTAssertNil(terminal.hudBodyFile)
        XCTAssertNil(terminal.onExit, "a surface that never frees must not keep the store alive")
    }

    func testDrainForQuitLeavesAStoppedChildPendingPastItsBudget() async throws {
        _ = try stopChild()
        terminal.retireSurface(into: retirement)
        let fallback = resumeAfterTenSeconds()
        defer { fallback.item.cancel() }
        let start = ContinuousClock.now

        retirement.drainForQuit(budget: .milliseconds(200))

        let waited = ContinuousClock.now - start
        XCTAssertFalse(fallback.fired.withLock { $0 }, "the drain outlived its budget")
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(200))
        XCTAssertLessThan(waited, .seconds(10))
        XCTAssertEqual(retirement.pendingCount, 1)
        XCTAssertFalse(terminal.configCStrings.isEmpty)
    }

    func testDrainForQuitFreesASurfaceWhoseChildExitsWithinItsBudget() async throws {
        _ = try stopChild()
        terminal.retireSurface(into: retirement)
        resumeChild()

        retirement.drainForQuit(budget: .seconds(30))

        XCTAssertEqual(retirement.pendingCount, 0)
        XCTAssertTrue(terminal.configCStrings.isEmpty)
    }

    func testASecondTeardownOfARetiredSurfaceKeepsItRetired() async throws {
        _ = try stopChild()
        terminal.retireSurface(into: retirement)

        terminal.destroySurface()
        terminal.retireSurface(into: retirement)

        XCTAssertEqual(retirement.pendingCount, 1)
        XCTAssertFalse(terminal.configCStrings.isEmpty, "the retired surface still runs on these")
    }

    func testCallbacksForARetiredSurfaceAreIgnored() async throws {
        let surface = try stopChild()
        var exited = false
        var searchEnded = false

        terminal.retireSurface(into: retirement)
        terminal.onExit = { exited = true }
        terminal.onSearchEnd = { searchEnded = true }
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

    func testAReattachedLiveScratchRetiresItsOldSurface() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-retirement-\(UUID().uuidString)")
        stateDir = dir
        let library = WindowLibrary(directory: dir)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID),
                                                     cwd: NSHomeDirectory()))
        let identity = UUID()
        defer { ZmxLeadBook.shared.forget(pane: identity) }
        terminal.destroySurface()
        terminal = makeTerminal(env: ["AGTERM_PANE_ID": identity.uuidString], backedByZmx: true)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: identity)
        _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:follower:1")), pane: identity)
        store.recordLiveScratch(session.id, identity: identity)
        terminal.watermarkSession = session
        session.scratchSurface = terminal
        _ = try stopChild()
        let pending = SurfaceRetirement.shared.pendingCount
        let services = agtermApp.SurfaceServices(library: library, actions: AppActions(library: library), zmxForegroundResolver: nil,
                                                 spawnRegistry: nil, launchContext: agtermApp.LaunchSpawnContext())

        XCTAssertTrue(agtermApp.reattachPane(terminal, claim: true, services: services))

        let fresh = try XCTUnwrap(session.scratchSurface as? GhosttySurfaceView)
        XCTAssertFalse(fresh === terminal)
        XCTAssertNil(terminal.surface)
        XCTAssertEqual(SurfaceRetirement.shared.pendingCount, pending + 1)
        XCTAssertFalse(terminal.configCStrings.isEmpty)

        resumeChild()
        await waitUntil { SurfaceRetirement.shared.pendingCount == pending }
        XCTAssertEqual(SurfaceRetirement.shared.pendingCount, pending)
        XCTAssertTrue(terminal.configCStrings.isEmpty)
        fresh.destroySurface()
    }
}
