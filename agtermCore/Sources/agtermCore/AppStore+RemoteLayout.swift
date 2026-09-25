import Foundation

extension AppStore {
    /// Applies layout to existing replicas and returns local identities eligible for confirmed-removal handling.
    @discardableResult
    public func applyRemoteLayout(_ layout: PresentationLayout, forSession id: UUID) -> [UUID] {
        guard layout.isValid, let session = session(withID: id),
              let binding = session.remotePresentation?.binding else { return [] }
        session.remotePresentation?.layout = layout
        if let split = session.splitPaneIdentity, session.hasSplit,
           session.surface?.isRealized == true, session.splitSurface?.isRealized == true,
           let primaryOrigin = binding.remotePane(forLocal: session.paneIdentity),
           let splitOrigin = binding.remotePane(forLocal: split),
           Set(layout.panes) == Set([primaryOrigin, splitOrigin]) {
            if binding.localPane(forRemote: layout.primary) == split {
                guard swapPanes(id) == nil else { return [] }
            }
            if let axis = layout.axis.flatMap(SplitAxis.init(rawValue:)) {
                session.splitAxis = axis
            }
            setSplitVisibility(id, shown: layout.shown)
        }
        return [session.splitPaneIdentity, session.paneIdentity].compactMap { $0 }.filter {
            canCloseRemovedRemotePane($0, forSession: id)
        }
    }

    /// Whether confirmed origin removal permits closing this replica without discarding a pending local split.
    public func canCloseRemovedRemotePane(_ local: UUID, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), session.paneRole(forIdentity: local) != nil,
              let state = session.remotePresentation, let layout = state.layout,
              let remote = state.binding.remotePane(forLocal: local), !layout.panes.contains(remote) else { return false }
        // ordinary primary close would discard a local split that has not produced its surface yet
        if local == session.paneIdentity, let split = session.splitPaneIdentity,
           state.binding.remotePane(forLocal: split) == nil, session.splitSurface?.isRealized != true { return false }
        return true
    }

    /// Records an SSH exit held by the current mapped replica, for a later removal frame.
    public func remotePaneHeld(_ local: UUID, forSession id: UUID) {
        guard let session = session(withID: id), session.paneRole(forIdentity: local) != nil,
              session.remotePresentation?.binding.remotePane(forLocal: local) != nil else { return }
        session.remotePresentation?.heldPanes.insert(local)
    }

    /// Whether a held exit was recorded for this local replica identity.
    public func remotePaneIsHeld(_ local: UUID, forSession id: UUID) -> Bool {
        session(withID: id)?.remotePresentation?.heldPanes.contains(local) == true
    }

    /// The held replica attached again.
    public func remotePaneResumed(_ local: UUID, forSession id: UUID) {
        session(withID: id)?.remotePresentation?.heldPanes.remove(local)
    }
}
