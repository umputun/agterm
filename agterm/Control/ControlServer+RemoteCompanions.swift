import Foundation
import agtermCore

/// RemoteCompanionRequest is a companion the origin of a remote row is asked to create under its own session.
enum RemoteCompanionRequest {
    case terminal(CompanionOptions)
    case duplicate

    var tint: SidebarTint? {
        if case .terminal(let options) = self { return options.tint }
        return nil
    }

    var command: Command {
        switch self {
        case .terminal: .sessionCompanionNew
        case .duplicate: .sessionCompanionDuplicate
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
        }
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
        let parentID = (store.parent(of: row) ?? row).id
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
        guard tree.sessions.contains(where: { $0.id == origin }) else {
            return ControlResponse(ok: false, error: "the session on \(host) is not attachable now; nothing was created")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteCompanionDeadline)
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
        switch await attachCreatedCompanion(pending) {
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
