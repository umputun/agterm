import Foundation
@testable import agtermCore

/// A store backed by a throwaway temp directory so mutation-time saves never
/// touch the real Application Support path. PersistenceStore creates the
/// directory lazily on first write.
@MainActor func makeStore() -> AppStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
    return AppStore(persistence: PersistenceStore(directory: dir))
}

/// The same throwaway store, plus the Open Recent store it records closes into and the persistence it
/// writes through, for the paths that read back what a close or a restore persisted.
@MainActor func makeStoreWithRecentClosed() -> (AppStore, RecentClosedStore, PersistenceStore) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
    let recentClosed = RecentClosedStore(directory: dir)
    let persistence = PersistenceStore(directory: dir)
    return (AppStore(persistence: persistence, recentClosedStore: recentClosed), recentClosed, persistence)
}

final class SpySurface: PaneRoleMutableSurface {
    var teardownCount = 0
    var promotedCount = 0
    var assignedRoles: [SwappablePaneRole] = []
    var paneToken: String
    /// Defaults to a live terminal, the state a surface parked in a session slot reaches a beat later; the
    /// stranded-slot cases set it false.
    var isRealized = true
    init(paneToken: String = "") { self.paneToken = paneToken }
    func teardown() { teardownCount += 1 }
    func promoteToPrimaryPane() { promotedCount += 1 }
    func setPaneRole(_ role: SwappablePaneRole) { assignedRoles.append(role) }
}
