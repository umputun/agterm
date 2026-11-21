import Foundation

/// PresenterGrant decides which viewer connection is a session's fallback presenter, the one that takes new work for a
/// pane no viewer reports leading. The first acquire wins and keeps the role until its connection goes; nothing
/// preempts it and nothing hands it back early.
struct PresenterGrant {
    private var holders: [UUID: PresentationHub.SubscriberID] = [:]

    /// Grants `session` to `subscriber` when nobody holds it. True when `subscriber` holds it afterwards.
    mutating func acquire(session: UUID, by subscriber: PresentationHub.SubscriberID) -> Bool {
        guard let holder = holders[session] else {
            holders[session] = subscriber
            return true
        }
        return holder == subscriber
    }

    /// Takes the role back from a connection that went away. Returns the sessions it held.
    mutating func release(_ subscriber: PresentationHub.SubscriberID) -> [UUID] {
        let held = holders.filter { $0.value == subscriber }.map(\.key)
        for session in held { holders[session] = nil }
        return held
    }

    func holder(of session: UUID) -> PresentationHub.SubscriberID? { holders[session] }
}
