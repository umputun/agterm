import XCTest
@testable import agterm
import agtermCore

@MainActor
final class LiveResetCoordinatorTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-live-reset-coordinator-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
            XCTAssertTrue(settingsModel.setRestoreMode(.live))
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            settingsModel = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    private static let selection = LiveReset.Selection(
        targets: [LiveReset.Target(paneIdentity: UUID(), sessionID: UUID(), daemon: "agterm-a", leaderPID: 10)],
        inventoryComplete: true)

    private final class Log {
        var refusals: [LiveResetCoordinator.Refusal] = []
        var terminations = 0
        var confirmations: [Int] = []
    }

    private func makeCoordinator(selection: LiveReset.Selection?, answer: Bool = true) -> (LiveResetCoordinator, Log) {
        let log = Log()
        let coordinator = LiveResetCoordinator(settingsModel: settingsModel, selection: { selection },
                                               activeMode: { .live }, terminate: { log.terminations += 1 })
        coordinator.confirm = { log.confirmations.append($0); return answer }
        coordinator.presentRefusal = { log.refusals.append($0) }
        return (coordinator, log)
    }

    func testMenuRefusalIsPresented() {
        let (listingFailed, log1) = makeCoordinator(selection: nil)
        listingFailed.runFromMenu()
        XCTAssertEqual(log1.refusals, [.listingFailed])
        XCTAssertEqual(log1.terminations, 0)

        let (nothing, log2) = makeCoordinator(selection: LiveReset.Selection(targets: [], inventoryComplete: true))
        nothing.runFromMenu()
        XCTAssertEqual(log2.refusals, [.nothingToReset])
        XCTAssertTrue(log2.confirmations.isEmpty, "a refusal never reaches the dialog")
    }

    func testMenuCancelIsSilent() {
        let (coordinator, log) = makeCoordinator(selection: Self.selection, answer: false)

        coordinator.runFromMenu()

        XCTAssertEqual(log.confirmations, [1])
        XCTAssertTrue(log.refusals.isEmpty)
        XCTAssertEqual(log.terminations, 0)
        XCTAssertNil(coordinator.pending)
    }

    func testMenuConfirmTerminates() {
        let (coordinator, log) = makeCoordinator(selection: Self.selection)

        coordinator.runFromMenu()

        XCTAssertEqual(log.confirmations, [1])
        XCTAssertEqual(log.terminations, 1)
        XCTAssertEqual(coordinator.armablePending, Self.selection)
    }

    func testPendingIsNotArmableAfterAModeChange() {
        let (coordinator, log) = makeCoordinator(selection: Self.selection)
        XCTAssertEqual(coordinator.request(confirmed: true), .confirmed(Self.selection))

        XCTAssertTrue(settingsModel.setRestoreMode(.rerun))

        XCTAssertNotNil(coordinator.pending)
        XCTAssertNil(coordinator.armablePending, "a reset confirmed before a mode change must not arm")
        coordinator.terminateIfPending()
        XCTAssertEqual(log.terminations, 0)
    }

    func testUserMessagesNameNoInternals() {
        for refusal in [LiveResetCoordinator.Refusal.notLive, .listingFailed, .inventoryIncomplete, .nothingToReset] {
            let text = refusal.userMessage.lowercased()
            XCTAssertFalse(text.contains("zmx") || text.contains("daemon") || text.contains("attribut"), refusal.userMessage)
        }
    }
}
