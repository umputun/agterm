import Foundation

/// PresenterGrant decides which viewer connection is a session's sole presenter. The first acquire wins and
/// keeps the role until its connection goes; nothing preempts it and nothing hands it back early.
///
/// Every change of holder bumps the session's generation, which is what later work owned by a presenter is
/// bound to, so an answer from a connection that lost the role can be told apart from a current one.
struct PresenterGrant {
    private var holders: [UUID: PresentationHub.SubscriberID] = [:]
    private var generations: [UUID: Int] = [:]

    /// Grants `session` to `subscriber` when nobody holds it. True when `subscriber` holds it afterwards.
    mutating func acquire(session: UUID, by subscriber: PresentationHub.SubscriberID) -> Bool {
        guard let holder = holders[session] else {
            holders[session] = subscriber
            generations[session, default: 0] += 1
            return true
        }
        return holder == subscriber
    }

    /// Takes the role back from a connection that went away. Returns the sessions it held.
    mutating func release(_ subscriber: PresentationHub.SubscriberID) -> [UUID] {
        let held = holders.filter { $0.value == subscriber }.map(\.key)
        for session in held {
            holders[session] = nil
            generations[session, default: 0] += 1
        }
        return held
    }

    func holder(of session: UUID) -> PresentationHub.SubscriberID? { holders[session] }

    func generation(of session: UUID) -> Int { generations[session, default: 0] }
}
