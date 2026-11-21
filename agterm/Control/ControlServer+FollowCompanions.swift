import Foundation
import os
import agtermCore

private let followLogger = Logger(subsystem: "com.umputun.agterm", category: "FollowCompanions")

/// OriginKey names one origin session: the host, its zmx endpoint and the session id in canonical form.
struct OriginKey: Hashable {
    let host: String
    let executable: String
    let socketDirectory: String
    let session: String

    init(host: String, endpoint: ControlZmxEndpoint, session: String) {
        self.host = host
        executable = endpoint.executable
        socketDirectory = endpoint.socketDirectory
        self.session = ControlServer.originID(session)
    }

    var originHost: OriginHost { OriginHost(host: host, executable: executable, socketDirectory: socketDirectory) }
}

/// OriginHost names one origin host's zmx, every session on it.
struct OriginHost: Hashable {
    let host: String
    let executable: String
    let socketDirectory: String
}

/// CompanionFollowState is what this Mac knows about following each attached row's origin companions, by local row.
struct CompanionFollowState {
    struct Row {
        /// list is the newest membership the row's current stream delivered, nil until its snapshot.
        var list: PresentationCompanions?
        /// generation names that list; a result from an older one settles nothing but a final mark.
        var generation = 0
        /// parked are members not attachable now, tried again on the row's next list.
        var parked: Set<String> = []
        /// retries are members whose attach failed in transport, tried again once due.
        var retries: [String: Retry] = [:]
        /// pass is the running pass's id, nil while none runs.
        var pass: Int?
        var dirty = false
    }

    struct Retry {
        var failures: Int
        var due: Date
    }

    var rows: [UUID: Row] = [:]
    /// holds are origin hosts, by host and zmx endpoint, whose followers wait while this Mac's own New Companion creates there: the parent can join
    /// another group during the creation, so holding its group alone would let that group's follower attach it too.
    var holds: [OriginHost: Int] = [:]
    private var counter = 0

    /// nextID numbers lists and passes alike, so no two of either ever share one.
    mutating func nextID() -> Int {
        counter += 1
        return counter
    }
}

// MARK: - Following an attached row's origin companions

extension ControlServer {
    enum FollowOutcome {
        case handled
        case parked
        case retry
        case dropped
    }

    /// applyOriginCompanions takes a membership list from row `id`'s stream; nil, a snapshot without one, forgets the row.
    func applyOriginCompanions(_ list: PresentationCompanions?, forSession id: UUID) {
        let binding = library.store(forSession: id)?.session(withID: id)?.remotePresentation?.binding
        let follows = list != nil && binding?.origin != nil && binding?.catalogOwned == false && streamFollows(id)
        library.store(forSession: id)?.setFollowsCompanions(follows, forSession: id)
        guard let list else {
            companionFollow.rows[id] = nil
            return
        }
        let generation = companionFollow.nextID()
        companionFollow.rows[id, default: CompanionFollowState.Row()].list = list
        companionFollow.rows[id]?.generation = generation
        companionFollow.rows[id]?.parked = []
        reconcileCompanions(id)
    }

    /// companionStreamChanged drops row `id`'s list whenever its stream is not up, so nothing follows a membership the
    /// stream may have moved past until the next snapshot brings an authoritative one.
    func companionStreamChanged(_ connection: RemotePresentationConnection, forSession id: UUID) {
        guard connection != .connected, companionFollow.rows[id] != nil else { return }
        let generation = companionFollow.nextID()
        companionFollow.rows[id]?.list = nil
        companionFollow.rows[id]?.generation = generation
        library.store(forSession: id)?.setFollowsCompanions(false, forSession: id)
    }

    /// forgetCompanionFollow drops what row `id` was following, at its stream's stop; an attach in flight finds it gone.
    func forgetCompanionFollow(_ id: UUID) {
        companionFollow.rows[id] = nil
        library.store(forSession: id)?.setFollowsCompanions(false, forSession: id)
    }

    func holdCompanionFollow(_ key: OriginKey) -> OriginKey {
        companionFollow.holds[key.originHost, default: 0] += 1
        return key
    }

    func releaseCompanionFollow(_ key: OriginKey) {
        let host = key.originHost
        guard let count = companionFollow.holds[host] else { return }
        companionFollow.holds[host] = count > 1 ? count - 1 : nil
        guard companionFollow.holds[host] == nil else { return }
        for id in companionFollow.rows.keys where followTarget(id)?.2.originHost == host { reconcileCompanions(id) }
    }

    /// markFollowersHandled marks `child` handled under every row following an origin session on `host`.
    func markFollowersHandled(_ child: String, on host: OriginHost) {
        let groups = Set(companionFollow.rows.keys.compactMap { followTarget($0)?.2 }.filter { $0.originHost == host })
        for key in groups { library.markOriginCompanionsHandled([child], parent: key.session, host: key.host, endpoint: endpoint(of: key)) }
    }

    /// remoteRowPromoted starts following what a row made top-level now heads: a Mac page root needs the membership
    /// observer its nested row had no use for, and a terminal row baselines the list its stream already delivered,
    /// which stays unchanged through the promotion, so the first companion after it is followed rather than baselined.
    func remoteRowPromoted(_ session: Session) {
        if let binding = session.remotePresentation?.binding, Self.observesMembershipOnly(session, binding: binding),
           remoteClients[session.id]?.observer != true {
            stopRemotePresentation(session.id)
            startRemotePresentation(for: session)
            return
        }
        reconcileCompanions(session.id)
    }

    /// tickCompanionFollow runs the passes whose transport retries fell due, for rows whose stream is up and follows.
    func tickCompanionFollow() {
        let now = hudClock()
        for (id, row) in companionFollow.rows where row.retries.values.contains(where: { $0.due <= now }) {
            reconcileCompanions(id)
        }
    }

    private func reconcileCompanions(_ id: UUID) {
        guard let state = companionFollow.rows[id], let list = state.list, let (store, _, key) = followTarget(id),
              streamFollows(id) else { return }
        // a first list is taken as the baseline even during a hold, or the list after it would be
        guard store.session(withID: id)?.companionsBaselined == true else {
            store.baselineCompanions(list.members.map(\.id.uuidString), forSession: id)
            return
        }
        guard companionFollow.holds[key.originHost] == nil else { return }
        companionFollow.rows[id]?.dirty = true
        guard state.pass == nil else { return }
        let pass = companionFollow.nextID()
        companionFollow.rows[id]?.pass = pass
        Task { await runCompanionPass(id, pass: pass) }
    }

    // one pass per row, in membership order, so a batch never opens one ssh flow per child at once; a newer list
    // stops it before its next member and the rerun takes that list
    private func runCompanionPass(_ id: UUID, pass: Int) async {
        while companionFollow.rows[id]?.pass == pass, companionFollow.rows[id]?.dirty == true {
            companionFollow.rows[id]?.dirty = false
            guard let row = companionFollow.rows[id], let list = row.list, let (store, _, key) = followTarget(id) else { break }
            let generation = row.generation
            let shown = library.shownOriginSessions(host: key.host, endpoint: endpoint(of: key))
            let follow = store.companionsToFollow(list, forSession: id, shown: shown)
            let wanted = Set(follow.attach.map(\.id.uuidString))
            companionFollow.rows[id]?.retries = row.retries.filter { wanted.contains($0.key) }
            if !follow.markOnly.isEmpty { library.markOriginCompanionsHandled(follow.markOnly, parent: key.session, host: key.host, endpoint: endpoint(of: key)) }
            for member in follow.attach where isDue(member, row: id) {
                guard isCurrent(id, pass: pass, generation: generation) else { break }
                let attempt = FollowAttempt(child: member.id.uuidString, row: id, key: key, generation: generation)
                let outcome = member.kind == .page ? await followPage(attempt) : await followTerminal(attempt)
                settle(outcome, attempt)
            }
        }
        if companionFollow.rows[id]?.pass == pass { companionFollow.rows[id]?.pass = nil }
    }

    /// FollowAttempt is one member's attach under row `row`, made from the list `generation` names.
    private struct FollowAttempt {
        let child: String
        let row: UUID
        let key: OriginKey
        let generation: Int
    }

    private func isCurrent(_ id: UUID, pass: Int, generation: Int) -> Bool {
        companionFollow.rows[id]?.pass == pass && companionFollow.rows[id]?.generation == generation
    }

    private func streamFollows(_ id: UUID) -> Bool {
        remoteClients[id]?.originSupports(PresentationHub.companionsKind) == true
    }

    private func isDue(_ member: PresentationCompanions.Member, row id: UUID) -> Bool {
        guard let row = companionFollow.rows[id] else { return false }
        let child = member.id.uuidString
        return !row.parked.contains(child) && (row.retries[child].map { $0.due <= hudClock() } ?? true)
    }

    private func settle(_ outcome: FollowOutcome, _ attempt: FollowAttempt) {
        let (child, id, key) = (attempt.child, attempt.row, attempt.key)
        if case .handled = outcome {
            companionFollow.rows[id]?.retries[child] = nil
            library.markOriginCompanionsHandled([child], parent: key.session, host: key.host, endpoint: endpoint(of: key))
            return
        }
        guard companionFollow.rows[id]?.generation == attempt.generation else { return }
        switch outcome {
        case .handled:
            return
        case .parked:
            companionFollow.rows[id]?.retries[child] = nil
            companionFollow.rows[id]?.parked.insert(child)
        case .retry:
            let failures = (companionFollow.rows[id]?.retries[child]?.failures ?? 0) + 1
            let due = hudClock().addingTimeInterval(RemoteRetryBackoff.delay(afterFailures: failures))
            companionFollow.rows[id]?.retries[child] = CompanionFollowState.Retry(failures: failures, due: due)
        case .dropped:
            companionFollow.rows[id]?.retries[child] = nil
        }
    }

    private func followTerminal(_ attempt: FollowAttempt) async -> FollowOutcome {
        let (child, key) = (attempt.child, attempt.key)
        let expected = ExpectedOrigin(parent: key.session, endpoint: endpoint(of: key))
        let outcome = await attachListed(child, host: key.host, expected: expected, closed: "its row here was closed") { [self] in
            followPlacement(attempt)
        }
        switch outcome {
        case .attached: return .handled
        case .refused(let reason):
            followLogger.warning("companion \(child, privacy: .public) of \(key.host, privacy: .public) not attached: \(reason, privacy: .public)")
            return .handled
        case .unavailable: return .parked
        case .transport(let reason):
            followLogger.info("companion \(child, privacy: .public) of \(key.host, privacy: .public) waits: \(reason, privacy: .public)")
            return .retry
        case .dropped: return .dropped
        }
    }

    private func followPage(_ attempt: FollowAttempt) async -> FollowOutcome {
        let (child, id, key) = (attempt.child, attempt.row, attempt.key)
        let page: PresentationPage
        switch await requestRemotePage(child, host: key.host) {
        case .unanswered, .interrupted: return .retry
        case .tooOld: return .handled
        case .refused(let reason):
            return [PageAttachmentBook.loopbackRefusal, PageAttachmentBook.contentRefusal].contains(reason) ? .handled : .parked
        case .page(let offered, let parent):
            guard parent.map(Self.originID) == key.session else { return .parked }
            page = offered
        }
        guard followPlacement(attempt) != nil, let row = library.store(forSession: id)?.session(withID: id),
              let binding = row.remotePresentation?.binding else { return .dropped }
        if let refusal = Self.pageRefusal(page, profileFailure: HtmlOverlayRegistry.shared.persistentStoreFailure) { return refusal }
        let origin = RemoteBinding.Origin(host: key.host, endpoint: endpoint(of: key), sessionName: child)
        let source = RemotePageOrigin(session: child, binding: origin,
                                      presentation: PagePresentation(version: binding.presentationVersion, headless: binding.originHeadless))
        let placed = placeRemotePage(page, from: source, at: .companion(of: id), select: false)
        guard placed.ok else {
            followLogger.warning("page companion \(child, privacy: .public) of \(key.host, privacy: .public) not shown: \(placed.error ?? "", privacy: .public)")
            return .handled
        }
        // a helper that could not start has closed the channel already; its row goes now, before its cleanup's ssh
        // call, or the retry would find it shown
        guard pageChannelOpen(placed) else {
            if let placedRow = placed.result?.id.flatMap(UUID.init(uuidString:)) { library.store(forSession: placedRow)?.discardSession(placedRow) }
            return .retry
        }
        return .handled
    }

    /// pageRefusal is what a handed-over page this Mac cannot show now comes to, nil for one it can: a loopback page and
    /// a profile store it cannot hold are final, a clear in progress ends without a word from the origin and is retried.
    static func pageRefusal(_ page: PresentationPage, profileFailure: () -> String?) -> FollowOutcome? {
        if case .url(let text) = page.source, HtmlSource.isLoopback(text) { return .handled }
        guard page.persistent, let failure = profileFailure() else { return nil }
        return failure == BrowserClearError.clearing ? .retry : .handled
    }

    // read after every wait: the row, its binding, its newest list and what this Mac shows all move meanwhile
    private func followPlacement(_ attempt: FollowAttempt) -> RemotePlacement? {
        let (child, id, key) = (attempt.child, attempt.row, attempt.key)
        guard companionFollow.rows[id]?.generation == attempt.generation, streamFollows(id),
              let (store, row, current) = followTarget(id), current == key, companionFollow.holds[key.originHost] == nil,
              companionFollow.rows[id]?.list?.members.contains(where: { $0.id.uuidString == child }) == true,
              !row.followedCompanions.contains(child), let workspace = store.workspace(forSession: id)?.id else { return nil }
        guard !library.shownOriginSessions(host: key.host, endpoint: endpoint(of: key)).contains(child) else {
            library.markOriginCompanionsHandled([child], parent: key.session, host: key.host, endpoint: endpoint(of: key))
            return nil
        }
        return RemotePlacement(store: store, workspace: workspace, parent: id, select: false, claimLead: false)
    }

    // a top-level row attached from another host into a normal window; a server window's rows follow its catalog
    private func followTarget(_ id: UUID) -> (AppStore, Session, OriginKey)? {
        guard let store = library.store(forSession: id), let row = store.session(withID: id), row.parentID == nil,
              let host = row.remoteHost, let binding = row.remotePresentation?.binding, !binding.catalogOwned,
              let origin = binding.origin else { return nil }
        return (store, row, OriginKey(host: host, endpoint: origin.endpoint, session: binding.remoteSessionID))
    }

    private func endpoint(of key: OriginKey) -> ControlZmxEndpoint {
        ControlZmxEndpoint(executable: key.executable, socketDirectory: key.socketDirectory)
    }
}
