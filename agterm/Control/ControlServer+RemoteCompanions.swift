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
        case .replica, nil: break
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
        let result = await remoteRunner.run(argv, deadline: Self.remoteCompanionDeadline)
        if result.refusedArguments {
            return ControlResponse(ok: false, error: "the agterm on \(host) is too old for companions")
        }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return ControlResponse(ok: false, error: "\(host) gave no answer\(stderr.isEmpty ? "" : " (\(stderr))"); "
                                   + "whether the companion was created there is unknown")
        }
        // a full receipt with a failed transport still names work the origin did, so it is reported, never redone
        if result.status != 0, reply.ok, let created = reply.result?.id, UUID(uuidString: created) != nil {
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
            outcome = await attachOriginPage(pending)
        } else {
            outcome = await attachCreatedCompanion(pending)
        }
        switch outcome {
        case .attached(let response):
            return response
        case .failed(let reason):
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

    private enum CompanionAttach {
        case attached(ControlResponse)
        case failed(String)
    }

    // a page is attachable as soon as it exists, so there is nothing to wait for
    private func attachOriginPage(_ pending: CreatedCompanion) async -> CompanionAttach {
        let attached = await attachRemotePage(pending.id, host: pending.host, parent: pending.parent, select: pending.select)
        return attached.ok ? .attached(attached) : .failed(attached.error ?? "attach failed")
    }

    /// attachRemotePage asks `host` for one attachment of its page companion `originSession` and shows it under the
    /// row `parent` here. The page stays that Mac's: closing the row here ends only this attachment's channel.
    func attachRemotePage(_ originSession: String, host: String, parent: UUID, select: Bool) async -> ControlResponse {
        let argv: [String]
        do {
            argv = try RemoteSession.controlCommand(host: host, arguments: ["session", "overlay", "page-attach", "--target", originSession])
        } catch {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteCompanionDeadline)
        if result.refusedArguments {
            return ControlResponse(ok: false, error: "the agterm on \(host) is too old for page companions")
        }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return ControlResponse(ok: false, error: stderr.isEmpty ? "\(host) gave no answer" : stderr)
        }
        guard result.status == 0, reply.ok, let page = reply.result?.companionPage else {
            if reply.refusesUnknown(.sessionCompanionPageAttach) {
                return ControlResponse(ok: false, error: "the agterm on \(host) is too old for page companions")
            }
            return ControlResponse(ok: false, error: reply.error ?? "\(host) did not hand the page over")
        }
        if case .url(let text) = page.source, HtmlSource.isLoopback(text) {
            return ControlResponse(ok: false, error: "a page on \(host)'s loopback cannot be shown on this Mac")
        }
        // the other Mac's browser profile says nothing about this one's
        if page.persistent, let failure = HtmlOverlayRegistry.shared.persistentStoreFailure() {
            return ControlResponse(ok: false, error: failure)
        }
        guard let store = library.store(forSession: parent) else {
            return ControlResponse(ok: false, error: "its parent row here was closed")
        }
        let row: Session
        switch store.addReplicaPageCompanion(to: parent, page: page, select: select) {
        case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message)
        case .success(let created): row = created
        }
        // the origin's page session, so New Companion on the row has that Mac make a sibling
        store.bindRemote(RemoteBinding(remoteSessionID: originSession, daemonsByLocalPane: [:], presentationVersion: nil),
                         forSession: row.id)
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
                                                               parent: parent.uuidString))
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

    /// attachRemotePageRow attaches a page companion `zmx tree` listed under the one row here showing its parent.
    func attachRemotePageRow(_ remote: ControlRemoteSession, tree: ControlRemoteTree, host: String,
                             in store: AppStore) async -> ControlResponse {
        let rows = store.workspaces.flatMap(\.sessions).filter { row in
            guard row.parentID == nil, row.remoteHost == host, let binding = row.remotePresentation?.binding else { return false }
            return binding.remoteSessionID == remote.parent && binding.origin?.endpoint == tree.endpoint
        }
        guard rows.count == 1, let parent = rows.first else {
            return ControlResponse(ok: false, error: rows.isEmpty
                ? "attach the page's parent session from \(host) first"
                : "more than one row here shows the page's parent")
        }
        return await attachRemotePage(remote.id, host: host, parent: parent.id, select: true)
    }

    // the parent's store and workspace are read again after every wait: the row may have moved or closed meanwhile
    private func attachCreatedCompanion(_ pending: CreatedCompanion) async -> CompanionAttach {
        let deadline = hudClock().addingTimeInterval(Self.remoteCompanionReadyBudget)
        var reason = "it did not become attachable"
        var waited = false
        while true {
            if waited { await remoteCompanionPause() }
            waited = true
            let remaining = deadline.timeIntervalSince(hudClock())
            guard remaining > 0 else { return .failed(reason) }
            let listing = await remoteTree(host: pending.host, deadline: min(Self.remoteTreeDeadline, remaining))
            guard let tree = listing.result?.remote else {
                reason = listing.error ?? reason
                continue
            }
            guard let remote = tree.sessions.first(where: { $0.id == pending.id }) else { continue }
            guard let store = library.store(forSession: pending.parent),
                  let workspace = store.workspace(forSession: pending.parent)?.id else {
                return .failed("its parent row here was closed")
            }
            let placement = RemotePlacement(store: store, workspace: workspace, parent: pending.parent, select: pending.select)
            let attached = attach(remote, from: tree, host: pending.host, placement: placement)
            guard attached.ok else { return .failed(attached.error ?? "attach failed") }
            if let tint = pending.tint, let id = attached.result?.id.flatMap(UUID.init(uuidString:)) {
                store.setTint(tint, forSession: id)
            }
            return .attached(attached)
        }
    }
}
