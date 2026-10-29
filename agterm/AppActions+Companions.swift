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

    /// Persists a parent's fold, then posts the store-scoped notification the live outline follows; false for
    /// a session without companions. The persist does not ride the notification, which a hidden sidebar drops.
    @discardableResult
    func setSessionExpanded(_ id: UUID, expanded: Bool, in store: AppStore) -> Bool {
        guard store.setSessionExpanded(id, expanded: expanded) else { return false }
        NotificationCenter.default.post(
            name: .agtermSetSessionExpanded, object: store,
            userInfo: [WorkspaceSidebar.Coordinator.sessionIDUserInfoKey: id,
                       WorkspaceSidebar.Coordinator.expandedUserInfoKey: expanded])
        return true
    }

    func newCompanionOfActiveSession() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID else { return }
        newCompanion(id, in: store)
    }
}
