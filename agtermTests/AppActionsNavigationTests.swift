import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppActionsNavigationTests: XCTestCase {
    private var stateDir: URL!
    private var registered: [WindowInfo.ID] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-nav-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func registerWindow(_ id: WindowInfo.ID) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(id, window: window)
        registered.append(id)
        windows.append(window)
        return window
    }

    private struct Pair {
        let library: WindowLibrary
        let actions: AppActions
        let front: WindowInfo.ID
        let frontStore: AppStore
        let origin: Session
        let back: WindowInfo.ID
        let backStore: AppStore
        let hostBack: NSWindow
    }

    private func makePair(acrossWindows: Bool) throws -> Pair {
        let library = WindowLibrary(directory: stateDir)
        let front = try XCTUnwrap(library.activeWindowID)
        let back = library.newWindow(name: "back")
        library.frontmostWindowID = front
        _ = registerWindow(front)
        let hostBack = registerWindow(back.id)
        let frontStore = try XCTUnwrap(library.store(for: front))
        let backStore = try XCTUnwrap(library.store(for: back.id))
        let origin = try addSession(to: frontStore, AgentIndicator(status: .idle))
        frontStore.selectSession(origin.id)
        frontStore.attentionNavigationAcrossWindows = acrossWindows
        backStore.attentionNavigationAcrossWindows = acrossWindows
        return Pair(library: library, actions: AppActions(library: library), front: front, frontStore: frontStore,
                    origin: origin, back: back.id, backStore: backStore, hostBack: hostBack)
    }

    private func addSession(to store: AppStore, _ indicator: AgentIndicator) throws -> Session {
        let session = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: NSTemporaryDirectory(),
                                                     select: false))
        store.setAgentIndicator(indicator, forSession: session.id)
        return session
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testStepStaysInTheWindowWithTheSettingOff() throws {
        let pair = try makePair(acrossWindows: false)
        let before = pair.backStore.activeSession?.id
        _ = try addSession(to: pair.backStore, AgentIndicator(status: .blocked))

        pair.actions.selectNextAttentionSession()
        drainMainQueue()

        XCTAssertEqual(pair.library.frontmostWindowID, pair.front)
        XCTAssertEqual(pair.frontStore.selectedSessionID, pair.origin.id)
        XCTAssertEqual(pair.backStore.activeSession?.id, before)
    }

    func testStepRaisesTheOtherWindowAndSelectsThereWithTheSettingOn() throws {
        let pair = try makePair(acrossWindows: true)
        let target = try addSession(to: pair.backStore, AgentIndicator(status: .blocked))
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .agtermWindowFrontmostChanged,
                                                          object: nil, queue: .main) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        pair.actions.selectNextAttentionSession()
        XCTAssertEqual(pair.library.frontmostWindowID, pair.front, "the raise waits one main-queue tick")
        drainMainQueue()

        XCTAssertEqual(pair.library.frontmostWindowID, pair.back)
        XCTAssertTrue(pair.hostBack.isVisible)
        XCTAssertEqual(pair.backStore.activeSession?.id, target.id)
        XCTAssertEqual(posted, 1)
    }

    func testStepPrefersTheNextTargetInTheSameWindowAndSelectsItAtOnce() throws {
        let pair = try makePair(acrossWindows: true)
        let local = try addSession(to: pair.frontStore, AgentIndicator(status: .completed))
        _ = try addSession(to: pair.backStore, AgentIndicator(status: .blocked))

        pair.actions.selectNextAttentionSession()

        XCTAssertEqual(pair.frontStore.selectedSessionID, local.id)
        XCTAssertEqual(pair.library.frontmostWindowID, pair.front)
    }

    func testPreviousStepWrapsBackwardIntoTheOtherWindow() throws {
        let pair = try makePair(acrossWindows: true)
        let target = try addSession(to: pair.backStore, AgentIndicator(status: .blocked))

        pair.actions.selectPreviousAttentionSession()
        drainMainQueue()

        XCTAssertEqual(pair.library.frontmostWindowID, pair.back)
        XCTAssertEqual(pair.backStore.activeSession?.id, target.id)
    }

    func testStepSkipsAWindowUnderTerminalZoom() throws {
        let pair = try makePair(acrossWindows: true)
        let before = pair.backStore.activeSession?.id
        let session = try addSession(to: pair.backStore, AgentIndicator(status: .blocked))
        let zoom = TerminalZoomController()
        TerminalZoomRegistry.shared.register(pair.back, controller: zoom)
        defer { TerminalZoomRegistry.shared.unregister(pair.back) }
        zoom.set(.on, target: .session(session.id, .primary))

        pair.actions.selectNextAttentionSession()
        drainMainQueue()

        XCTAssertEqual(pair.library.frontmostWindowID, pair.front)
        XCTAssertEqual(pair.frontStore.selectedSessionID, pair.origin.id)
        XCTAssertEqual(pair.backStore.activeSession?.id, before)
    }

    func testStepFromAWindowWithNoSelectionReachesTheOtherWindow() throws {
        let pair = try makePair(acrossWindows: true)
        let target = try addSession(to: pair.backStore, AgentIndicator(status: .blocked))
        pair.frontStore.selectSession(nil)

        pair.actions.selectNextAttentionSession()
        drainMainQueue()

        XCTAssertEqual(pair.library.frontmostWindowID, pair.back)
        XCTAssertEqual(pair.backStore.activeSession?.id, target.id)
    }

    func testStepRevealsTheCapturedPaneAfterAnAutoResetClears() throws {
        let pair = try makePair(acrossWindows: true)
        let target = try addSession(to: pair.backStore,
                                    AgentIndicator(status: .completed, autoReset: true, statusPane: .scratch))

        pair.actions.selectNextAttentionSession()
        drainMainQueue()

        XCTAssertEqual(target.agentIndicator.status, .idle)
        XCTAssertTrue(target.scratchActive)
    }

    func testActionPaletteRowRaisesTheOtherWindowOnlyAfterItReturns() throws {
        let pair = try makePair(acrossWindows: true)
        let target = try addSession(to: pair.backStore, AgentIndicator(status: .blocked))
        let row = try XCTUnwrap(pair.actions.paletteActions().first { $0.title == "Next Attention Session" })

        XCTAssertTrue(row.runIfEnabled())
        XCTAssertEqual(pair.library.frontmostWindowID, pair.front, "the palette dismisses before the raise")
        drainMainQueue()

        XCTAssertEqual(pair.library.frontmostWindowID, pair.back)
        XCTAssertEqual(pair.backStore.activeSession?.id, target.id)
    }

    func testAnEmptyWindowEnablesTheAttentionStepsOnlyWithTheSetting() throws {
        let pair = try makePair(acrossWindows: false)
        pair.frontStore.selectSession(nil)

        XCTAssertFalse(PaletteCommand.nextAttentionSession.isEnabled(in: pair.actions.paletteContext))
        pair.frontStore.attentionNavigationAcrossWindows = true
        XCTAssertTrue(PaletteCommand.nextAttentionSession.isEnabled(in: pair.actions.paletteContext))
        XCTAssertTrue(PaletteCommand.previousAttentionSession.isEnabled(in: pair.actions.paletteContext))
    }

    func testStepWithNoOtherTargetRevealsTheCurrentSessionsTaggedPane() throws {
        let pair = try makePair(acrossWindows: true)
        pair.frontStore.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .scratch), forSession: pair.origin.id)

        pair.actions.selectNextAttentionSession()
        drainMainQueue()

        XCTAssertEqual(pair.library.frontmostWindowID, pair.front)
        XCTAssertTrue(pair.origin.scratchActive)
    }
}
