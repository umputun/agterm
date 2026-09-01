import Foundation

/// What running a remote command produced. `status` is ssh's exit code, which carries the far side's own
/// exit status once the connection itself succeeded.
public struct RemoteCommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs an ssh invocation somewhere that is not the main actor. The app supplies a `Process`-backed
/// implementation; tests supply a fake, which is what lets the end-to-end coverage run without a second
/// Mac.
public protocol RemoteCommandRunner: Sendable {
    func run(_ argv: [String], deadline: TimeInterval) async -> RemoteCommandResult
}

/// One open window's projection, paired with the identity the tree payload does not carry.
public struct RemoteWindowProjection: Sendable {
    public let id: String
    public let name: String
    public let tree: ControlTree

    public init(id: String, name: String, tree: ControlTree) {
        self.id = id
        self.name = name
        self.tree = tree
    }
}

/// Turns an agterm's own windows into the per-pane endpoints an attach needs, and reads that answer back
/// when it arrives over ssh.
public enum RemoteTreeMerger {
    public enum MergeError: Error, Equatable {
        /// The remote answered, but not with a readable `zmx tree` document — an older CLI, or a
        /// truncated read.
        case malformedProjection
        /// The remote is too old to report where its zmx and its daemons live, so nothing can be attached.
        case missingEndpoint
        /// The remote command itself failed; carries whatever it said.
        case remoteFailed(String)

        public var message: String {
            switch self {
            case .malformedProjection:
                return "the remote did not return a readable session list"
            case .missingEndpoint:
                return "the remote agterm is too old to report its zmx endpoint"
            case let .remoteFailed(reason):
                return reason
            }
        }
    }

    /// The remote's own explanation for a nonzero exit, or nil when it gave none.
    ///
    /// `agtermctl --json` prints a not-ok response to STDOUT and then exits nonzero, so stderr is empty on
    /// exactly the failures worth reporting. An ok-looking payload from a nonzero process is never
    /// accepted: the caller checks the status first and only comes here for the reason.
    public static func remoteError(stdout: String) -> String? {
        let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(stdout.utf8))
        guard let response, !response.ok else { return nil }
        return response.error?.trimmedOrNil
    }

    /// Every attachable session across the windows given, flat, each row naming where it lives.
    ///
    /// Only a session whose every pane resolves to a daemon that is both claimed and running is returned.
    /// A daemon that vanished, one zmx could not read, and a split whose second pane has no row are all
    /// dropped rather than offered: `zmx attach` CREATES a missing daemon, handing back a fresh shell
    /// wearing the name of the session that was asked for. The zmx observation is a subprocess snapshot
    /// taken beside the model walk rather than inside it, so these guards are eligibility rules and not
    /// only a defence against that gap.
    ///
    /// An empty result is a successful answer. It cannot be told apart from a store that is simply not
    /// running in `live` mode, and does not try to be: `zmx list` is the restore-mode diagnostic.
    public static func candidates(windows: [RemoteWindowProjection],
                                  inventory: ControlZmxInventory) throws -> ControlRemoteTree {
        guard let endpoint = inventory.endpoint else { throw MergeError.missingEndpoint }

        var daemons: [String: [String: String]] = [:]
        for entry in inventory.entries where entry.state == "claimed" && entry.observation == "running" {
            guard let sessionID = entry.sessionID, let pane = entry.pane else { continue }
            // this command promises every row it returns is attachable, so a name `zmx attach` would
            // deterministically refuse must not reach the caller
            guard ZmxSupport.isDaemonName(entry.daemon) else { continue }
            daemons[sessionID, default: [:]][pane] = entry.daemon
        }

        let sessions = windows.flatMap { window in
            window.tree.workspaces.flatMap { workspace in
                workspace.sessions.compactMap { node in
                    remoteSession(node, window: window, workspace: workspace,
                                  daemons: daemons[node.id] ?? [:])
                }
            }
        }
        return ControlRemoteTree(host: nil, endpoint: endpoint, sessions: sessions)
    }

    /// Reads back what the far side's own `zmx tree` printed. The caller must reject a nonzero exit BEFORE
    /// calling this, and stamps the ssh destination it was given onto the result: the far side has no idea
    /// what name reached it.
    public static func decode(stdout: String) throws -> ControlRemoteTree {
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(stdout.utf8)) else {
            throw MergeError.malformedProjection
        }
        guard response.ok else {
            throw MergeError.remoteFailed(response.error ?? "the remote session list could not be read")
        }
        // an older far side answers ok to `zmx tree` with no `remote` result at all
        guard let remote = response.result?.remote else { throw MergeError.malformedProjection }
        return remote
    }

    private static func remoteSession(_ node: ControlSessionNode, window: RemoteWindowProjection,
                                      workspace: ControlWorkspaceNode,
                                      daemons: [String: String]) -> ControlRemoteSession? {
        // a claimed, running daemon is not proof the owner is looking at it: a launch that asked for live
        // and fell back preserves its daemons while showing fresh ordinary shells, and so does a mode
        // switch. `backedByZmx` is the store's own answer to "is every pane actually attached".
        guard node.backedByZmx == true else { return nil }
        guard let left = daemons["left"] else { return nil }
        var panes = [ControlRemotePane(pane: "left", daemon: left, foreground: node.foreground)]
        if node.hasSplit == true {
            guard let right = daemons["right"] else { return nil }
            panes.append(ControlRemotePane(pane: "right", daemon: right, foreground: node.splitForeground))
        }
        return ControlRemoteSession(id: node.id, name: node.name, windowID: window.id,
                                    windowName: window.name, workspaceID: workspace.id,
                                    workspaceName: workspace.name, context: node.context, cwd: node.cwd,
                                    splitAxis: node.hasSplit == true ? node.splitAxis : nil, panes: panes)
    }
}
