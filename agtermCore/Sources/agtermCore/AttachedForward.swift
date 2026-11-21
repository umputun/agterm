import Foundation

/// AttachedOrigin is where a row attached from another host runs: the host, the zmx namespace there and the origin's own
/// session id. Rows share an origin when host and endpoint match.
public struct AttachedOrigin: Equatable, Sendable {
    public let host: String
    public let endpoint: ControlZmxEndpoint
    public let session: String
    public let headless: Bool

    /// init reads `row`'s binding; nil for a local row, a server window's row or a binding that cannot reach its origin.
    @MainActor public init?(_ row: Session) {
        guard row.remoteHost != nil, let binding = row.remotePresentation?.binding, !binding.catalogOwned,
              let origin = binding.origin else { return nil }
        host = origin.host
        endpoint = origin.endpoint
        session = binding.remoteSessionID
        headless = binding.originHeadless
    }

    public func shares(_ other: AttachedOrigin) -> Bool { host == other.host && endpoint == other.endpoint }

    /// originPaneID is the origin's token for `row`'s local pane `identity`, the value its `AGTERM_PANE_ID` carries there.
    @MainActor public static func originPaneID(of row: Session, local identity: UUID) -> String? {
        row.remotePresentation?.binding.remotePane(forLocal: identity)?.uuidString
    }
}

/// AttachedForward is an action on a row attached from another host, as the origin's own `agtermctl` arguments.
public enum AttachedForward: Equatable, Sendable {
    case terminate(sessions: [String], undoable: Bool)
    case restart(session: String, paneID: String, command: String?)
    case killPane(session: String, pane: ZmxPaneRole, paneID: String)
    case convert(session: String)
    /// moveCompanion puts the origin's session `session` under its session `parent`, at the end of that group: the
    /// viewer places its own row at the requested slot afterwards.
    case moveCompanion(session: String, parent: String)
    /// promoteCompanion makes the origin's companion `session` top-level after its group there: the viewer places its
    /// own row afterwards.
    case promoteCompanion(session: String)
    /// duplicate starts a shell after the origin session, as a server window's Duplicate does, without moving the
    /// origin's own selection.
    case duplicate(after: String, cwd: String?)
    case split(session: String, mode: String, axis: String?)
    case closeSplit(session: String)
    case scratch(session: String, mode: String, command: String?)
    case restore(session: String, paneID: String, pin: ControlRestoreOverride)

    /// words carry each free value joined to its flag, so a value starting with `-` is never read as an option.
    public var words: [String] {
        switch self {
        case .terminate(let sessions, let undoable):
            ["session", "close"] + sessions.flatMap { ["--target", $0] } + (undoable ? ["--undoable"] : [])
        case .restart(let session, let paneID, let command):
            ["session", "restart", "--target", session, "--pane-id", paneID] + (command.map { ["--command=" + $0] } ?? [])
        case .killPane(let session, let pane, let paneID):
            ["zmx", "kill", "--target", session, "--pane", pane.rawValue, "--pane-id", paneID, "--force"]
        case .convert(let session): ["session", "convert", "--companion", "--target", session]
        case .moveCompanion(let session, let parent): ["session", "move", "--target", session, "--parent", parent]
        case .promoteCompanion(let session): ["session", "move", "--target", session, "--top-level"]
        case .duplicate(let after, let cwd):
            ["session", "new", "--after", after, "--no-select"] + (cwd.map { ["--cwd=" + $0] } ?? [])
        case .split(let session, let mode, let axis):
            ["session", "split", "visibility", mode, "--target", session] + (axis.map { ["--axis", $0] } ?? [])
        case .closeSplit(let session): ["session", "split", "close", "--target", session]
        case .scratch(let session, let mode, let command):
            ["session", "scratch", mode, "--target", session] + (command.map { ["--command=" + $0] } ?? [])
        case .restore(let session, let paneID, let pin):
            ["session", "restore", "--target", session, "--pane-id", paneID] + {
                switch pin {
                case .pin: []
                case .pinNone: ["--none"]
                case .unpin: ["--clear"]
                }
            }()
        }
    }

    /// operands follow a `--`, so a restore line starting with `-` stays the line.
    public var operands: [String] {
        if case .restore(_, _, .pin(let command)) = self { return [command] }
        return []
    }

    /// command is the wire command the origin's `agtermctl` sends for `words`, which an origin too old for it names.
    public var command: Command {
        switch self {
        case .terminate: .sessionClose
        case .restart: .sessionRestart
        case .killPane: .zmxKillPane
        case .convert: .sessionCompanionConvert
        case .moveCompanion: .sessionCompanionMove
        case .promoteCompanion: .sessionCompanionPromote
        case .duplicate: .sessionNew
        case .split: .sessionSplit
        case .closeSplit: .sessionSplitClose
        case .scratch: .sessionScratch
        case .restore: .sessionRestore
        }
    }

    /// outcome reads what the origin's `agtermctl` printed. A reply the origin did not finish sending is unknown, never
    /// a refusal: the request may have run there, so it is reported and never sent again.
    public func outcome(of result: RemoteCommandResult, host: String) -> AttachedOutcome {
        let tooOld = "the agterm on \(host) is too old for this"
        if result.refusedArguments { return .refused(tooOld) }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unknown("\(host) gave no answer\(stderr.isEmpty ? "" : " (\(stderr))"); whether \(what) there is unknown")
        }
        if reply.ok { return .done(reply) }
        // another Mac made it top-level there already: still not ok, so the viewer places its row but seeds no baseline
        if case .promoteCompanion = self, reply.error == CompanionPromotionRefusal.notCompanion.message { return .done(reply) }
        if reply.refusesUnknown(command) { return .refused(tooOld) }
        return .refused(reply.error ?? "the command failed on \(host)")
    }

    /// what names the action in an unknown-outcome error.
    public var what: String {
        switch self {
        case .terminate: "the session was ended"
        case .restart: "the pane was restarted"
        case .killPane: "the pane was killed"
        case .convert: "the session was converted"
        case .moveCompanion: "the companion was moved"
        case .promoteCompanion: "the companion became a top-level session"
        case .duplicate: "a session was created"
        case .split, .closeSplit: "the split changed"
        case .scratch: "the scratch changed"
        case .restore: "the restore command was set"
        }
    }
}

/// AttachedOutcome is what became of a request sent to an attached row's origin.
public enum AttachedOutcome: Equatable, Sendable {
    /// done is the origin's ok reply, or its refusal of a promotion the session already satisfies there.
    case done(ControlResponse)
    /// refused means the origin did not do it, with the reason to show.
    case refused(String)
    /// unknown means the origin may have done it; the reason says so.
    case unknown(String)
}
