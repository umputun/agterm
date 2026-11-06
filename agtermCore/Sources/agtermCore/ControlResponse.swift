/// The single response written back per connection. `ok` gates `result` (on success) vs `error`.
public struct ControlResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public var result: ControlResult?
    public var error: String?

    public init(ok: Bool, result: ControlResult? = nil, error: String? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
    }

    /// refusesUnknown names the reply an app predating `command` gives: it cannot decode the command, so it
    /// refused the request before doing anything. Every other error is the server's own.
    public func refusesUnknown(_ command: Command) -> Bool {
        guard !ok, let error else { return false }
        return error.hasPrefix("invalid request:") && error.contains(command.rawValue)
    }
}
