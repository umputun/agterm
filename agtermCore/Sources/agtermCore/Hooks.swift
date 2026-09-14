import Foundation

/// What makes two `hooks.conf` lines the same hook: the event kind and the shell line, outer whitespace
/// trimmed. The line number is deliberately not part of it, so inserting a comment above a hook keeps its
/// running child and queue across a reload.
public struct HookIdentity: Hashable, Sendable {
    public let kind: ControlEventKind
    public let command: String

    public init(kind: ControlEventKind, command: String) {
        self.kind = kind
        self.command = command
    }
}

/// One `on <kind> <shell...>` line. `line` is display data for diagnostics and `hooks list`.
public struct HookEntry: Equatable, Sendable {
    public let identity: HookIdentity
    public let line: Int

    public var kind: ControlEventKind { identity.kind }
    public var command: String { identity.command }

    public init(identity: HookIdentity, line: Int) {
        self.identity = identity
        self.line = line
    }
}

/// The parsed `hooks.conf`, entries in file order.
public struct Hooks: Equatable, Sendable {
    public let entries: [HookEntry]

    public init(entries: [HookEntry] = []) {
        self.entries = entries
    }
}

/// Parses `hooks.conf`. Blank lines and whole-line `#` comments are skipped; everything after the kind is
/// the shell line verbatim, so an inline `#`, quotes, pipes and `$VAR` reach `/bin/sh` untouched. A malformed
/// line or a duplicate kind+command is diagnosed and skipped without stopping later lines. Never throws.
public func parseHooksConf(_ text: String) -> (hooks: Hooks, diagnostics: [KeymapDiagnostic]) {
    var entries: [HookEntry] = []
    var seen: Set<HookIdentity> = []
    var diagnostics: [KeymapDiagnostic] = []

    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    for (index, rawLine) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let lineNumber = index + 1
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }

        let verb = String(line.prefix(while: { !$0.isWhitespace }))
        guard verb == "on" else {
            diagnostics.append(KeymapDiagnostic(line: lineNumber, message: "unknown verb '\(verb)'"))
            continue
        }
        let rest = line.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
        let rawKind = String(rest.prefix(while: { !$0.isWhitespace }))
        guard !rawKind.isEmpty else {
            diagnostics.append(KeymapDiagnostic(line: lineNumber, message: "on requires an event kind"))
            continue
        }
        guard let kind = ControlEventKind(rawValue: rawKind) else {
            diagnostics.append(KeymapDiagnostic(line: lineNumber, message: "unknown event kind '\(rawKind)'"))
            continue
        }
        let command = rest.dropFirst(rawKind.count).trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            diagnostics.append(KeymapDiagnostic(line: lineNumber, message: "hook for '\(rawKind)' has no shell line"))
            continue
        }
        let identity = HookIdentity(kind: kind, command: command)
        guard seen.insert(identity).inserted else {
            diagnostics.append(KeymapDiagnostic(
                line: lineNumber, message: "hook 'on \(rawKind) \(command)' is already defined; hook skipped"))
            continue
        }
        entries.append(HookEntry(identity: identity, line: lineNumber))
    }
    return (Hooks(entries: entries), diagnostics)
}
