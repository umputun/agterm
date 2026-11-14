import Foundation

/// RemoteAttachLines builds the command attaching an origin daemon into a row attached from another host, for a pane
/// or scratch the origin added after the attach.
@MainActor
public protocol RemoteAttachLines: AnyObject {
    func paneAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String
    func scratchAttach(_ origin: RemoteBinding.Origin, daemon: String, local: UUID) -> String
}

extension AppStore {
    /// applyRemoteLayout applies layout to the row's replicas, attaching a split or scratch the origin added after
    /// the attach, and returns local identities eligible for confirmed-removal handling.
    @discardableResult
    public func applyRemoteLayout(_ layout: PresentationLayout, forSession id: UUID, attach: RemoteAttachLines) -> [UUID] {
        guard layout.isValid, let session = session(withID: id),
              let binding = session.remotePresentation?.binding, !binding.catalogOwned else { return [] }
        session.remotePresentation?.layout = layout
        if let origin = binding.origin {
            addOriginSplit(session, layout: layout, binding: binding, origin: origin, attach: attach)
            applyOriginScratch(session, layout: layout, binding: binding, origin: origin, attach: attach)
        }
        let current = session.remotePresentation?.binding ?? binding
        if let split = session.splitPaneIdentity, session.hasSplit,
           let primaryOrigin = current.remotePane(forLocal: session.paneIdentity),
           let splitOrigin = current.remotePane(forLocal: split),
           Set(layout.panes) == Set([primaryOrigin, splitOrigin]) {
            // a replica whose attach has not realized its surface yet moves as a slot, as a catalog row's does
            let realized = session.surface?.isRealized == true && session.splitSurface?.isRealized == true
            if layout.primary == splitOrigin {
                guard swapPanes(id, allowingUnrealized: !realized) == nil else { return [] }
            }
            if realized {
                if let axis = layout.axis.flatMap(SplitAxis.init(rawValue:)) {
                    session.splitAxis = axis
                }
                setSplitVisibility(id, shown: layout.shown)
            }
        }
        return [session.splitPaneIdentity, session.paneIdentity].compactMap { $0 }.filter {
            canCloseRemovedRemotePane($0, forSession: id)
        }
    }

    /// attachOriginAdditions attaches a pane the saved layout lists once a removal here freed the split slot for it.
    public func attachOriginAdditions(forSession id: UUID, attach: RemoteAttachLines) {
        guard let session = session(withID: id), let state = session.remotePresentation, !state.binding.catalogOwned,
              let origin = state.binding.origin, let layout = state.layout else { return }
        addOriginSplit(session, layout: layout, binding: state.binding, origin: origin, attach: attach)
    }

    /// addOriginSplit attaches a pane the origin added after the attach into the row's empty split slot. A pane the
    /// binding already maps is never added again, so a replica closed here stays closed.
    private func addOriginSplit(_ session: Session, layout: PresentationLayout, binding: RemoteBinding,
                                origin: RemoteBinding.Origin, attach: RemoteAttachLines) {
        guard !session.hasSplit, let added = layout.panes.first(where: { binding.localPane(forRemote: $0) == nil }) else { return }
        let local = UUID()
        let daemon = ZmxSupport.daemonName(for: added)
        session.remotePresentation?.binding = binding.adding(local: local, daemon: daemon)
        session.hasSplit = true
        session.splitPaneIdentity = local
        session.splitAxis = layout.axis.flatMap(SplitAxis.init(rawValue:)) ?? .leftRight
        session.splitInitialCommand = attach.paneAttach(origin, daemon: daemon, local: local)
        session.splitCommandWait = true
        session.isSplit = layout.shown
        if layout.shown { emitPaneVisibility(.paneSplit, session: session, shown: true) }
        save()
        scheduleTreeChanged()
    }

    /// applyOriginScratch keeps a row's scratch on its origin's once the origin publishes one: a shown one attaches
    /// its daemon, a hidden one keeps its surface, and a replaced or gone one, or a scratch of this Mac's, closes.
    private func applyOriginScratch(_ session: Session, layout: PresentationLayout, binding: RemoteBinding,
                                    origin: RemoteBinding.Origin, attach: RemoteAttachLines) {
        guard let shown = layout.scratchShown else { return }
        let identity = layout.scratch
        if session.scratchDaemon?.identity != identity || (identity == nil && session.scratchSurface != nil) {
            // between two attaches there is no surface to close, and what the old scratch owned still goes
            if !closeScratch(session.id), session.scratchActive { toggleScratch(session.id) }
            if let current = session.scratchDaemon { releaseScratchOwnedState(of: session, token: current.identity.uuidString) }
            session.scratchCommand = nil
            session.scratchDaemon = identity.map { Session.ScratchDaemon(identity: $0, shown: shown) }
            session.originScratchClient = nil
            scheduleTreeChanged()
        }
        guard let identity else { return }
        session.scratchDaemon?.shown = shown
        let client = session.originScratchClient ?? UUID()
        session.originScratchClient = client
        if shown, session.scratchSurface == nil, session.scratchCommand == nil {
            session.scratchCommand = attach.scratchAttach(origin, daemon: binding.scratchDaemon(for: identity), local: client)
        }
        if session.scratchActive != shown { toggleScratch(session.id) }
    }

    /// originScratchStopped marks row `id`'s origin scratch attach as ended while the saved layout still lists that
    /// scratch, answering the row's key for it to reconnect; nil when the layout no longer has it.
    public func originScratchStopped(_ id: UUID) -> UUID? {
        guard let row = session(withID: id), row.scratchFollowsOrigin, row.scratchSurface != nil,
              let identity = row.scratchDaemon?.identity, row.remotePresentation?.layout?.scratch == identity,
              let client = row.scratchClientIdentity else { return nil }
        row.scratchStoppedGeneration = row.scratchGeneration
        return client
    }

    /// replaceOriginScratchAttachment swaps a stopped origin scratch attach for a fresh one, leaving it shown or hidden as
    /// the origin has it. False when the layout changed that scratch or another attach already replaced it.
    public func replaceOriginScratchAttachment(_ id: UUID, identity: UUID, attach: RemoteAttachLines) -> Bool {
        guard let row = session(withID: id), row.scratchFollowsOrigin, let binding = row.remotePresentation?.binding,
              let origin = binding.origin, row.remotePresentation?.layout?.scratch == identity,
              row.scratchDaemon?.identity == identity, row.scratchStoppedGeneration == row.scratchGeneration,
              let client = row.scratchClientIdentity else { return false }
        replaceScratchSurface(row, command: attach.scratchAttach(origin, daemon: binding.scratchDaemon(for: identity), local: client))
        return true
    }

    /// Whether confirmed origin removal permits closing this replica without discarding a pending local split.
    public func canCloseRemovedRemotePane(_ local: UUID, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), session.paneRole(forIdentity: local) != nil,
              let state = session.remotePresentation, !state.binding.catalogOwned, let layout = state.layout,
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
