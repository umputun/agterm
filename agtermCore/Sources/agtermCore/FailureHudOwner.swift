import Foundation

/// Who a posted HUD belongs to, so a delayed close can only take down the panel it opened.
///
/// The session id is not identity: a restored session carries the SAME UUID in a fresh object whose slot
/// generation starts again at zero (`AppStore.session(from:)`), so an id-and-generation pair alone would let
/// a stale timer close a panel it never posted. The object itself is held weakly — a session that has since
/// closed owns nothing, and nothing here keeps its store alive.
@MainActor
public struct FailureHudOwner {
    private weak var session: Session?
    private let generation: Int

    /// Records `session` and the slot generation it is showing now, which is the panel just opened in it.
    public init(session: Session) {
        self.session = session
        generation = session.overlaySlotGeneration
    }

    /// Whether `current` is the same session still showing that panel. False once anything else has taken the
    /// slot, once the HUD is gone, and for a replacement object wearing the same id.
    public func owns(_ current: Session?) -> Bool {
        guard let session, let current, current === session else { return false }
        return current.hudActive && current.overlaySlotGeneration == generation
    }
}
