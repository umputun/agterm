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

@MainActor struct CompanionGroup {
    let store: AppStore
    let work: Workspace
    let personal: Workspace
    let parent: Session
    let first: Session
    let second: Session
    let after: Session

    init() throws {
        store = makeStore()
        work = store.addWorkspace(name: "work")
        personal = store.addWorkspace(name: "personal")
        guard let parent = store.addSession(toWorkspace: work.id, cwd: "/parent"),
              let after = store.addSession(toWorkspace: work.id, cwd: "/after") else { throw CompanionGroupFailure.setup }
        self.parent = parent
        self.after = after
        first = try store.addCompanion(to: parent.id, options: CompanionOptions(cwd: "/first")).get()
        second = try store.addCompanion(to: parent.id, options: CompanionOptions(cwd: "/second")).get()
    }

    var order: [UUID] { store.workspaces[0].sessions.map(\.id) }
}

enum CompanionGroupFailure: Error {
    case setup
}

final class SpySurface: PaneRoleMutableSurface {
    var teardownCount = 0
    var promotedCount = 0
    var assignedRoles: [SwappablePaneRole] = []
    var paneToken: String
    var backedByZmx: Bool
    /// Defaults to a live terminal, the state a surface parked in a session slot reaches a beat later; the
    /// stranded-slot cases set it false.
    var isRealized = true
    init(paneToken: String = "", backedByZmx: Bool = false) {
        self.paneToken = paneToken
        self.backedByZmx = backedByZmx
    }
    func teardown() { teardownCount += 1 }
    func promoteToPrimaryPane() { promotedCount += 1 }
    func setPaneRole(_ role: SwappablePaneRole) { assignedRoles.append(role) }
}
