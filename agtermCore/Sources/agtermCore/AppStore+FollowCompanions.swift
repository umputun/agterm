import Foundation

/// CompanionFollow is what an attached row does with its origin's membership list: the members to attach under it, in
/// origin order, and the ids to remember without attaching, since this Mac already shows them.
public struct CompanionFollow: Equatable, Sendable {
    public var attach: [PresentationCompanions.Member]
    public var markOnly: [String]

    public init(attach: [PresentationCompanions.Member], markOnly: [String]) {
        self.attach = attach
        self.markOnly = markOnly
    }
}

// MARK: - Following an origin's companions on an attached row

extension AppStore {
    /// companionsToFollow is what row `id` does with `list`: every member it has not handled yet, unless `shown` (origin
    /// ids this Mac already shows anywhere) names it. A row not yet baselined follows nothing.
    public func companionsToFollow(_ list: PresentationCompanions, forSession id: UUID, shown: Set<String>) -> CompanionFollow {
        var follow = CompanionFollow(attach: [], markOnly: [])
        guard let session = session(withID: id), session.companionsBaselined else { return follow }
        let shown = Set(shown.map(Self.originID))
        for member in list.members where !session.followedCompanions.contains(member.id.uuidString) {
            if shown.contains(member.id.uuidString) {
                follow.markOnly.append(member.id.uuidString)
            } else {
                follow.attach.append(member)
            }
        }
        return follow
    }

    /// baselineCompanions takes `ids`, the origin companions listed when row `id` was attached or in its first membership
    /// list, as handled: none of them is attached by itself.
    public func baselineCompanions(_ ids: [String], forSession id: UUID) {
        guard let session = session(withID: id) else { return }
        session.followedCompanions.formUnion(ids.map(Self.originID))
        session.companionsBaselined = true
        save()
    }

    /// markFollowed records origin ids row `id` has handled, whether or not it has taken its first list yet, and while an
    /// undoable close holds it.
    public func markFollowed(_ ids: [String], forSession id: UUID) {
        let visible = session(withID: id)
        guard let session = visible ?? pendingCloseSession(withID: id) else { return }
        let marks = ids.map(Self.originID)
        guard !session.followedCompanions.isSuperset(of: marks) else { return }
        session.followedCompanions.formUnion(marks)
        // a save now would drop a parked row from disk before its close is final; undo saves it with the mark
        if visible != nil { save() }
    }

    /// setFollowsCompanions records whether row `id` holds its origin's companion list, for the `tree` read-back.
    public func setFollowsCompanions(_ follows: Bool, forSession id: UUID) {
        session(withID: id)?.remotePresentation?.followsCompanions = follows
    }

    // origin ids arrive in either case from a tree or a binding; membership frames carry the canonical form
    private static func originID(_ id: String) -> String {
        UUID(uuidString: id)?.uuidString ?? id
    }
}
