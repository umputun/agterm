/// The `hooks.list` read-back: where the file was read from, what failed to parse, and one row per hook.
public struct ControlHooks: Codable, Sendable, Equatable {
    public let path: String
    public let diagnostics: [ControlKeymapDiagnostic]
    public let hooks: [ControlHookEntry]

    public init(path: String, diagnostics: [ControlKeymapDiagnostic], hooks: [ControlHookEntry]) {
        self.path = path
        self.diagnostics = diagnostics
        self.hooks = hooks
    }
}

/// One hook's definition and live state. `runningPid`/`elapsedSeconds` are absent while idle;
/// `lastFailure` is absent until a run fails and again after the next clean run (a reload keeps it).
/// `retired` is true for a hook removed from the file whose child is still running; it lists after the
/// live rows so a hung script stays visible.
public struct ControlHookEntry: Codable, Sendable, Equatable {
    public let kind: String
    public let command: String
    public let line: Int
    public let runningPid: Int32?
    public let elapsedSeconds: Double?
    public let pending: Int
    public let dropped: UInt64
    public let lastFailure: String?
    public let retired: Bool?

    public init(kind: String, command: String, line: Int, runningPid: Int32? = nil, elapsedSeconds: Double? = nil,
                pending: Int = 0, dropped: UInt64 = 0, lastFailure: String? = nil, retired: Bool? = nil) {
        self.kind = kind
        self.command = command
        self.line = line
        self.runningPid = runningPid
        self.elapsedSeconds = elapsedSeconds
        self.pending = pending
        self.dropped = dropped
        self.lastFailure = lastFailure
        self.retired = retired
    }
}
