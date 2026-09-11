import XCTest
@testable import agterm
import agtermCore

@MainActor
final class LiveResetQuitTests: XCTestCase {
    private static let selection = LiveReset.Selection(
        targets: [LiveReset.Target(paneIdentity: UUID(), sessionID: UUID(), daemon: "agterm-a", leaderPID: 10)],
        inventoryComplete: true)

    private func flush(pending: LiveReset.Selection?, saveChecked: Bool = true, arm: Bool = true) -> (armed: Bool, order: [String]) {
        var order: [String] = []
        let armed = AppDelegate.exitFlush(pending: pending, steps: AppDelegate.ExitFlushSteps(
            capture: { order.append("capture") },
            finalize: { order.append("finalize") },
            saveChecked: { order.append("saveChecked"); return saveChecked },
            save: { order.append("save") },
            arm: { _ in order.append("arm"); return arm }))
        return (armed, order)
    }

    func testCaptureRunsBeforeCheckedSave() {
        let result = flush(pending: Self.selection)
        XCTAssertTrue(result.armed)
        XCTAssertEqual(result.order, ["capture", "finalize", "saveChecked", "arm"])
    }

    func testNoMarkerWhenSaveFails() {
        let result = flush(pending: Self.selection, saveChecked: false)
        XCTAssertFalse(result.armed)
        XCTAssertEqual(result.order, ["capture", "finalize", "saveChecked"])
    }

    func testOrdinaryQuitWritesNothing() {
        let result = flush(pending: nil)
        XCTAssertFalse(result.armed)
        XCTAssertEqual(result.order, ["capture", "finalize", "save"])
    }

    private func makeStore() throws -> (store: LiveResetMarkerStore, marker: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-live-reset-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (LiveResetMarkerStore(directory: dir), dir.appendingPathComponent(LiveReset.markerFilename), dir)
    }

    func testMarkerWrittenOnlyAfterCheckedSave() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        XCTAssertTrue(AppDelegate.armLiveReset(Self.selection, store: fixture.store) { true })

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.marker.path))
        XCTAssertEqual(try fixture.store.consume()?.targets, Self.selection.targets)
    }

    func testMarkerRemovedWhenSpawnerFails() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        var sawMarkerWhileSpawning = false

        let armed = AppDelegate.armLiveReset(Self.selection, store: fixture.store) {
            sawMarkerWhileSpawning = FileManager.default.fileExists(atPath: fixture.marker.path)
            return false
        }

        XCTAssertFalse(armed)
        XCTAssertTrue(sawMarkerWhileSpawning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
    }
}
