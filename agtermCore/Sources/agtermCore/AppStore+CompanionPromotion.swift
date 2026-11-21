import Foundation

/// CompanionPromotion is where a companion made a top-level session lands.
public enum CompanionPromotion: Equatable, Sendable {
    /// afterOwnGroup lands right after the group the companion leaves.
    case afterOwnGroup
    /// workspace lands before the `slot`th top-level session of the workspace, nil or past the end appending.
    case workspace(UUID, slot: Int?)
    /// beside lands before or after the whole group of session `anchor`, its former parent's included.
    case beside(UUID, after: Bool)
}

/// CompanionPromotionRefusal is why a companion did not become a top-level session; `message` is the text callers show.
public enum CompanionPromotionRefusal: Error, Equatable, Sendable {
    case noSuchSession
    case notCompanion
    case noSuchWorkspace
    case ownAnchor

    public var message: String {
        switch self {
        case .noSuchSession: "no such session"
        case .notCompanion: "not a companion"
        case .noSuchWorkspace: "no such workspace"
        case .ownAnchor: "a session cannot be placed beside itself"
        }
    }
}

extension AppStore {
    /// canPromoteCompanion answers whether `promoteCompanion` accepts this placement, without moving.
    public func canPromoteCompanion(_ id: UUID, to placement: CompanionPromotion) -> Result<Void, CompanionPromotionRefusal> {
        promotionTarget(id, placement).map { _ in () }
    }

    /// promoteCompanion makes companion `id` a top-level session at `placement`, keeping the same `Session` object so its
    /// surfaces survive.
    @discardableResult
    public func promoteCompanion(_ id: UUID, to placement: CompanionPromotion) -> Result<Void, CompanionPromotionRefusal> {
        switch promotionTarget(id, placement) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let target):
            guard let row = session(withID: id) else { return .failure(.noSuchSession) }
            row.parentID = nil
            relocate([id], toWorkspace: target.workspace, before: target.anchor, parentChanged: true)
            if row.remoteHost != nil { onRemoteRowPromoted?(row) }
            return .success(())
        }
    }

    private func promotionTarget(_ id: UUID, _ placement: CompanionPromotion) -> Result<(workspace: Int, anchor: UUID?), CompanionPromotionRefusal> {
        guard let row = session(withID: id), let source = location(ofSession: id) else { return .failure(.noSuchSession) }
        guard let parentID = row.parentID else { return .failure(.notCompanion) }
        switch placement {
        case .afterOwnGroup:
            return .success((source.workspaceIndex, topLevel(after: parentID, in: source.workspaceIndex)))
        case .workspace(let workspaceID, let slot):
            guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return .failure(.noSuchWorkspace) }
            let roots = workspaces[index].sessions.filter { $0.parentID == nil }
            return .success((index, slot.flatMap { roots.indices.contains(max(0, $0)) ? roots[max(0, $0)].id : nil }))
        case .beside(let anchorID, let after):
            guard anchorID != id else { return .failure(.ownAnchor) }
            guard let anchor = session(withID: anchorID) else { return .failure(.noSuchSession) }
            let root = anchor.parentID ?? anchorID
            guard let location = location(ofSession: root) else { return .failure(.noSuchSession) }
            return .success((location.workspaceIndex, after ? topLevel(after: root, in: location.workspaceIndex) : root))
        }
    }

    /// promotionPlacement is `placement` as the anchor an owner elsewhere places companion `id` by, nil for
    /// `afterOwnGroup`: a workspace slot names the top-level session it lands before, since the owner's workspace can
    /// hold rows this store does not show.
    public func promotionPlacement(of id: UUID, _ placement: CompanionPromotion) -> RemoteSessionPlacement? {
        switch placement {
        case .afterOwnGroup:
            return nil
        case .workspace(let workspaceID, let slot):
            let roots = workspaces.first { $0.id == workspaceID }?.sessions.filter { $0.parentID == nil && $0.id != id }.map(\.id) ?? []
            return RemoteOperation.promotionPlacement(workspace: workspaceID, slot: slot, roots: roots)
        case .beside(let anchor, let after):
            return after ? .after(anchor) : .before(anchor)
        }
    }

    // the top-level session after `root`'s group in workspace `index`, nil when that group is last
    private func topLevel(after root: UUID, in index: Int) -> UUID? {
        let roots = workspaces[index].sessions.filter { $0.parentID == nil }.map(\.id)
        guard let position = roots.firstIndex(of: root), position + 1 < roots.count else { return nil }
        return roots[position + 1]
    }
}
