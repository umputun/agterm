import Foundation

extension ControlDispatcher {
    func dispatchSessionRestore(_ request: ControlRequest) -> ControlResponse {
        switch Self.restoreUpdate(request.args) {
        case .failure(let rejection): return ControlResponse(ok: false, error: rejection.message)
        case .success(let update): return actions.setSessionRestore(request.target, window: request.args?.window, update: update)
        }
    }

    /// restoreUpdate parses `session.restore`'s `set`|`none`|`clear` mode into a `ControlRestoreOverride` and the pane
    /// selector into a `StatusPane`. A pinned command is validated but NEVER rewritten — it is a shell line, so
    /// metacharacters are the point; it is rejected only for being absent, carrying control characters, or exceeding
    /// the storage cap. An EMPTY command means the same pinned-to-nothing state as `none`. `paneID` rides through
    /// opaquely (no session here to resolve it).
    static func restoreUpdate(_ args: ControlArgs?) -> Result<ControlSessionRestoreUpdate, ArgumentRejection> {
        let pin: ControlRestoreOverride
        switch args?.mode ?? "" {
        case "set":
            guard let command = args?.command else {
                return .failure(ArgumentRejection(message: "session.restore set requires a command"))
            }
            // a control character would smuggle an extra line (or an escape sequence) into the shell the
            // override is typed into, so the whole class is rejected — tab included.
            guard !CommandRestore.hasControlCharacter(command) else {
                return .failure(ArgumentRejection(message: "command must not contain control characters"))
            }
            guard command.utf8.count <= ControlRestoreOverride.maxCommandBytes else {
                return .failure(ArgumentRejection(message: "command too long (max \(ControlRestoreOverride.maxCommandBytes) bytes)"))
            }
            pin = .pin(command)
        case "none":
            pin = .pinNone
        case "clear":
            pin = .unpin
        default:
            return .failure(ArgumentRejection(message: "invalid restore mode: \(args?.mode ?? "") (set|none|clear)"))
        }
        var pane: StatusPane?
        if let raw = args?.pane {
            guard let parsed = StatusPane(controlName: raw) else {
                return .failure(ArgumentRejection(message: "--pane must be left, right, or scratch"))
            }
            pane = parsed
        }
        return .success(ControlSessionRestoreUpdate(pin: pin, pane: pane, paneID: args?.paneID))
    }

    /// refusesArguments is whether `request` fails the argument checks its command makes before any host is asked, for
    /// a route that runs ahead of the dispatcher and leaves such a request to it.
    public static func refusesArguments(_ request: ControlRequest) -> Bool {
        switch request.cmd {
        case .zmxKill, .zmxKillPane:
            if case .failure = killArguments(request) { return true }
        case .sessionRestart:
            if case .failure = restartOptions(request.args) { return true }
        case .sessionRestore:
            if case .failure = restoreUpdate(request.args) { return true }
        default:
            break
        }
        return false
    }

    /// `session.restart`: the line is a shell line and is never rewritten; an absent one asks the host to
    /// replay the pane's foreground program. A pane must be named, by token or by role, because a default
    /// would restart a shell the caller never addressed.
    func dispatchSessionRestart(_ request: ControlRequest) async -> ControlResponse {
        switch Self.restartOptions(request.args) {
        case .failure(let rejection): return ControlResponse(ok: false, error: rejection.message)
        case .success(let options): return await actions.restartSessionPane(request.target, window: request.args?.window, options: options)
        }
    }

    /// restartOptions validates `session.restart`'s arguments, here and in a remote window forwarding it to its server.
    static func restartOptions(_ args: ControlArgs?) -> Result<ControlSessionRestartOptions, ArgumentRejection> {
        let command = args?.command
        if let command {
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(ArgumentRejection(message: "session.restart takes a non-empty command, or none to replay"))
            }
            guard !CommandRestore.hasControlCharacter(command) else {
                return .failure(ArgumentRejection(message: "command must not contain control characters"))
            }
            guard command.utf8.count <= ControlSessionRestartOptions.maxCommandBytes else {
                return .failure(ArgumentRejection(message: "command too long (max \(ControlSessionRestartOptions.maxCommandBytes) bytes)"))
            }
        }
        var pane: StatusPane?
        if let raw = args?.pane {
            guard let parsed = StatusPane(controlName: raw) else { return .failure(ArgumentRejection(message: "--pane must be left, right, or scratch")) }
            pane = parsed
        }
        guard pane != .scratch else {
            return .failure(ArgumentRejection(message: "session.restart does not address the scratch pane"))
        }
        let paneID = args?.paneID.flatMap { $0.isEmpty ? nil : $0 }
        guard pane != nil || paneID != nil else {
            return .failure(ArgumentRejection(message: "session.restart requires --pane-id or --pane"))
        }
        return .success(ControlSessionRestartOptions(command: command, pane: pane, paneID: paneID))
    }
}

struct ArgumentRejection: Error {
    let message: String
}
