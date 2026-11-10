import Foundation

/// ControlInteraction is an ask, pick, page or overlay job a session holds for a presenter: offered to one, claimed by
/// its helper or channel, or on a headless origin unpresented until one can show it.
public struct ControlInteraction: Codable, Equatable, Sendable {
    public static let unpresented = "unpresented"
    public static let offered = "offered"
    public static let claimed = "claimed"
    /// maxTimeout is the longest `--timeout`, a day like the HUD's ceiling.
    public static let maxTimeout: Double = 86400
    public static let timeoutError = "timeout must be more than 0 and at most 86400 seconds"

    public let kind: String
    public let id: String
    public let state: String
    /// deadline is when it ends unless answered or claimed, in epoch seconds; omitted while nothing expires it.
    public let deadline: Double?

    public init(kind: String, id: String, state: String, deadline: Double? = nil) {
        self.kind = kind
        self.id = id
        self.state = state
        self.deadline = deadline
    }

    /// isValidTimeout reports whether `seconds` is a usable `--timeout`.
    public static func isValidTimeout(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds > 0 && seconds <= maxTimeout
    }
}

extension AppStore {
    /// interactionNodes is `session`'s read-back of what it holds for a presenter, nil when there is nothing.
    func interactionNodes(_ session: Session) -> [ControlInteraction]? {
        var nodes: [ControlInteraction] = []
        if let ask = session.askPending, !session.askReplica, session.askPresentedRemotely || headless {
            nodes.append(ControlInteraction(kind: "ask", id: ask.id,
                                            state: session.askPresentedRemotely ? ControlInteraction.offered : ControlInteraction.unpresented,
                                            deadline: ask.deadline?.timeIntervalSince1970))
        }
        if let pick = SessionPickBook.shared.interaction(forSession: session.id) { nodes.append(pick) }
        for slot in session.remoteOverlays.slots {
            if let page = slot.page {
                let state = slot.owner == nil ? ControlInteraction.unpresented
                    : page.claimed ? ControlInteraction.claimed : ControlInteraction.offered
                // a url page loads with no channel, so only a channel page has a claim to wait for
                let claimWindow = state == ControlInteraction.offered && page.overlay.source.kind != .url
                nodes.append(ControlInteraction(kind: "page", id: slot.job, state: state,
                                                deadline: claimWindow ? page.claimDeadline.timeIntervalSince1970 : nil))
                continue
            }
            switch overlayJobs?.job(slot.job)?.state {
            case .unpresented?: nodes.append(ControlInteraction(kind: "job", id: slot.job, state: ControlInteraction.unpresented))
            case .unclaimed(let deadline)?:
                nodes.append(ControlInteraction(kind: "job", id: slot.job, state: ControlInteraction.offered,
                                                deadline: deadline.timeIntervalSince1970))
            case .claimed(let deadline)?:
                nodes.append(ControlInteraction(kind: "job", id: slot.job, state: ControlInteraction.claimed,
                                                deadline: deadline.timeIntervalSince1970))
            case .running?: nodes.append(ControlInteraction(kind: "job", id: slot.job, state: ControlInteraction.claimed))
            case .finished?, nil: break
            }
        }
        return nodes.isEmpty ? nil : nodes
    }

    /// offerPendingInteractions hands `id`'s unpresented ask, pick, pages and jobs to its presenter, ending first an
    /// ask or pick whose deadline passed, so an expired one is never shown.
    public func offerPendingInteractions(forSession id: UUID, now: Date) {
        if let ask = session(withID: id)?.askPending, !expireInteraction(ask.id, now: now) { offerPendingAsk(forSession: id) }
        if let (pick, _) = SessionPickBook.shared.unpresented(forSession: id), !SessionPickBook.shared.expire(pick.id, now: now) {
            offerPendingPick(forSession: id)
        }
        guard let session = session(withID: id) else { return }
        for slot in session.remoteOverlays.slots where slot.owner == nil {
            if slot.page != nil { offerPendingPage(slot, in: session, now: now) } else { offerPendingOverlay(slot, in: session) }
        }
    }

    /// expireInteraction cancels the ask or pick `id` once its deadline passed, telling a presenter holding it to
    /// take it down; false while it has time left or nothing by that id is pending.
    @discardableResult
    public func expireInteraction(_ id: String, now: Date) -> Bool {
        if let session = workspaces.flatMap(\.sessions).first(where: { $0.askPending?.id == id }) {
            guard let deadline = session.askPending?.deadline, deadline <= now else { return false }
            return session.resolveAsk(id: id, ControlAskResult(result: .cancelled))
        }
        return SessionPickBook.shared.expire(id, now: now)
    }
}
