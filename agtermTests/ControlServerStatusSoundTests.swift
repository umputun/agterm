import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerStatusSoundTests: XCTestCase {
    private final class Surface: TerminalSurface {
        let paneToken: String
        var isRealized = true
        init(_ token: String) { paneToken = token }
        func teardown() {}
        func promoteToPrimaryPane() {}
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settings: SettingsModel!
    private var server: ControlServer!
    private var player: StatusSoundPlayer!
    private var sound: RecordingSound!
    private var gate: StatusSoundResolutionGate!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-status-\(UUID().uuidString)")
        library = WindowLibrary(directory: stateDir)
        settings = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        sound = try XCTUnwrap(RecordingSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true))
    }

    override func tearDown() async throws {
        gate?.release.signal()
        server = nil
        player = nil
        settings = nil
        library = nil
        sound = nil
        gate = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testUnknownSoundDoesNotMutateAndWinsOverMissingTarget() async throws {
        makeServer(resolvedSound: nil)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let before = session.agentIndicator
        let pending = Task { await self.update() }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertEqual(session.agentIndicator, before)
        gate.release.signal()
        let response = await pending.value
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.hasPrefix("unknown sound: held") == true)
        XCTAssertEqual(session.agentIndicator, before)

        let missing = await update(target: UUID().uuidString, soundName: "missing")
        XCTAssertTrue(missing.error?.hasPrefix("unknown sound: missing") == true)
        XCTAssertTrue(sound.log.calls.isEmpty)
    }

    func testActiveTargetStaysBoundDuringSelectionChange() async throws {
        makeServer(resolvedSound: sound)
        let store = try XCTUnwrap(library.activeStore)
        let original = try XCTUnwrap(store.activeSession)
        let other = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp"))
        store.selectSession(original.id)
        let pending = Task { await self.update() }
        await fulfillment(of: [gate.started], timeout: 2)
        store.selectSession(other.id)
        gate.release.signal()
        let response = await pending.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.id, original.id.uuidString)
        XCTAssertEqual(original.agentIndicator.status, .blocked)
        XCTAssertEqual(other.agentIndicator.status, .idle)
        await fulfillment(of: [sound.log.playCalled], timeout: 2)
        XCTAssertEqual(sound.log.calls.map(\.selector), ["stop", "play"])
    }

    func testClosedSessionDoesNotSucceedOrPlay() async throws {
        makeServer(resolvedSound: sound)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let pending = Task { await self.update() }
        await fulfillment(of: [gate.started], timeout: 2)
        store.closeSession(session.id)
        gate.release.signal()
        let response = await pending.value
        XCTAssertFalse(response.ok)
        _ = await player.action(for: "barrier")
        XCTAssertTrue(sound.log.calls.isEmpty)
    }

    func testClosedWindowDoesNotMutateRetainedStoreOrPlay() async throws {
        makeServer(resolvedSound: sound)
        let window = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let pending = Task { await self.update() }
        await fulfillment(of: [gate.started], timeout: 2)
        library.closeWindow(window)
        gate.release.signal()
        let response = await pending.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(session.agentIndicator.status, .idle)
        _ = await player.action(for: "barrier")
        XCTAssertTrue(sound.log.calls.isEmpty)
    }

    func testPaneRefusalUsesStateAfterResolutionAndDoesNotPlay() async throws {
        makeServer(resolvedSound: sound)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        session.hasSplit = true
        let pending = Task { await self.update(status: .completed, pane: .left) }
        await fulfillment(of: [gate.started], timeout: 2)
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)
        gate.release.signal()
        let response = await pending.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "blocked status owned by pane right (write from that pane to change it)")
        XCTAssertEqual(session.agentIndicator.status, .blocked)
        _ = await player.action(for: "barrier")
        XCTAssertTrue(sound.log.calls.isEmpty)
    }

    func testInvalidBlockedDefaultDoesNotRejectOrDelayMutation() async throws {
        makeServer(resolvedSound: nil)
        settings.setBlockedStatusSoundName("held")
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let response = await update(soundName: nil)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(session.agentIndicator.status, .blocked)
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertFalse(gate.onMainThread)
        gate.release.signal()
        _ = await player.action(for: "barrier")
        XCTAssertTrue(sound.log.calls.isEmpty)
    }

    func testPaneTokenUsesRolesAfterResolution() async throws {
        makeServer(resolvedSound: sound)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        let left = Surface("left-token")
        let right = Surface("right-token")
        session.surface = left
        session.splitSurface = right
        session.hasSplit = true
        let pending = Task { await self.update(pane: .right, paneID: "right-token") }
        await fulfillment(of: [gate.started], timeout: 2)
        session.surface = right
        session.splitSurface = left
        gate.release.signal()
        let response = await pending.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(session.agentIndicator.statusPane, .left)
        await fulfillment(of: [sound.log.playCalled], timeout: 2)
    }

    private func makeServer(resolvedSound: NSSound?) {
        let gate = StatusSoundResolutionGate(sound: resolvedSound)
        self.gate = gate
        player = StatusSoundPlayer(resolve: { name in name == "held" ? gate.resolve() : resolvedSound })
        server = ControlServer(library: library, actions: AppActions(library: library), settingsModel: settings,
                               identity: AppIdentity(version: "test", commit: "test"),
                               statusSoundPlayer: player,
                               socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    private func update(target: String? = nil, soundName: String? = "held", status: AgentStatus = .blocked,
                        pane: StatusPane? = nil, paneID: String? = nil) async -> ControlResponse {
        let update = ControlSessionStatusUpdate(status: status, blink: nil, autoReset: nil, sound: soundName, pane: pane, paneID: paneID)
        return await server.setSessionStatus(target, window: nil, update: update)
    }
}
