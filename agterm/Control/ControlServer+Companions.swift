import agtermCore
import Foundation

extension ControlServer {
    static let companionMoveError = "a companion moves only among its siblings"

    func createCompanion(_ target: String?, options: CompanionOptions, window: String?) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            switch store.addCompanion(to: id, options: options) {
            case .failure(.remoteParent):
                return ControlResponse(ok: false, error: "companions of a remote session are not supported yet")
            case .failure(.noSuchSession):
                return ControlResponse(ok: false, error: "could not create companion")
            case .success(let companion):
                if options.select, store === library.activeStore { actions.focusActiveSession() }
                return ControlResponse(ok: true, result: ControlResult(id: companion.id.uuidString,
                                                                       parent: companion.parentID?.uuidString))
            }
        }
    }

    // a batch of companions alone that moved nothing was refused, while one carrying a parent may be a no-op
    func refusesCompanionMove(_ ids: [UUID], in store: AppStore) -> Bool {
        ids.allSatisfy { store.session(withID: $0)?.parentID != nil }
    }

    /// closeRoots are the ids a close acts on: a companion named beside its parent leaves the list, since the
    /// parent's close takes it and records it in the parent's group.
    func closeRoots(_ ids: [UUID], in store: AppStore) -> [UUID] {
        let named = Set(ids)
        return ids.filter { store.session(withID: $0)?.parentID.map(named.contains) != true }
    }

    /// The ids a close of `ids` removes, each root followed by its companions; computed before the close
    /// because the companions are gone after it.
    func closingGroup(_ ids: [UUID], in store: AppStore) -> [UUID] {
        closeRoots(ids, in: store).flatMap { [$0] + store.companions(of: $0).map(\.id) }
    }

    func setSessionExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            guard actions.setSessionExpanded(id, expanded: expanded, in: store) else {
                return ControlResponse(ok: false, error: "session has no companions")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
