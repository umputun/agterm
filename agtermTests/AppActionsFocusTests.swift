import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Coverage for `AppActions+Focus`'s reveal leg: a recent-closed reopen restores into the window that still
/// owns the entry, which need not be the active one, so the action has to move the frontmost id and the
/// first responder there rather than relying on the active store.
@MainActor
final class AppActionsFocusTests: XCTestCase {
    private var stateDir: URL!
    private var registered: [WindowInfo.ID] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-reveal-tests-\(UUID().uuidString)", isDirectory: true)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            registered.forEach { WindowRegistry.shared.unregister($0) }
            registered = []
            windows.forEach { $0.orderOut(nil) }
            windows = []
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    /// A titled window registered under `id`, ordered out at teardown. `isReleasedWhenClosed` is false per
    /// the hosted-test rule: the registry outlives the test body.
    private func registerWindow(_ id: WindowInfo.ID) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(id, window: window)
        registered.append(id)
        windows.append(window)
        return window
    }

    func testReopeningRevealsTheWindowThatOwnsTheEntryRatherThanTheActiveOne() throws {
        let windowA = UUID(), windowB = UUID(), sessionID = UUID()
        let windowsDir = stateDir.appendingPathComponent("windows")
        try PersistenceStore(directory: windowsDir, fileName: "\(windowA.uuidString).json")
            .save(Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "a", sessions: [])]))
        try PersistenceStore(directory: windowsDir, fileName: "\(windowB.uuidString).json")
            .save(Snapshot(workspaces: [WorkspaceSnapshot(id: UUID(), name: "b", sessions: [
                SessionSnapshot(id: sessionID, customName: "api", cwd: NSTemporaryDirectory()),
            ])]))
        let index = WindowsIndex(frontmost: windowA, windows: [WindowEntry(id: windowA, name: "a", isOpen: true),
                                                              WindowEntry(id: windowB, name: "b", isOpen: true)])
        try JSONEncoder().encode(index).write(to: stateDir.appendingPathComponent("windows.json"))

        let library = WindowLibrary(directory: stateDir)
        _ = registerWindow(windowA)
        let hostB = registerWindow(windowB)
        let storeB = try XCTUnwrap(library.store(for: windowB))
        let session = try XCTUnwrap(storeB.session(withID: sessionID))

        let surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory())
        defer { surface.teardown(); surface.removeFromSuperview() }
        surface.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        hostB.contentView?.addSubview(surface)
        session.surface = surface

        XCTAssertTrue(storeB.softCloseSession(sessionID, grace: 60))
        XCTAssertEqual(library.frontmostWindowID, windowA, "the reopen starts from the other window")
        XCTAssertFalse(hostB.isVisible, "off screen until the reveal orders it front")

        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .agtermWindowFrontmostChanged,
                                                          object: nil, queue: .main) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let actions = AppActions(library: library)
        actions.openLatestRecentClosed()

        XCTAssertEqual(library.frontmostWindowID, windowB, "the owner window must become frontmost")
        XCTAssertTrue(hostB.isVisible, "and be ordered front: a hidden window can still hold a responder")
        XCTAssertTrue(storeB.session(withID: sessionID) === session, "the original object comes back")
        XCTAssertTrue(hostB.firstResponder === surface, "and its surface takes first responder")

        XCTAssertEqual(posted, 1, "the frontmost change must be published for the control cache")
        let saved = try JSONDecoder().decode(WindowsIndex.self,
                                             from: Data(contentsOf: stateDir.appendingPathComponent("windows.json")))
        XCTAssertEqual(saved.frontmost, windowB, "and persisted to the index")
    }

    private struct Pair {
        let library: WindowLibrary
        let actions: AppActions
        let front: WindowInfo.ID
        let back: WindowInfo.ID
        let backStore: AppStore
        let hostBack: NSWindow
    }

    private func makePair() throws -> Pair {
        let library = WindowLibrary(directory: stateDir)
        let front = try XCTUnwrap(library.activeWindowID)
        let back = library.newWindow(name: "back")
        library.frontmostWindowID = front
        _ = registerWindow(front)
        let hostBack = registerWindow(back.id)
        let backStore = try XCTUnwrap(library.store(for: back.id))
        return Pair(library: library, actions: AppActions(library: library), front: front, back: back.id,
                    backStore: backStore, hostBack: hostBack)
    }

    private func addSession(to store: AppStore, _ indicator: AgentIndicator) throws -> Session {
        let session = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: NSTemporaryDirectory(),
                                                     select: false))
        store.setAgentIndicator(indicator, forSession: session.id)
        return session
    }

    func testAttentionPickRaisesTheOwningWindowAndSelectsThere() throws {
        let pair = try makePair()
        let session = try addSession(to: pair.backStore, AgentIndicator(status: .blocked))
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .agtermWindowFrontmostChanged,
                                                          object: nil, queue: .main) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        pair.actions.selectAttention(windowID: pair.back, sessionID: session.id)

        XCTAssertEqual(pair.library.frontmostWindowID, pair.back)
        XCTAssertTrue(pair.hostBack.isVisible)
        XCTAssertEqual(pair.backStore.activeSession?.id, session.id)
        XCTAssertEqual(posted, 1)
    }

    func testAttentionPickRevealsAHiddenScratchInTheOtherWindow() throws {
        let pair = try makePair()
        let session = try addSession(to: pair.backStore, AgentIndicator(status: .blocked, statusPane: .scratch))

        pair.actions.selectAttention(windowID: pair.back, sessionID: session.id)

        XCTAssertTrue(session.scratchActive)
    }

    func testAttentionPickHidesAShownScratchCoveringAMainTarget() throws {
        let pair = try makePair()
        let session = try addSession(to: pair.backStore, AgentIndicator(status: .blocked, statusPane: .left))
        pair.backStore.toggleScratch(session.id)

        pair.actions.selectAttention(windowID: pair.back, sessionID: session.id)

        XCTAssertFalse(session.scratchActive)
    }

    func testAttentionPickKeepsTheCapturedPaneAfterAnAutoResetClears() throws {
        let pair = try makePair()
        let session = try addSession(to: pair.backStore,
                                     AgentIndicator(status: .completed, autoReset: true, statusPane: .scratch))

        pair.actions.selectAttention(windowID: pair.back, sessionID: session.id)

        XCTAssertEqual(session.agentIndicator.status, .idle)
        XCTAssertTrue(session.scratchActive)
    }

    func testAttentionPickLeavesAnActiveSessionsPanesAlone() throws {
        let pair = try makePair()
        let session = try addSession(to: pair.backStore, AgentIndicator(status: .active, statusPane: .left))
        pair.backStore.toggleScratch(session.id)
        session.splitFocused = true

        pair.actions.selectAttention(windowID: pair.back, sessionID: session.id)

        XCTAssertEqual(pair.backStore.activeSession?.id, session.id)
        XCTAssertTrue(session.scratchActive)
        XCTAssertTrue(session.splitFocused)
    }

    func testAttentionPickDropsWhenTheOwningWindowCannotBeRaised() throws {
        let library = WindowLibrary(directory: stateDir)
        let front = try XCTUnwrap(library.activeWindowID)
        let back = library.newWindow(name: "back")
        library.frontmostWindowID = front
        _ = registerWindow(front)
        let backStore = try XCTUnwrap(library.store(for: back.id))
        let before = backStore.activeSession?.id
        let session = try addSession(to: backStore, AgentIndicator(status: .blocked))

        AppActions(library: library).selectAttention(windowID: back.id, sessionID: session.id)

        XCTAssertEqual(library.frontmostWindowID, front)
        XCTAssertEqual(backStore.activeSession?.id, before)
    }

    func testAttentionPickRefusesATargetUnderTerminalZoom() throws {
        let pair = try makePair()
        let before = pair.backStore.activeSession?.id
        let session = try addSession(to: pair.backStore, AgentIndicator(status: .blocked, statusPane: .scratch))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(pair.back, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(pair.back) }
        zoom.set(.on, target: .session(session.id, .primary))

        pair.actions.selectAttention(windowID: pair.back, sessionID: session.id)

        XCTAssertEqual(pair.library.frontmostWindowID, pair.front)
        XCTAssertEqual(pair.backStore.activeSession?.id, before)
        XCTAssertFalse(session.scratchActive)
    }
}
