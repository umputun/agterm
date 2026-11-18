import Foundation
import agtermCore

/// RemoteCompanionRequest is a companion the origin of a remote row is asked to create under its own session.
enum RemoteCompanionRequest {
    case terminal(CompanionOptions)
    case duplicate
    case page(ControlSessionOverlayOpenOptions)

    var tint: SidebarTint? {
        if case .terminal(let options) = self { return options.tint }
        return nil
    }

    var command: Command {
        switch self {
        case .terminal: .sessionCompanionNew
        case .duplicate: .sessionCompanionDuplicate
        case .page: .sessionCompanionPage
        }
    }

    // the origin keeps its own selection: the companion is wanted here, not there
    func arguments(originSession: String) -> [String] {
        switch self {
        case .duplicate:
            return ["session", "duplicate", "--companion", "--target", originSession, "--no-select"]
        case .terminal(let options):
            var arguments = ["session", "new", "--parent", originSession, "--no-select"]
            if let cwd = options.cwd { arguments += ["--cwd", cwd] }
            if let command = options.command { arguments += ["--command", command] }
            if options.wait { arguments.append("--wait") }
            if let name = options.name { arguments += ["--name", name] }
            return arguments
        case .page(let options):
            return Self.pageArguments(options, originSession: originSession)
        }
    }

    // a file path is the origin's own: the page is that Mac's and is served from there
    private static func pageArguments(_ options: ControlSessionOverlayOpenOptions, originSession: String) -> [String] {
        var arguments = ["session", "overlay", "open", "--companion", "--target", originSession]
        switch options.page {
        case .file(let path, let grantRoot):
            arguments += ["--html", path]
            if let grantRoot { arguments += ["--cwd", grantRoot] }
        case .url(let url): arguments += ["--url", url.absoluteString]
        case .replica, .image, .markdown, .text, .document, .unreadable, nil: break
        }
        let flags: [(Bool, String)] = [(options.navigation, "--navigation"), (options.javascript, "--js"),
                                       (options.chromeless, "--chromeless"), (options.persistent, "--persistent"),
                                       (options.browse, "--browse")]
        arguments += flags.filter(\.0).map(\.1)
        if let color = options.backgroundColor { arguments += ["--background-color", color] }
        return arguments
    }
}

extension ControlServer {
    static let remoteCompanionDeadline: TimeInterval = 30
    /// A new origin session is attachable once every pane's daemon runs, which takes a moment after creation.
    static let remoteCompanionReadyBudget: TimeInterval = 20

    /// createRemoteCompanion asks the origin of `rowID`, a remote row, to create a companion under its session,
    /// waits for the origin to report it attachable, then attaches it under the row's group here. Creation is
    /// never retried and never falls back to a local session; one created but not attached is named.
    func createRemoteCompanion(_ request: RemoteCompanionRequest, of rowID: UUID, in store: AppStore, select: Bool,
                               progress: (String) -> Void = { _ in }) async -> ControlResponse {
        guard let row = store.session(withID: rowID), let host = row.remoteHost,
              let origin = row.remotePresentation?.binding.remoteSessionID else {
            return ControlResponse(ok: false, error: "the remote session is not attached")
        }
        let parent = store.parent(of: row) ?? row
        let parentID = parent.id
        // the companion lands under the parent, so the parent is what must still be attachable there
        let listedOrigin = parent.remotePresentation?.binding.remoteSessionID ?? origin
        let argv: [String]
        do {
            argv = try RemoteSession.controlCommand(host: host, arguments: request.arguments(originSession: origin))
        } catch {
            return ControlResponse(ok: false, error: "invalid host")
        }
        progress("creating a companion on \(host)…")
        // a binding can outlive an origin relaunched into fresh shells, where nothing created could be attached
        let current = await remoteTree(host: host)
        guard let tree = current.result?.remote else { return current }
        guard tree.sessions.contains(where: { $0.id == listedOrigin }) else {
            return ControlResponse(ok: false, error: "the session on \(host) is not attachable now; nothing was created")
        }
        // the origin creates under the target's current parent there, which is the group whose followers must wait; a
        // target missing from the tree, such as a companion whose split daemon stopped, is still in its parent's membership
        let group = tree.sessions.first(where: { $0.id == origin })?.parent
            ?? tree.sessions.first(where: { $0.companions?.contains(where: { $0.id == origin }) == true })?.id
            ?? listedOrigin
        let hold = holdCompanionFollow(OriginKey(host: host, endpoint: tree.endpoint, session: group))
        defer { releaseCompanionFollow(hold) }
        let result = await remoteRunner.run(argv, deadline: Self.remoteCompanionDeadline)
        if result.refusedArguments {
            return ControlResponse(ok: false, error: "the agterm on \(host) is too old for companions")
        }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return ControlResponse(ok: false, error: "\(host) gave no answer\(stderr.isEmpty ? "" : " (\(stderr))"); "
                                   + "whether the companion was created there is unknown")
        }
        // a created child the error names is the user's to attach, so no follower attaches it as well
        let leaveToUser = { [self] (created: String) in
            library.markOriginCompanionsHandled([created], parent: reply.result?.parent ?? group, host: host, endpoint: tree.endpoint)
        }
        // a full receipt with a failed transport still names work the origin did, so it is reported, never redone
        if result.status != 0, reply.ok, let created = reply.result?.id, UUID(uuidString: created) != nil {
            leaveToUser(created)
            return ControlResponse(ok: false, error: "created companion \(created) on \(host) but the connection failed before "
                                   + "attaching it; `agtermctl zmx attach \(host) \(created)` attaches it")
        }
        guard result.status == 0, reply.ok else {
            if reply.refusesUnknown(request.command) {
                return ControlResponse(ok: false, error: "the agterm on \(host) is too old for companions")
            }
            return ControlResponse(ok: false, error: reply.error ?? "the remote command failed on \(host)")
        }
        // the id reaches an error message, so only a well-formed one is echoed
        guard let created = reply.result?.id, UUID(uuidString: created) != nil else {
            return ControlResponse(ok: false, error: "\(host) created a companion but did not name it")
        }
        progress("attaching the companion…")
        let pending = CreatedCompanion(id: created, host: host, parent: parentID, select: select, tint: request.tint)
        let outcome: CompanionAttach
        if case .page = request {
            outcome = await attachOriginPage(pending, endpoint: tree.endpoint)
        } else {
            outcome = await attachCreatedCompanion(pending)
        }
        switch outcome {
        case .attached(let response):
            return response
        case .failed(let reason):
            leaveToUser(created)
            return ControlResponse(ok: false, error: "created companion \(created) on \(host) but could not attach it: "
                                   + "\(reason); `agtermctl zmx attach \(host) \(created)` attaches it")
        }
    }

    private struct CreatedCompanion {
        let id: String
        let host: String
        let parent: UUID
        let select: Bool
        let tint: SidebarTint?
    }

    enum CompanionAttach {
        case attached(ControlResponse)
        case failed(String)
    }

    // a page is attachable as soon as it exists, so there is nothing to wait for
    private func attachOriginPage(_ pending: CreatedCompanion, endpoint: ControlZmxEndpoint) async -> CompanionAttach {
        let origin = RemoteBinding.Origin(host: pending.host, endpoint: endpoint, sessionName: pending.id)
        let parent = library.store(forSession: pending.parent)?.session(withID: pending.parent)?.remotePresentation?.binding
        let presentation = PagePresentation(version: parent?.presentationVersion, headless: parent?.originHeadless == true)
        let attached = await attachRemotePage(pending.id, origin: origin, presentation: presentation,
                                              at: .companion(of: pending.parent), select: pending.select)
        return attached.ok ? .attached(attached) : .failed(attached.error ?? "attach failed")
    }

    /// RemotePageSpot is where an origin's page goes here: under a row attached from that Mac, or as a top-level row
    /// of a workspace in the window backed by `store`.
    enum RemotePageSpot {
        case companion(of: UUID)
        case root(store: AppStore, workspace: AttachDestination)
        /// existing is a page row a relaunch restored, waiting for its page.
        case existing(UUID)
    }

    /// PagePresentation is what the origin said of its presentation stream: its version and whether it has no screen.
    struct PagePresentation {
        let version: Int?
        let headless: Bool

        init(version: Int?, headless: Bool) {
            self.version = version
            self.headless = headless
        }

        init(_ tree: ControlRemoteTree) {
            self.init(version: tree.presentation, headless: tree.headless == true)
        }
    }

    /// RemotePageHandover is a host's answer when asked for one of its pages.
    enum RemotePageHandover {
        /// page is the handed-over page and the origin session its host says it belongs under.
        case page(PresentationPage, parent: String?)
        case refused(String)
        /// tooOld is a host whose agterm predates page companions.
        case tooOld(String)
        /// unanswered is no reply at all, which says nothing about the page.
        case unanswered(String)
        /// interrupted is a handover the host made over a connection that then failed.
        case interrupted(String)
    }

    /// RemotePageOrigin is where a handed-over page comes from: the origin's page session, its host and how that host
    /// presents it.
    struct RemotePageOrigin {
        let session: String
        let binding: RemoteBinding.Origin
        let presentation: PagePresentation
        /// companions are the origin's companions of a page root, listed when it was attached.
        var companions: [String]?
    }

    /// attachRemotePage asks `origin.host` for one attachment of its page session `originSession` and shows it at
    /// `spot` here. The page stays that Mac's: closing the row here ends only this attachment's channel.
    func attachRemotePage(_ originSession: String, origin binding: RemoteBinding.Origin, presentation: PagePresentation,
                          at spot: RemotePageSpot, select: Bool, companions: [String]? = nil) async -> ControlResponse {
        switch await requestRemotePage(originSession, host: binding.host) {
        case .refused(let reason), .tooOld(let reason), .unanswered(let reason), .interrupted(let reason):
            return ControlResponse(ok: false, error: reason)
        case .page(let page, let parent):
            let source = RemotePageOrigin(session: originSession, binding: binding, presentation: presentation, companions: companions)
            let placed = placeRemotePage(page, from: source, at: spot, select: select)
            if placed.ok, case .companion = spot, let parent, pageChannelOpen(placed) {
                library.markOriginCompanionsHandled([originSession], parent: parent, host: binding.host, endpoint: binding.endpoint)
            }
            return placed
        }
    }

    /// pageChannelOpen says the page `placed` answers for still has its channel, which a helper that failed to start
    /// closes before the reply.
    func pageChannelOpen(_ placed: ControlResponse) -> Bool {
        guard let local = placed.result?.pageID.flatMap(UUID.init(uuidString:)) else { return false }
        return replicaPages[local]?.channel?.closed == false
    }

    /// requestRemotePage asks `host` to hand over one attachment of its page session `originSession`.
    func requestRemotePage(_ originSession: String, host: String) async -> RemotePageHandover {
        let argv: [String]
        do {
            argv = try RemoteSession.controlCommand(host: host, arguments: ["session", "overlay", "page-attach", "--target", originSession])
        } catch {
            return .refused("invalid host")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteCompanionDeadline)
        if result.refusedArguments {
            return .tooOld("the agterm on \(host) is too old for page companions")
        }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unanswered(stderr.isEmpty ? "\(host) gave no answer" : stderr)
        }
        if result.status != 0, reply.ok, reply.result?.companionPage != nil {
            return .interrupted("the connection to \(host) failed after it handed the page over")
        }
        guard result.status == 0, reply.ok, let page = reply.result?.companionPage else {
            if reply.refusesUnknown(.sessionCompanionPageAttach) {
                return .tooOld("the agterm on \(host) is too old for page companions")
            }
            return .refused(reply.error ?? "\(host) did not hand the page over")
        }
        return .page(page, parent: reply.result?.parent)
    }

    /// placeRemotePage shows `page`, handed over by `source`'s host, at `spot` here.
    func placeRemotePage(_ page: PresentationPage, from source: RemotePageOrigin, at spot: RemotePageSpot,
                         select: Bool) -> ControlResponse {
        let (originSession, binding, presentation) = (source.session, source.binding, source.presentation)
        let host = binding.host
        if case .url(let text) = page.source, HtmlSource.isLoopback(text) {
            return ControlResponse(ok: false, error: "a page on \(host)'s loopback cannot be shown on this Mac")
        }
        // the other Mac's browser profile says nothing about this one's
        if page.persistent, let failure = HtmlOverlayRegistry.shared.persistentStoreFailure() {
            return ControlResponse(ok: false, error: failure)
        }
        // the destination is read only now: the ssh wait lets the parent row, window or workspace close
        let store: AppStore
        let row: Session
        let parent: UUID?
        switch spot {
        case .companion(let parentID):
            guard let holder = library.store(forSession: parentID) else {
                return ControlResponse(ok: false, error: "its parent row here was closed")
            }
            switch holder.addReplicaPageCompanion(to: parentID, page: page, select: select,
                                                  remoteSessionID: originSession) {
            case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message)
            case .success(let created): (store, row, parent) = (holder, created, parentID)
            }
        case .root(let holder, let destination):
            guard library.windowID(for: holder) != nil else {
                return ControlResponse(ok: false, error: "the window or workspace to attach into was closed")
            }
            // a named workspace is created only once the handover succeeded, so a refused page adds none
            guard let workspace = destination.workspace(in: holder) else { return Self.workspaceNotCreated }
            guard holder.workspaces.contains(where: { $0.id == workspace }) else {
                return ControlResponse(ok: false, error: "the window or workspace to attach into was closed")
            }
            switch holder.addReplicaPageRoot(toWorkspace: workspace, host: host, name: binding.sessionName, page: page,
                                             select: select, remoteSessionID: originSession) {
            case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message)
            case .success(let created): (store, row, parent) = (holder, created, nil)
            }
        case .existing(let rowID):
            guard let holder = library.store(forSession: rowID) else {
                return ControlResponse(ok: false, error: "the row here was closed")
            }
            switch holder.fillReplicaPage(rowID, page: page) {
            case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message)
            case .success(let filled): (store, row, parent) = (holder, filled, filled.parentID)
            }
        }
        // the origin's page session, so New Companion on the row has that Mac make one there; the origin's endpoint
        // is what lets a companion attached later find this row as its parent. Only a headless origin's page row takes
        // the full stream: another Mac shows that page's asks and picks in its own window, so its root observes membership.
        store.bindRemote(RemoteBinding(remoteSessionID: originSession, daemonsByLocalPane: [:],
                                       presentationVersion: presentation.headless ? presentation.version : nil,
                                       origin: binding, originHeadless: presentation.headless),
                         forSession: row.id)
        if let companions = source.companions { store.baselineCompanions(companions, forSession: row.id) }
        if presentation.headless || parent == nil { startRemotePresentation(for: row) }
        guard let overlay = row.htmlOverlay, let origin = overlay.replicaOf,
              let serve = try? RemoteSession.pageServeCommand(host: host, token: page.token) else {
            store.closeSession(row.id)
            return ControlResponse(ok: false, error: "the page cannot be reached on \(host)")
        }
        // a URL page fetches nothing through it, but its channel still ends the row when the page closes there
        let channel = RemotePageChannel()
        replicaPages[overlay.id] = ReplicaPageRecord(session: row.id, origin: origin, channel: channel)
        _ = HtmlOverlayRegistry.shared.page(for: overlay, store: store, backgroundColor: page.backgroundColor,
                                            replica: Self.link(channel, ownPageCommandsLocal: true))
        let local = overlay.id, rowID = row.id
        channel.onClose = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.settleRemotePageOutcome(local, origin: origin, host: host)
                guard let holder = self.library.store(holdingSession: rowID) else { return }
                // a parked row is out of the visible lookup, and Undo would bring back a page that ended there
                if !holder.closeHtmlOverlay(local) { holder.finalizePendingClose(ofSession: rowID) }
            }
        }
        channel.start(serve, launcher: pageLauncher)
        if select, store === library.activeStore { actions.focusActiveSession() }
        return ControlResponse(ok: true, result: ControlResult(id: row.id.uuidString, pageID: local.uuidString,
                                                               parent: parent?.uuidString))
    }

    /// settleRemotePageOutcome copies the outcome the other Mac recorded for its page into the view's own, once that
    /// page ended there; an unreadable answer leaves the close's dismissal.
    private func settleRemotePageOutcome(_ local: UUID, origin: UUID, host: String) async {
        guard HtmlPageOutcomes.shared.outcome(for: local)?.outcome == .pending,
              let argv = try? RemoteSession.controlCommand(host: host, arguments: ["session", "overlay", "result",
                                                                                   "--page", origin.uuidString]) else { return }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8))
        HtmlPageOutcomes.shared.settle(local, like: reply?.result?.pageOutcome)
    }

    /// attachedParentRows are the top-level rows in `store` showing the origin parent of companion `remote`.
    func attachedParentRows(of remote: ControlRemoteSession, tree: ControlRemoteTree, host: String,
                            in store: AppStore) -> [Session] {
        guard let parent = remote.parent else { return [] }
        return store.workspaces.flatMap(\.sessions).filter {
            $0.parentID == nil && $0.showsOriginSession(parent, host: host, endpoint: tree.endpoint)
        }
    }

    /// attachRemotePageRow attaches a page `zmx tree` listed: a top-level page as a row of `workspace` (nil is `store`'s
    /// current one), a page companion under the one row here showing its parent.
    func attachRemotePageRow(_ remote: ControlRemoteSession, tree: ControlRemoteTree, host: String,
                             in store: AppStore, workspace target: ControlAttachWorkspace?) async -> ControlResponse {
        let origin = RemoteBinding.Origin(host: host, endpoint: tree.endpoint, sessionName: remote.name)
        guard remote.parent != nil else {
            let workspace: AttachDestination
            switch attachWorkspace(target, in: store) {
            case .failure(let response): return response
            case .success(let destination): workspace = destination
            }
            return await attachRemotePage(remote.id, origin: origin, presentation: PagePresentation(tree),
                                          at: .root(store: store, workspace: workspace), select: true,
                                          companions: remote.companions?.map(\.id))
        }
        let rows = attachedParentRows(of: remote, tree: tree, host: host, in: store)
        guard rows.count == 1, let parent = rows.first else {
            return ControlResponse(ok: false, error: rows.isEmpty
                ? "attach the page's parent session from \(host) first"
                : "more than one row here shows the page's parent")
        }
        return await attachRemotePage(remote.id, origin: origin, presentation: PagePresentation(tree),
                                      at: .companion(of: parent.id), select: true)
    }

    private func attachCreatedCompanion(_ pending: CreatedCompanion) async -> CompanionAttach {
        let outcome = await attachWhenListed(pending.id, host: pending.host, closed: "its parent row here was closed") { [library] in
            guard let store = library.store(forSession: pending.parent),
                  let workspace = store.workspace(forSession: pending.parent)?.id else { return nil }
            return RemotePlacement(store: store, workspace: workspace, parent: pending.parent, select: pending.select)
        }
        if case .attached(let attached) = outcome, let tint = pending.tint, let id = attached.result?.id.flatMap(UUID.init(uuidString:)) {
            library.store(forSession: id)?.setTint(tint, forSession: id)
        }
        return outcome
    }

    /// attachCreated attaches `created`, a session the origin of attached row `row` just made, beside the row: after
    /// it, or at its slot when `atSlot`, so the row can move under it.
    func attachCreated(_ created: String, host: String, beside row: UUID, atSlot: Bool) async -> ControlResponse {
        let outcome = await attachWhenListed(created, host: host, closed: "its row here was closed") { [library] in
            guard let store = library.store(forSession: row), let location = store.sessionLocation(ofSession: row) else { return nil }
            return RemotePlacement(store: store, workspace: location.workspace, select: !atSlot,
                                   index: atSlot ? location.index : location.index + 1)
        }
        switch outcome {
        case .attached(let response): return response
        case .failed(let reason): return ControlResponse(ok: false, error: reason)
        }
    }

    func attachWhenListed(_ id: String, host: String, closed: String,
                          place: () -> RemotePlacement?) async -> CompanionAttach {
        switch await attachListed(id, host: host, closed: closed, place: place) {
        case .attached(let response): return .attached(response)
        case .transport(let reason), .unavailable(let reason), .dropped(let reason), .refused(let reason): return .failed(reason)
        }
    }

    /// ListedAttach is how waiting for an origin session to become attachable ended.
    enum ListedAttach {
        case attached(ControlResponse)
        /// transport: the budget ran out on a listing that did not answer.
        case transport(String)
        /// unavailable: the origin listed the session elsewhere, or its last answer in the budget did not list it.
        case unavailable(String)
        /// dropped: the destination declined it after the wait.
        case dropped(String)
        /// refused: the listed session could not be attached as listed.
        case refused(String)
    }

    /// ExpectedOrigin is where a session must be listed to be attached: under `parent` of the zmx at `endpoint`.
    struct ExpectedOrigin {
        let parent: String
        let endpoint: ControlZmxEndpoint
    }

    // the destination is read again after every wait: the row may have moved or closed meanwhile
    func attachListed(_ id: String, host: String, expected: ExpectedOrigin? = nil, closed: String,
                      place: () -> RemotePlacement?) async -> ListedAttach {
        let deadline = hudClock().addingTimeInterval(Self.remoteCompanionReadyBudget)
        let unlisted = "it did not become attachable"
        var last = ListedAttach.transport(unlisted)
        var waited = false
        while true {
            if waited { await remoteCompanionPause() }
            waited = true
            let remaining = deadline.timeIntervalSince(hudClock())
            guard remaining > 0 else { return last }
            let listing = await remoteTree(host: host, deadline: min(Self.remoteTreeDeadline, remaining))
            guard let tree = listing.result?.remote else {
                last = .transport(listing.error ?? unlisted)
                continue
            }
            last = .unavailable(unlisted)
            // a membership id is canonical while the tree spells it as its origin did
            let match: (ControlRemoteSession) -> Bool = expected == nil ? { $0.id == id } : { Self.originID($0.id) == Self.originID(id) }
            guard let remote = tree.sessions.first(where: match) else { continue }
            if let expected, tree.endpoint != expected.endpoint || remote.parent.map(Self.originID) != Self.originID(expected.parent) {
                return .unavailable("it is no longer under that session")
            }
            guard let placement = place() else { return .dropped(closed) }
            let attached = attach(remote, from: tree, host: host, placement: placement)
            guard attached.ok else { return .refused(attached.error ?? "attach failed") }
            return .attached(attached)
        }
    }

    nonisolated static func originID(_ id: String) -> String { UUID(uuidString: id)?.uuidString ?? id }
}
