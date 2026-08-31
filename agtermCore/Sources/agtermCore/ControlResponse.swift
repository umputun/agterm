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
}
