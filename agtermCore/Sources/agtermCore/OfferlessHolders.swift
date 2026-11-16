import Foundation

/// OfferlessHolders records, by ask, pick or page id, the viewers without `offer.id` that gave that piece up while
/// still connected. Such a viewer echoes no offer, so a reply to its old copy would read as one to a new hand-over:
/// the piece is never handed to it again.
@MainActor
final class OfferlessHolders {
    static let shared = OfferlessHolders()
    private var holders: [String: Set<Int>] = [:]

    func record(_ owner: Int, gaveUp id: String) { holders[id, default: []].insert(owner) }

    func held(_ id: String, by owner: Int) -> Bool { holders[id]?.contains(owner) == true }

    func forget(_ id: String) { holders[id] = nil }
}

extension AppStore {
    /// noteGivenUp records that viewer `owner` gave up piece `id` while connected, when it echoes no offers.
    func noteGivenUp(_ id: String, by owner: Int?) {
        guard let owner, let hub = presentationHub, hub.isConnected(owner: owner),
              !hub.supports(PresentationHub.offerIdentityKind, owner: owner) else { return }
        OfferlessHolders.shared.record(owner, gaveUp: id)
    }

    /// mayHandOver is whether piece `id` can go to viewer `owner`: not one without offers that already gave it up.
    func mayHandOver(_ id: String, to owner: Int) -> Bool { !OfferlessHolders.shared.held(id, by: owner) }
}
