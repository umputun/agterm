import Foundation

/// PresentationPick is a session-bound pick the origin hands to the viewer presenting the session. `owner` is the
/// presenter generation it went out under, so an answer from a presenter that has since lost the role is dropped.
public struct PresentationPick: Codable, Equatable, Sendable {
    public var id: String
    public var owner: Int
    public var items: [ControlPickItem]
    public var prompt: String?
    public var query: String?
    public var allowCustom: Bool?
    public var selection: String?
    /// follow raises the presenter's window holding the row, as `--follow` raises the origin's.
    public var follow: Bool?

    public init(_ pick: PendingPick, owner: Int, follow: Bool = false) {
        id = pick.id
        self.owner = owner
        items = pick.items
        prompt = pick.prompt
        query = pick.query
        allowCustom = pick.allowCustom ? true : nil
        selection = pick.selection
        self.follow = follow ? true : nil
    }

    /// pending is the pick as the presenter's own window shows it, under the origin's id.
    public var pending: PendingPick {
        PendingPick(id: id, items: items, prompt: prompt, query: query, allowCustom: allowCustom == true,
                    selection: selection)
    }

    /// fitsFrame is whether the request encodes under the frame cap; a thousand long rows may not.
    public var fitsFrame: Bool {
        (try? PresentationCodec.encode(PresentationFrame(gen: .max, rev: .max, body: .pickRequest(self)))) != nil
    }
}

/// PresentationPickAnswer is the presenter's outcome: `item` for a picked row, `query` for a custom answer, neither
/// for a cancel. The origin derives label and index from the items it stored.
public struct PresentationPickAnswer: Codable, Equatable, Sendable {
    public var id: String
    public var owner: Int
    public var item: String?
    public var query: String?

    public init(id: String, owner: Int, item: String? = nil, query: String? = nil) {
        self.id = id
        self.owner = owner
        self.item = item
        self.query = query
    }

    init(id: String, owner: Int, result: ControlPickResult) {
        switch result.result {
        case .picked: self.init(id: id, owner: owner, item: result.id)
        case .custom: self.init(id: id, owner: owner, query: result.query ?? "")
        case .cancelled, .pending: self.init(id: id, owner: owner)
        }
    }
}

/// PresentationPickRef names one handed-over pick, for a refusal or a dismissal.
public struct PresentationPickRef: Codable, Equatable, Sendable {
    public var id: String
    public var owner: Int

    public init(id: String, owner: Int) {
        self.id = id
        self.owner = owner
    }
}

extension PendingPick {
    /// validatedResult is the outcome a presenter's answer stands for, nil when it names a row this pick does not
    /// have or a custom answer it does not accept.
    func validatedResult(item: String?, query: String?) -> ControlPickResult? {
        switch (item, query) {
        case (nil, nil): return ControlPickResult(result: .cancelled)
        case (let item?, nil):
            guard let index = items.firstIndex(where: { $0.id == item }) else { return nil }
            return ControlPickResult(result: .picked, id: item, label: items[index].label, index: index)
        case (nil, let query?):
            return allowCustom ? ControlPickResult(result: .custom, query: query) : nil
        default: return nil
        }
    }
}

/// SessionPickBook holds the picks bound to a session rather than to a window. On an origin each one is drawn by
/// the session's presenter or in the session's own window here, and its outcome stays readable after it ends; on a
/// viewer it maps the replicas this Mac draws for an origin back to their stream.
@MainActor
public final class SessionPickBook {
    public static let shared = SessionPickBook()
    /// Matches PickRegistry's app-wide cap, for the same unread-answer reason.
    static let retainedResultLimit = 32

    public enum Placement: Equatable, Sendable {
        /// drawn by the session's presenter, handed over under that presenter generation
        case presenter(owner: Int)
        /// drawn in this window's modal slot
        case local(WindowInfo.ID)
        /// held by a headless origin until a presenter can show it
        case unpresented
    }

    private struct Entry {
        let session: UUID
        let pick: PendingPick
        var placement: Placement
        var window: WindowInfo.ID?
        var dismiss: (@MainActor () -> Void)?
        var follow = false
    }

    private struct Replica {
        let session: UUID
        let owner: Int
        let window: WindowInfo.ID
        let answer: @MainActor (PresentationFrame.Body) -> Void
    }

    private var entries: [String: Entry] = [:]
    private var retained: [(id: String, result: ControlPickResult, window: WindowInfo.ID?)] = []
    private var replicas: [String: Replica] = [:]
    /// queued are replicas waiting, oldest first, for their window's modal slot.
    private var queued: [(request: PresentationPick, replica: Replica)] = []

    init() {}

    /// placement is where `session`'s pick in flight is drawn, nil when it has none.
    public func placement(forSession session: UUID) -> Placement? {
        entries.values.first { $0.session == session }?.placement
    }

    /// openLocal shows `pick` in `controller`, the modal slot of the session's own window, and books it to the
    /// session. Nil when shown, otherwise the refusal.
    public func openLocal(_ pick: PendingPick, session: UUID, window: WindowInfo.ID, controller: PickController) -> String? {
        guard placement(forSession: session) == nil else { return "pick already pending" }
        guard controller.open(pick) else { return controller.pendingAsk != nil ? "ask already pending" : "pick already pending" }
        entries[pick.id] = Entry(session: session, pick: pick, placement: .local(window), window: window)
        return nil
    }

    /// openRemote books `pick` as drawn by the session's presenter, described by `request`; `dismiss` tells that
    /// presenter the pick ended here. False when the session already has one.
    func openRemote(_ pick: PendingPick, as request: PresentationPick, session: UUID, window: WindowInfo.ID?,
                    dismiss: @escaping @MainActor () -> Void) -> Bool {
        guard placement(forSession: session) == nil else { return false }
        entries[pick.id] = Entry(session: session, pick: pick, placement: .presenter(owner: request.owner), window: window,
                                 dismiss: dismiss, follow: request.follow == true)
        return true
    }

    /// openUnpresented books `pick` as held until `session` has a presenter that can show it. False when the session
    /// already has one.
    public func openUnpresented(_ pick: PendingPick, session: UUID, follow: Bool) -> Bool {
        guard placement(forSession: session) == nil else { return false }
        entries[pick.id] = Entry(session: session, pick: pick, placement: .unpresented, window: nil, follow: follow)
        return true
    }

    func unpresented(forSession session: UUID) -> (pick: PendingPick, follow: Bool)? {
        entries.values.first { $0.session == session && $0.placement == .unpresented }.map { ($0.pick, $0.follow) }
    }

    /// offer marks `session`'s unpresented pick as handed to the presenter under `owner`.
    func offer(session: UUID, owner: Int, dismiss: @escaping @MainActor () -> Void) {
        guard let (id, _) = entries.first(where: { $0.value.session == session && $0.value.placement == .unpresented }) else { return }
        entries[id]?.placement = .presenter(owner: owner)
        entries[id]?.dismiss = dismiss
    }

    /// returnToPending takes `session`'s presenter-held pick back as unpresented after its presenter was lost or
    /// refused it (`refused`, which must name it under its owner); an answer from that presenter is then stale.
    public func returnToPending(session: UUID, refused: PresentationPickRef? = nil) {
        guard let (id, entry) = entries.first(where: { $0.value.session == session }),
              case .presenter(let held) = entry.placement,
              refused.map({ $0.id == id && $0.owner == held }) ?? true else { return }
        entries[id]?.placement = .unpresented
        entries[id]?.dismiss = nil
    }

    /// expire cancels the pick `id` once its deadline passed; false while it has time left or is not booked.
    @discardableResult
    public func expire(_ id: String, now: Date) -> Bool {
        guard let deadline = entries[id]?.pick.deadline, deadline <= now else { return false }
        return cancel(id)
    }

    /// interaction is `session`'s pick as the tree lists it while a presenter holds it or one is awaited.
    func interaction(forSession session: UUID) -> ControlInteraction? {
        guard let (id, entry) = entries.first(where: { $0.value.session == session }) else { return nil }
        let state: String
        switch entry.placement {
        case .presenter: state = ControlInteraction.offered
        case .unpresented: state = ControlInteraction.unpresented
        case .local: return nil
        }
        return ControlInteraction(kind: "pick", id: id, state: state, deadline: entry.pick.deadline?.timeIntervalSince1970)
    }

    /// resolveRemote applies the presenter's answer. Refused unless it is for the pick `session`'s presenter holds
    /// under that owner and names a row or a custom answer the pick allows.
    @discardableResult
    public func resolveRemote(_ answer: PresentationPickAnswer, session: UUID) -> Bool {
        guard let entry = entries[answer.id], entry.session == session, entry.placement == .presenter(owner: answer.owner),
              let result = entry.pick.validatedResult(item: answer.item, query: answer.query) else { return false }
        finish(answer.id, entry.pick.expired(at: Date()) ? ControlPickResult(result: .cancelled) : result)
        return true
    }

    /// handBack moves `session`'s presenter-held pick into `controller`, the session's window here, after the
    /// presenter refused it (`refused`, which must name it under its owner) or was lost (nil). With no
    /// controller, or one whose modal slot holds another pick or ask, the pick ends cancelled and stays readable:
    /// it never waits where nothing draws it, and the unrelated modal is left alone.
    public func handBack(session: UUID, refused: PresentationPickRef? = nil, to controller: PickController?,
                         window: WindowInfo.ID?) {
        guard let (id, entry) = entries.first(where: { $0.value.session == session }),
              case .presenter(let held) = entry.placement,
              refused.map({ $0.id == id && $0.owner == held }) ?? true else { return }
        guard let controller, let window, controller.open(entry.pick) else {
            finish(id, ControlPickResult(result: .cancelled))
            return
        }
        entries[id]?.placement = .local(window)
        entries[id]?.window = window
        entries[id]?.dismiss = nil
    }

    /// cancel ends the pick `id` from the origin: its presenter is told to take the replica down, a local one is
    /// cancelled in its window. False for an id the book never held; a retained one is a successful no-op.
    @discardableResult
    public func cancel(_ id: String) -> Bool {
        if let index = queued.firstIndex(where: { $0.request.id == id }) {
            let waiting = queued.remove(at: index).replica
            let cancelled = ControlPickResult(result: .cancelled)
            retain(id, cancelled, window: waiting.window)
            waiting.answer(.pickResolve(PresentationPickAnswer(id: id, owner: waiting.owner, result: cancelled)))
            return true
        }
        guard let entry = entries[id] else { return retained.contains { $0.id == id } }
        if case .local(let window) = entry.placement, let controller = PickRegistry.shared.controller(for: window),
           controller.pending?.id == id {
            controller.cancel()
            return true
        }
        // settled before the dismissal: a stalled send drops the presenter, whose handback must find nothing
        finish(id, ControlPickResult(result: .cancelled))
        entry.dismiss?()
        return true
    }

    /// sessionEnded settles everything bound to `session` once it leaves its store: its own pick is cancelled, and
    /// a replica is taken down without answering, since its origin takes the pick back when the stream ends.
    public func sessionEnded(_ session: UUID) {
        for (id, entry) in entries where entry.session == session { cancel(id) }
        dropReplicas(forSession: session)
    }

    /// window is the window the pick `id` was opened for, booked or retained; nil on a headless origin.
    public func window(of id: String) -> WindowInfo.ID? {
        if let waiting = queued.first(where: { $0.request.id == id }) { return waiting.replica.window }
        return entries[id].map(\.window) ?? retained.last { $0.id == id }?.window
    }

    /// result is the pick `id`'s outcome: pending while booked or queued, then the retained answer.
    public func result(for id: String) -> ControlPickResult? {
        if entries[id] != nil || queued.contains(where: { $0.request.id == id }) { return ControlPickResult(result: .pending) }
        return retained.last { $0.id == id }?.result
    }

    /// node is `session`'s pick read-back: its own pick, or the replica this Mac draws for its origin.
    func node(forSession session: UUID) -> ControlSessionPick? {
        if let (id, entry) = entries.first(where: { $0.value.session == session }) {
            guard case .presenter = entry.placement else { return ControlSessionPick(id: id) }
            return ControlSessionPick(id: id, remote: true)
        }
        if let shown = replicas.first(where: { $0.value.session == session }) { return ControlSessionPick(id: shown.key, replica: true) }
        return queued.first { $0.replica.session == session }.map { ControlSessionPick(id: $0.request.id, replica: true) }
    }

    /// controllerResolved is a window controller's report that pick `id` left its slot: a choice, a custom answer,
    /// Esc, a cancel or the window's teardown. It settles the booked pick or the replica showing there.
    func controllerResolved(_ id: String, result: ControlPickResult) {
        if let replica = replicas.removeValue(forKey: id) {
            replica.answer(.pickResolve(PresentationPickAnswer(id: id, owner: replica.owner, result: result)))
        }
        if let entry = entries[id], case .local = entry.placement { finish(id, result) }
    }

    // MARK: - Viewer

    /// openReplica shows the pick an origin handed over in `controller`, the modal slot of the window holding the
    /// attached row, or queues it there until the slot frees; its outcome goes back through `answer`. False only
    /// for an id this Mac already holds.
    public func openReplica(_ request: PresentationPick, session: UUID, window: WindowInfo.ID, controller: PickController,
                            answer: @escaping @MainActor (PresentationFrame.Body) -> Void) -> Bool {
        guard replicas[request.id] == nil, !queued.contains(where: { $0.request.id == request.id }) else { return false }
        let replica = Replica(session: session, owner: request.owner, window: window, answer: answer)
        guard controller.open(request.pending) else {
            queued.append((request, replica))
            return true
        }
        replicas[request.id] = replica
        return true
    }

    /// drain shows the oldest replica queued for `controller`'s window once its modal slot is free.
    func drain(_ controller: PickController) {
        guard !controller.modalPending,
              let index = queued.firstIndex(where: { PickRegistry.shared.controller(for: $0.replica.window) === controller }) else { return }
        let next = queued.remove(at: index)
        guard controller.open(next.request.pending) else { return queued.insert(next, at: index) }
        replicas[next.request.id] = next.replica
    }

    /// dismissReplica takes the replica `ref` names down without answering, once its origin ended the pick. A
    /// dismissal under another owner, or for a pick no longer shown, changes nothing.
    public func dismissReplica(_ ref: PresentationPickRef, session: UUID) {
        queued.removeAll { $0.request.id == ref.id && $0.replica.session == session && $0.replica.owner == ref.owner }
        guard let replica = replicas[ref.id], replica.session == session, replica.owner == ref.owner else { return }
        closeReplica(ref.id, in: replica.window)
    }

    /// dropReplicas takes down `session`'s replica without answering: its stream is gone, and the origin takes the
    /// pick back on its own.
    public func dropReplicas(forSession session: UUID) {
        queued.removeAll { $0.replica.session == session }
        for (id, replica) in replicas where replica.session == session { closeReplica(id, in: replica.window) }
    }

    /// windowClosing detaches the replicas shown or queued in `window` without answering, before its modal slot
    /// is cancelled: the origin takes them back when the window's streams end.
    func windowClosing(_ window: WindowInfo.ID) {
        queued.removeAll { $0.replica.window == window }
        for (id, replica) in replicas where replica.window == window { replicas[id] = nil }
    }

    private func closeReplica(_ id: String, in window: WindowInfo.ID) {
        replicas[id] = nil
        guard let controller = PickRegistry.shared.controller(for: window), controller.pending?.id == id else { return }
        controller.cancel()
    }

    private func finish(_ id: String, _ result: ControlPickResult) {
        retain(id, result, window: entries.removeValue(forKey: id)?.window)
    }

    private func retain(_ id: String, _ result: ControlPickResult, window: WindowInfo.ID?) {
        retained.removeAll { $0.id == id }
        retained.append((id: id, result: result, window: window))
        if retained.count > Self.retainedResultLimit { retained.removeFirst(retained.count - Self.retainedResultLimit) }
    }
}

// MARK: - Origin routing

extension AppStore {
    /// presentPickRemotely hands a session-bound pick to the session's presenter when the session presents remotely
    /// and its presenter speaks the pick frames. Nil leaves it to the caller; false means the session already has
    /// a pick.
    public func presentPickRemotely(_ pick: PendingPick, in session: Session, window: WindowInfo.ID?,
                                    follow: Bool = false) -> Bool? {
        guard let hub = presentationHub, hub.hasPresenter(session: session.id), presentsRemotely(session, paneIdentity: nil),
              hub.presenterSupports("pick.request", session: session.id) else { return nil }
        // an expired pick is never shown: the caller holds it and its deadline ends it
        guard !pick.expired(at: Date()) else { return nil }
        let owner = hub.presenterGeneration(session: session.id)
        let request = PresentationPick(pick, owner: owner, follow: follow)
        guard request.fitsFrame else { return nil }
        let booked = SessionPickBook.shared.openRemote(pick, as: request, session: session.id,
                                                       window: window) { [weak hub, id = session.id] in
            hub?.sendToPresenter(.pickDismiss(PresentationPickRef(id: pick.id, owner: owner)), session: id)
        }
        guard booked else { return false }
        // booked first: a presenter dropped by this send is taken back through onPresenterLost
        hub.sendToPresenter(.pickRequest(request), session: session.id)
        return true
    }

    /// offerPendingPick hands `id`'s unpresented pick to its presenter under the current generation; false when
    /// there is none, or the presenter cannot show it and it stays unpresented.
    @discardableResult
    public func offerPendingPick(forSession id: UUID) -> Bool {
        guard let hub = presentationHub, hub.hasPresenter(session: id), hub.presenterSupports("pick.request", session: id),
              let (pick, follow) = SessionPickBook.shared.unpresented(forSession: id) else { return false }
        let owner = hub.presenterGeneration(session: id)
        let request = PresentationPick(pick, owner: owner, follow: follow)
        guard request.fitsFrame else { return false }
        SessionPickBook.shared.offer(session: id, owner: owner) { [weak hub] in
            hub?.sendToPresenter(.pickDismiss(PresentationPickRef(id: pick.id, owner: owner)), session: id)
        }
        hub.sendToPresenter(.pickRequest(request), session: id)
        return true
    }
}
