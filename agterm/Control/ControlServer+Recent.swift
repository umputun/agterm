import Foundation
import agtermCore

extension ControlServer {
    func listRecentClosed() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(recent: library.recentClosedItems.map(ControlRecentItem.init)))
    }

    /// The store swallows a failed write, so the reply is decided by the reloaded list, never by the call.
    func clearRecentClosed() -> ControlResponse {
        library.clearRecentClosedItems()
        guard library.recentClosedItems.isEmpty else {
            return ControlResponse(ok: false, error: "could not clear recent items")
        }
        return ControlResponse(ok: true)
    }

    /// Restores without raising or focusing the window, unlike the menu item: a script names the window
    /// it wants in front with `window select`.
    func openRecentClosed(_ target: String?, window: String?) -> ControlResponse {
        resolver.resolveOpenPlacementStore(window) { store in
            let items = library.recentClosedItems
            let id: UUID
            switch RecentClosedTarget.resolve(target, in: items) {
            case .failure(let error): return ControlResponse(ok: false, error: error.message)
            case .success(let resolved): id = resolved
            }
            guard let item = items.first(where: { $0.id == id }),
                  let outcome = library.reopenRecentClosedOutcome(id, into: store)
            else { return ControlResponse(ok: false, error: "could not reopen \(id.uuidString)") }
            let open = ControlRecentOpen(item: ControlRecentItem(item), window: outcome.window.uuidString,
                                         complete: outcome.complete)
            return ControlResponse(ok: true, result: ControlResult(recentOpen: open))
        }
    }
}
