import Observation

/// One picker request currently presented by a window.
public struct PendingPick: Equatable, Sendable {
    public let id: String
    public let items: [ControlPickItem]
    public let prompt: String?
    /// Text the query field opens with; a non-empty value filters immediately.
    public let query: String?
    public let allowCustom: Bool

    public init(id: String, items: [ControlPickItem], prompt: String? = nil, query: String? = nil,
                allowCustom: Bool = false) {
        self.id = id
        self.items = items
        self.prompt = prompt
        self.query = query
        self.allowCustom = allowCustom
    }
}

/// Owns the window modal slot and retained pick results; AskRegistry retains ask results.
@Observable
@MainActor
public final class PickController {
    /// How many terminal results stay readable per window. A blocking client polls every 500ms, so its
    /// answer survives any plausible number of pickers opened in that window before the poll lands;
    /// keying by pick id rather than one slot is what keeps `open` from discarding an unread answer.
    static let retainedResultLimit = 8

    /// Monotonic across every controller, so results merged from different windows can be ordered by
    /// when they were answered rather than by when their window closed.
    private static var resolutionSequence = 0

    public private(set) var pending: PendingPick?
    /// Terminal results in resolution order, oldest first, capped at `retainedResultLimit`.
    public private(set) var recentResults: [ResolvedPick] = []
    /// pendingAsk is the dialog currently awaiting an answer.
    public private(set) var pendingAsk: PendingAsk?
    fileprivate var windowID: WindowInfo.ID?
    /// modalPending prevents pick and ask from presenting competing modals.
    public var modalPending: Bool { pending != nil || pendingAsk != nil }
    /// pendingModalError names the modal blocking another control action, or nil when the slot is free.
    public var pendingModalError: String? {
        guard modalPending else { return nil }
        return pendingAsk == nil ? "pick pending" : "ask pending"
    }

    public init() {}

    /// open reserves the modal slot unless a pick or ask already owns it.
    @discardableResult
    public func open(_ pick: PendingPick) -> Bool {
        guard !modalPending else { return false }
        pending = pick
        return true
    }

    /// Completes the pending picker with `outcome`, keeping it readable until it ages out.
    public func resolve(_ outcome: ControlPickResult) {
        guard let pending else { return }
        Self.resolutionSequence += 1
        recentResults.removeAll { $0.id == pending.id }
        recentResults.append(ResolvedPick(id: pending.id, result: outcome, sequence: Self.resolutionSequence))
        if recentResults.count > Self.retainedResultLimit {
            recentResults.removeFirst(recentResults.count - Self.retainedResultLimit)
        }
        self.pending = nil
    }

    /// Completes the pending picker as cancelled.
    public func cancel() {
        resolve(ControlPickResult(result: .cancelled))
    }

    /// Returns the current or retained result for the exact picker id.
    public func result(for id: String) -> ControlPickResult? {
        if pending?.id == id {
            return ControlPickResult(result: .pending)
        }
        return recentResults.last { $0.id == id }?.result
    }

    /// openAsk reserves the modal slot unless a pick or ask already owns it.
    @discardableResult
    public func openAsk(_ ask: PendingAsk) -> Bool {
        guard !modalPending else { return false }
        pendingAsk = ask
        return true
    }

    /// resolveAsk retains the outcome before releasing the modal slot.
    public func resolveAsk(_ outcome: ControlAskResult) {
        guard let pendingAsk else { return }
        guard outcome.result != .pending else { return }
        if let windowID, AskRegistry.shared.owner(for: pendingAsk.id) == .window(windowID) {
            AskRegistry.shared.retain(id: pendingAsk.id, result: outcome, window: windowID)
        }
        self.pendingAsk = nil
    }

    /// cancelAsk cancels without synthesizing a named button answer.
    public func cancelAsk() {
        resolveAsk(ControlAskResult(result: .cancelled))
    }

    /// escapeAsk retains a user dismissal separately from administrative cancellation.
    public func escapeAsk() {
        resolveAsk(ControlAskResult(result: .escaped))
    }

    /// askResult returns the pending or retained outcome for an exact ask id.
    public func askResult(for id: String) -> ControlAskResult? {
        if pendingAsk?.id == id {
            return ControlAskResult(result: .pending)
        }
        guard let windowID, let retained = AskRegistry.shared.result(for: id), retained.windowID == windowID else { return nil }
        return retained.result
    }
}

/// PickRegistry maps windows to their shared pick and ask controllers.
@MainActor
public final class PickRegistry {
    public static let shared = PickRegistry()
    /// How many results outlive their window across the whole app. Nothing frees an entry for a window
    /// that never reopens, so scripted window churn would otherwise grow this without bound.
    static let retainedResultLimit = 32

    private var controllers: [WindowInfo.ID: PickController] = [:]
    /// Results whose window is gone, oldest first, capped at `retainedResultLimit`.
    private var retainedResults: [(windowID: WindowInfo.ID, pick: ResolvedPick)] = []

    private init() {}

    public func register(_ id: WindowInfo.ID, controller: PickController) {
        controller.windowID = id
        controllers[id] = controller
    }

    /// unregister cancels pending modals and retains their outcomes for polls after window teardown.
    public func unregister(_ id: WindowInfo.ID) {
        guard let controller = controllers[id] else { return }
        controller.cancel()
        controller.cancelAsk()
        controllers[id] = nil
        retainedResults.append(contentsOf: controller.recentResults.map { (windowID: id, pick: $0) })
        if retainedResults.count > Self.retainedResultLimit {
            // order by when each pick was ANSWERED before trimming: a window closing later arrives with a
            // whole batch, and appending alone would evict a newer result an earlier-closing window held.
            retainedResults.sort { $0.pick.sequence < $1.pick.sequence }
            retainedResults.removeFirst(retainedResults.count - Self.retainedResultLimit)
        }
    }

    public func controller(for id: WindowInfo.ID?) -> PickController? {
        guard let id else { return nil }
        return controllers[id]
    }

    /// Locate a live picker by its globally unique id. Blocking clients intentionally use this lookup
    /// when no window selector was supplied so a later frontmost-window change cannot orphan the request.
    public func livePick(for pickID: String) -> (windowID: WindowInfo.ID, controller: PickController)? {
        controllers.first { $0.value.result(for: pickID) != nil }
            .map { (windowID: $0.key, controller: $0.value) }
    }

    /// A result retained when its window unregistered, matched by the globally unique pick id.
    public func retainedResult(for pickID: String) -> (windowID: WindowInfo.ID, result: ControlPickResult)? {
        retainedResults.last { $0.pick.id == pickID }
            .map { (windowID: $0.windowID, result: $0.pick.result) }
    }
}
