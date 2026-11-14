import Foundation
import agtermCore

/// Reopen and Undo for rows attached from another host: both run on the row's origin through `RemoteAttaching`, and
/// a refusal is shown as a failed command since nothing changed here.
extension AppActions {
    /// openAttachedRecent shows an attached row's closed session again, attached anew or reopened on its origin.
    func openAttachedRecent(_ id: UUID) {
        guard uiActionsEnabled, let remoteAttacher else { return }
        Task { @MainActor in
            let reply = await remoteAttacher.reopenAttached(id, window: nil)
            guard !reply.ok else { return }
            NotificationManager.shared.notifyCommandFailure(name: "Reopen Last Closed Item", detail: reply.error ?? "not reopened")
        }
    }

    /// newestAttachedRecent is the newest attached row's entry when it is newer than every local one.
    var newestAttachedRecent: RemoteRecentClosedItem? {
        guard let remote = library.remoteRecentClosedItems.first else { return nil }
        guard let local = library.recentClosedItems.first else { return remote }
        return remote.closedAt > local.closedAt ? remote : nil
    }

    /// undoOriginCloseIfNewer undoes the newest terminate of attached rows asked for in `store`'s window, on their origin,
    /// when it was asked for after `store`'s own pending close; false leaves ⌘Z to the local undo.
    func undoOriginCloseIfNewer(than store: AppStore) -> Bool {
        guard let remoteAttacher, let window = library.windowID(for: store), let newest = library.attachedUndos[window]?.last,
              newest.initiated > (store.pendingCloseSummary?.closedAt ?? .distantPast),
              let undo = library.takeAttachedUndo(window: window) else { return false }
        Task { @MainActor in
            let reply = await remoteAttacher.undoOriginClose(undo, window: window.uuidString)
            guard !reply.ok else { return }
            NotificationManager.shared.notifyCommandFailure(name: "Reopen Closed Item", detail: reply.error ?? "not undone")
        }
        return true
    }
}
