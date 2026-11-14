import Foundation

extension ControlDispatcher {
    /// `session.restore`: parse the `set`|`none`|`clear` mode into a `ControlRestoreOverride` and the pane
    /// selector into a `StatusPane`, then hand both to the host. A pinned command is validated but NEVER
    /// rewritten — it is a shell line, so metacharacters are the point; it is rejected only for being
    /// absent, carrying control characters, or exceeding the storage cap. An EMPTY command means the same
    /// pinned-to-nothing state as `none`. `paneID` rides through opaquely (no session here to resolve it).
    func dispatchSessionRestore(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let pin: ControlRestoreOverride
        switch args?.mode ?? "" {
        case "set":
            guard let command = args?.command else {
                return ControlResponse(ok: false, error: "session.restore set requires a command")
            }
            // a control character would smuggle an extra line (or an escape sequence) into the shell the
            // override is typed into, so the whole class is rejected — tab included.
            guard !CommandRestore.hasControlCharacter(command) else {
                return ControlResponse(ok: false, error: "command must not contain control characters")
            }
            guard command.utf8.count <= ControlRestoreOverride.maxCommandBytes else {
                return ControlResponse(ok: false,
                                       error: "command too long (max \(ControlRestoreOverride.maxCommandBytes) bytes)")
            }
            pin = .pin(command)
        case "none":
            pin = .pinNone
        case "clear":
            pin = .unpin
        default:
            return ControlResponse(ok: false,
                                   error: "invalid restore mode: \(args?.mode ?? "") (set|none|clear)")
        }
        let pane: StatusPane?
        switch parsePane(args?.pane) {
        case .pane(let parsed): pane = parsed
        case .rejected(let rejection): return rejection
        }
        let update = ControlSessionRestoreUpdate(pin: pin, pane: pane, paneID: args?.paneID)
        return actions.setSessionRestore(request.target, window: args?.window, update: update)
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
    static func restartOptions(_ args: ControlArgs?) -> Result<ControlSessionRestartOptions, RestartRejection> {
        let command = args?.command
        if let command {
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(RestartRejection(message: "session.restart takes a non-empty command, or none to replay"))
            }
            guard !CommandRestore.hasControlCharacter(command) else {
                return .failure(RestartRejection(message: "command must not contain control characters"))
            }
            guard command.utf8.count <= ControlSessionRestartOptions.maxCommandBytes else {
                return .failure(RestartRejection(message: "command too long (max \(ControlSessionRestartOptions.maxCommandBytes) bytes)"))
            }
        }
        var pane: StatusPane?
        if let raw = args?.pane {
            guard let parsed = StatusPane(controlName: raw) else { return .failure(RestartRejection(message: "--pane must be left, right, or scratch")) }
            pane = parsed
        }
        guard pane != .scratch else {
            return .failure(RestartRejection(message: "session.restart does not address the scratch pane"))
        }
        let paneID = args?.paneID.flatMap { $0.isEmpty ? nil : $0 }
        guard pane != nil || paneID != nil else {
            return .failure(RestartRejection(message: "session.restart requires --pane-id or --pane"))
        }
        return .success(ControlSessionRestartOptions(command: command, pane: pane, paneID: paneID))
    }
}

struct RestartRejection: Error {
    let message: String
}
