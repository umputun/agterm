/// TintRejection is the refusal text of a tint request the dispatcher will not pass on.
struct TintRejection: Error {
    let message: String
}

extension ControlDispatcher {
    /// `session.context`: `set` takes `text`, `clear` takes none. An invalid value is REJECTED, never
    /// normalized, so `clear` stays the only route to nil and a refused call leaves the previous context
    /// standing. The mode is required rather than inferred from `text`, which is what makes "both" and
    /// "neither" reachable errors for a raw socket client that never sees the CLI's own exclusivity check.
    func dispatchSessionContext(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let context: String?
        switch args?.mode ?? "" {
        case "set":
            guard let text = args?.text else {
                return ControlResponse(ok: false, error: "session.context set requires text")
            }
            switch Session.validateContext(text) {
            case .valid(let value): context = value
            case .invalid(let message): return ControlResponse(ok: false, error: message)
            }
        case "clear":
            guard args?.text == nil else {
                return ControlResponse(ok: false, error: "session.context clear takes no text")
            }
            context = nil
        default:
            return ControlResponse(ok: false, error: "invalid context mode: \(args?.mode ?? "") (set|clear)")
        }
        return actions.setSessionContext(request.target, window: args?.window, context: context)
    }

    /// `session.tint` and `workspace.tint` share one parse, so both refuse the same input the same way.
    func dispatchTint(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        switch Self.tintUpdate(args, command: request.cmd.rawValue) {
        case .failure(let rejection):
            return ControlResponse(ok: false, error: rejection.message)
        case .success(let update) where request.cmd == .workspaceTint:
            return actions.setWorkspaceTint(request.target, window: args?.window, update: update)
        case .success(let update):
            return actions.setSessionTint(request.target, window: args?.window, update: update)
        }
    }

    /// tintUpdate parses a set or clear. The mode is required, a set needs a color, and a clear refuses a
    /// color or placement rather than ignoring it, so a contradictory raw request never half-applies.
    static func tintUpdate(_ args: ControlArgs?, command: String) -> Result<ControlTintUpdate, TintRejection> {
        switch args?.mode ?? "" {
        case "set":
            guard let raw = args?.tint else { return .failure(TintRejection(message: "\(command) set requires a color")) }
            return tintColor(raw).flatMap { color in
                tintParts(args?.tintOn).map { ControlTintUpdate.set(color, parts: $0) }
            }
        case "clear":
            guard args?.tint == nil, args?.tintOn == nil else {
                return .failure(TintRejection(message: "\(command) clear takes no color or placement"))
            }
            return .success(.clear)
        default:
            return .failure(TintRejection(message: "invalid tint mode: \(args?.mode ?? "") (set|clear)"))
        }
    }

    /// creationTint parses `session.new`/`workspace.new`'s optional tint before anything is created, so an
    /// invalid one leaves no session or workspace behind. A placement without a color is refused.
    static func creationTint(_ args: ControlArgs?) -> Result<SidebarTint?, TintRejection> {
        guard let raw = args?.tint else {
            guard args?.tintOn == nil else { return .failure(TintRejection(message: "--tint-on requires --tint")) }
            return .success(nil)
        }
        return tintColor(raw).flatMap { color in
            tintParts(args?.tintOn).map { SidebarTint(color: color, parts: $0 ?? [.icon]) }
        }
    }

    private static func tintColor(_ raw: String) -> Result<TintColor, TintRejection> {
        guard let color = TintColor(rawValue: raw.lowercased()) else {
            return .failure(TintRejection(message: "invalid tint: \(raw) (\(TintColor.validNamesList))"))
        }
        return .success(color)
    }

    private static func tintParts(_ raw: [String]?) -> Result<Set<TintPart>?, TintRejection> {
        guard let raw else { return .success(nil) }
        guard let parts = SidebarTint.parseParts(raw) else {
            let shown = raw.joined(separator: ",")
            return .failure(TintRejection(message: "invalid tint placement: \(shown) (\(TintPart.validNamesList))"))
        }
        return .success(parts)
    }
}
