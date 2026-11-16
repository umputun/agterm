import Foundation

/// RemoteAskOffers holds, by ask id, the offer each remotely presented ask was last handed over under: nil for a
/// viewer that does not echo offers.
@MainActor
final class RemoteAskOffers {
    static let shared = RemoteAskOffers()
    private var offers: [String: Int] = [:]

    func set(_ offer: Int?, ask id: String) { offers[id] = offer }

    /// matches is whether a reply echoing `offer` is about the ask's current hand-over.
    func matches(_ offer: Int?, ask id: String) -> Bool { offers[id] == offer }

    func forget(ask id: String) { offers[id] = nil }
}
