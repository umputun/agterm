import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreSidebarTests {
    @Test(arguments: [(300.0, 300.0), (120.0, 160.0), (900.0, 560.0)])
    func setSidebarWidthClampsToDragBounds(_ requested: Double, _ applied: Double) {
        let store = makeStore()

        store.setSidebarWidth(requested)

        #expect(store.sidebarWidth == applied)
    }

    @Test func setSidebarWidthKeepsFractionalPoints() {
        let store = makeStore()

        store.setSidebarWidth(271.34)

        #expect(store.sidebarWidth == 271.34)
    }

    @Test func setSidebarWidthWritesThroughToDisk() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)

        store.setSidebarWidth(271.3)

        #expect(persistence.load().sidebarWidth == 271.3)
    }

    @Test func setSidebarWidthToTheCurrentClampedValueDoesNotWrite() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let persistence = PersistenceStore(directory: dir)
        let store = AppStore(persistence: persistence)
        store.setSidebarWidth(900) // clamps to the max and saves
        let file = dir.appendingPathComponent("workspaces.json")
        try? FileManager.default.removeItem(at: file) // a no-op setter must NOT recreate the file

        store.setSidebarWidth(1200) // clamps to the same max → no save

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.sidebarWidth == AppStore.sidebarWidthMax)
    }

    @Test func restoreClampsAnOutOfRangeSnapshotWidth() {
        let store = makeStore()

        store.restore(from: Snapshot(workspaces: [], sidebarWidth: 9000))

        #expect(store.sidebarWidth == AppStore.sidebarWidthMax)
    }

    @Test func controlTreeReportsSidebarWidth() {
        let store = makeStore()

        store.setSidebarWidth(340)

        #expect(store.controlTree().sidebarWidth == 340)
    }
}
