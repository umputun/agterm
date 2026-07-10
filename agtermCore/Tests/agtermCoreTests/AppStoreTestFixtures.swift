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

final class SpySurface: TerminalSurface {
    var teardownCount = 0
    func teardown() { teardownCount += 1 }
}
