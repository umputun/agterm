import Foundation

/// RemoteOverlaySlot is an overlay slot of a session reserved for a job a viewer presents: nothing covers
/// the session here, but a second overlay cannot open on the slot until the job ends.
public struct RemoteOverlaySlot: Equatable, Sendable {
    public let job: String
    /// The pane role the slot covers, nil for the session-wide slot. Follows its pane across a swap.
    public fileprivate(set) var pane: OverlayPane?
    /// The presenter generation the job was handed to; only that stream can still reach its surface.
    public let owner: Int
    /// The size requested for a session-wide overlay, nil for full. What the viewer applied is not known.
    public var sizePercent: Int?
    /// Whether the viewer's surface stays up after the program ends (`--wait`), which keeps the slot held
    /// until that surface is closed.
    public var wait = false
    /// Whether the program already ended, its result recorded, while a held surface keeps the slot.
    public var ended = false
    /// page is what the slot holds instead of a program; `job` is then the page id.
    public var page: RemotePage?

    public init(job: String, pane: OverlayPane?, owner: Int, sizePercent: Int?, wait: Bool = false,
                ended: Bool = false, page: RemotePage? = nil) {
        self.job = job
        self.pane = pane
        self.owner = owner
        self.sizePercent = sizePercent
        self.wait = wait
        self.ended = ended
        self.page = page
    }
}

/// RemotePage is a page a reserved slot holds: the origin's record of what it opened, and what the presenting
/// Mac last reported it shows.
public struct RemotePage: Equatable, Sendable {
    struct VisibilityRequest: Equatable, Sendable {
        let hidden: Bool
        let seq: Int
    }

    public internal(set) var overlay: HtmlOverlay
    /// token claims the page channel once; it is never reported.
    let token: String
    let claimDeadline: Date
    public internal(set) var claimed = false
    /// hidden is the visibility the presenter last reported.
    public internal(set) var hidden = false
    /// requested is a visibility sent and not yet echoed back by the presenter.
    private(set) var requested: VisibilityRequest?
    private var lastSeq = 0

    init(overlay: HtmlOverlay, token: String, claimDeadline: Date) {
        self.overlay = overlay
        self.token = token
        self.claimDeadline = claimDeadline
    }

    /// effectiveHidden is what a toggle and a visibility reply go by: an unacknowledged request, else the
    /// presenter's last report, so a hide made on the presenter turns the next toggle into a show.
    var effectiveHidden: Bool { requested?.hidden ?? hidden }

    mutating func nextSeq() -> Int {
        lastSeq += 1
        return lastSeq
    }

    mutating func request(hidden: Bool) -> Int {
        let seq = nextSeq()
        requested = VisibilityRequest(hidden: hidden, seq: seq)
        return seq
    }

    /// apply takes the presenter's report, true when the reported visibility changed. A report echoing the
    /// pending request's sequence settles it; an older one leaves the request pending.
    mutating func apply(_ state: PresentationPageState) -> Bool {
        let wasHidden = hidden
        overlay.loadState = state.load
        overlay.loadError = state.error
        overlay.current = state.address.map {
            HtmlPageInfo(page: $0, title: state.title, canGoBack: state.canGoBack, canGoForward: state.canGoForward)
        }
        hidden = state.hidden
        if let requested, state.appliedSeq >= requested.seq { self.requested = nil }
        return wasHidden != hidden
    }
}

/// RemoteOverlays is a session's remote overlay state on the origin: the reserved slots, and for each slot
/// the failure a remote job ended with, which `session.overlay.result` reports until the next open there.
public struct RemoteOverlays: Equatable, Sendable {
    public private(set) var slots: [RemoteOverlaySlot] = []
    private var failures: [OverlayPane?: String] = [:]

    public func slot(_ pane: OverlayPane?) -> RemoteOverlaySlot? { slots.first { $0.pane == pane } }

    public func slot(job: String) -> RemoteOverlaySlot? { slots.first { $0.job == job } }

    public func failure(_ pane: OverlayPane?) -> String? { failures[pane] }

    mutating func reserve(_ slot: RemoteOverlaySlot) {
        failures[slot.pane] = nil
        slots.append(slot)
    }

    /// The program ended: the slot is freed, unless a held surface still occupies it on the viewer.
    mutating func end(job: String) -> RemoteOverlaySlot? {
        guard let index = slots.firstIndex(where: { $0.job == job }) else { return nil }
        let slot = slots[index]
        if slot.wait {
            slots[index].ended = true
        } else {
            slots.remove(at: index)
        }
        return slot
    }

    /// The viewer's surface is gone: a slot whose program ended is freed; a running one is freed when it ends.
    mutating func surfaceGone(job: String) {
        guard let index = slots.firstIndex(where: { $0.job == job }) else { return }
        if slots[index].ended {
            slots.remove(at: index)
        } else {
            slots[index].wait = false
        }
    }

    mutating func resize(job: String, sizePercent: Int?) {
        guard let index = slots.firstIndex(where: { $0.job == job }) else { return }
        slots[index].sizePercent = sizePercent
    }

    mutating func remove(job: String) { slots.removeAll { $0.job == job } }

    /// updatePage changes the page held under `job`; false when no slot holds it.
    @discardableResult
    mutating func updatePage(_ job: String, _ change: (inout RemotePage) -> Void) -> Bool {
        guard let index = slots.firstIndex(where: { $0.job == job }), var page = slots[index].page else { return false }
        change(&page)
        slots[index].page = page
        return true
    }

    /// The origin swapped its panes, and each pane's slot and result go with it.
    mutating func swapPanes() {
        for index in slots.indices where slots[index].pane != nil {
            slots[index].pane = slots[index].pane == .left ? .right : .left
        }
        (failures[.left], failures[.right]) = (failures[.right], failures[.left])
    }

    /// The split was promoted to the primary pane, whose own slot is already dropped.
    mutating func promoteRight() {
        for index in slots.indices where slots[index].pane == .right { slots[index].pane = .left }
        failures[.left] = failures[.right]
        failures[.right] = nil
    }

    mutating func recordFailure(_ name: String, pane: OverlayPane?) { failures[pane] = name }

    /// A local open on the slot starts a new result, as the local exit code does.
    mutating func clearFailure(_ pane: OverlayPane?) { failures[pane] = nil }
}
