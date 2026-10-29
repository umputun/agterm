import agtermCore
import Foundation

extension AppActions {
    /// Opens a companion of `id`, a sibling when `id` is itself a companion, and selects it. Store-scoped like
    /// `duplicateSession(_:in:)`.
    func newCompanion(_ id: UUID, in store: AppStore) {
        guard case .success(let companion) = store.addCompanion(to: id) else { return }
        store.noteUserActivity()
        store.selectSession(companion.id)
        focusActiveSession()
    }

    func newCompanionOfActiveSession() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID else { return }
        newCompanion(id, in: store)
    }
}
