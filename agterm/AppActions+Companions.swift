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
        if performRemote(.newCompanion(parent: id), in: store, select: true) { return }
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
        if performRemote(.duplicateCompanion(id), in: store, select: true) { return }
        if store.session(withID: id)?.remoteHost != nil {
            return createRemoteCompanion(.duplicate, of: id, in: store, action: "Duplicate as Companion")
        }
        guard let companionDuplicator else { return }
        switch companionDuplicator.duplicateCompanion(of: id, in: store, select: true) {
        case .failure(let failure):
            guard let remoteAttacher, let windowID = library.windowID(for: store) else {
                return NotificationManager.shared.notifyCommandFailure(name: "Duplicate as Companion", detail: failure.message)
            }
            RemoteAttachHud(attacher: remoteAttacher, session: id.uuidString, window: windowID.uuidString,
                            action: "Duplicate as Companion").fail(failure.message)
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

    /// convertToCompanion shows refusals in a timed HUD, with notification fallback.
    func convertToCompanion(_ id: UUID, in store: AppStore) {
        if performRemote(.convertCompanion(id), in: store) { return }
        if forwardAttached(ControlRequest(cmd: .sessionCompanionConvert, target: id.uuidString), row: id, in: store,
                           action: "Convert to Companion") { return }
        switch store.convertToCompanion(id) {
        case .failure(let refusal):
            showCompanionRefusal(refusal.message, action: "Convert to Companion", over: id, in: store)
        case .success:
            store.noteUserActivity()
            focusActiveSession()
        }
    }

    /// moveCompanion puts a companion under another top-level session for the sidebar drop and the row menu; the
    /// control command calls the store itself, since this reports only through the HUD.
    func moveCompanion(_ id: UUID, under parentID: UUID, at index: Int?, in store: AppStore) {
        if let remote = store.remoteActions {
            // the slot counts the rows shown here; the server's group also holds the rows this window detached
            let visible = store.companions(of: parentID).map(\.id).filter { $0 != id }
            let group = remote.mirror.catalog?.workspaces.flatMap(\.sessions).filter { $0.fields.parent == parentID && $0.id != id }
                .map(\.id) ?? []
            let mapped = RemoteOperation.companionIndex(slot: index, visible: visible, group: group)
            _ = performRemote(.moveCompanion(id, parent: parentID, index: mapped), in: store)
            return
        }
        var args = ControlArgs()
        args.parent = parentID.uuidString
        args.index = index
        if forwardAttached(ControlRequest(cmd: .sessionCompanionMove, target: id.uuidString, args: args), row: id, in: store,
                           action: "Move Companion") { return }
        switch store.moveCompanion(id, under: parentID, at: index) {
        case .failure(let refusal):
            showCompanionRefusal(refusal.message, action: "Move Companion", over: id, in: store)
        case .success:
            store.noteUserActivity()
        }
    }

    /// promoteCompanion makes a companion a top-level session for the sidebar drop and the row menu, through the same
    /// server, origin or store path its control command takes.
    func promoteCompanion(_ id: UUID, to promotion: CompanionPromotion, in store: AppStore) {
        let action = "Make Top-Level Session"
        if case .failure(let refusal) = store.canPromoteCompanion(id, to: promotion) {
            return showCompanionRefusal(refusal.message, action: action, over: id, in: store)
        }
        let placement = store.promotionPlacement(of: id, promotion)
        if store.remoteActions != nil {
            _ = performRemote(.promoteCompanion(id, to: placement), in: store)
            return
        }
        var args = ControlArgs()
        switch placement {
        case .workspace(let workspace): args.workspace = workspace.uuidString
        case .after(let anchor): args.after = anchor.uuidString
        case .before(let anchor): args.before = anchor.uuidString
        case .step, nil: break
        }
        if forwardAttached(ControlRequest(cmd: .sessionCompanionPromote, target: id.uuidString, args: args), row: id, in: store,
                           action: action) { return }
        store.promoteCompanion(id, to: promotion)
        store.noteUserActivity()
    }

    // a refusal shows in a timed HUD over the session, falling back to a notification when there is no window for it
    private func showCompanionRefusal(_ message: String, action: String, over id: UUID, in store: AppStore) {
        guard let remoteAttacher, let windowID = library.windowID(for: store) else {
            return NotificationManager.shared.notifyCommandFailure(name: action, detail: message)
        }
        RemoteAttachHud(attacher: remoteAttacher, session: id.uuidString, window: windowID.uuidString, action: action).fail(message)
    }

    func convertActiveSessionToCompanion() {
        guard uiActionsEnabled else { return }
        guard let store, let id = store.selectedSessionID else { return }
        convertToCompanion(id, in: store)
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
