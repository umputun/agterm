import agtermCore
import Foundation

/// CompanionDuplicating plans and creates Duplicate as Companion, which reads the panes' processes.
@MainActor
protocol CompanionDuplicating: AnyObject {
    func duplicateCompanion(of id: UUID, in store: AppStore, select: Bool) -> Result<Session, CompanionDuplicateFailure>
}

/// CompanionDuplicateFailure is why Duplicate as Companion created nothing.
struct CompanionDuplicateFailure: Error {
    let message: String
}

extension AppActions {
    /// Opens a companion of `id`, a sibling when `id` is itself a companion, and selects it. Store-scoped like
    /// `duplicateSession(_:in:)`.
    func newCompanion(_ id: UUID, in store: AppStore) {
        if store.session(withID: id)?.remoteHost != nil {
            return createRemoteCompanion(.terminal(CompanionOptions()), of: id, in: store, action: "New Companion")
        }
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

    func duplicateAsCompanion(_ id: UUID, in store: AppStore) {
        if store.session(withID: id)?.remoteHost != nil {
            return createRemoteCompanion(.duplicate, of: id, in: store, action: "Duplicate as Companion")
        }
        guard let companionDuplicator else { return }
        switch companionDuplicator.duplicateCompanion(of: id, in: store, select: true) {
        case .failure(let failure):
            NotificationManager.shared.notifyCommandFailure(name: "Duplicate as Companion", detail: failure.message)
        case .success:
            store.noteUserActivity()
            focusActiveSession()
        }
    }

    /// createRemoteCompanion has the origin of a remote row create the companion and attaches it here, showing the
    /// two ssh waits and a failure in a HUD over the row.
    private func createRemoteCompanion(_ request: RemoteCompanionRequest, of id: UUID, in store: AppStore, action: String) {
        guard let remoteAttacher, let windowID = library.windowID(for: store) else { return }
        let hud = RemoteAttachHud(attacher: remoteAttacher, session: id.uuidString, window: windowID.uuidString, action: action)
        Task {
            let reply = await remoteAttacher.createRemoteCompanion(request, of: id, in: store, select: true) { hud.progress($0) }
            if reply.ok {
                hud.close()
                store.noteUserActivity()
            } else {
                hud.fail(reply.error ?? "the companion was not created")
            }
        }
    }

    func duplicateActiveSessionAsCompanion() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID else { return }
        duplicateAsCompanion(id, in: store)
    }

    func newCompanionOfActiveSession() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID else { return }
        newCompanion(id, in: store)
    }
}
