import Foundation

/// A user-defined command: a shell line run via `/bin/sh -c`, optionally bound to a keyboard
/// shortcut and always listed in the action palette.
///
/// The `command` body may contain `{AGT_X}` template tokens (see `CommandContext`), expanded at
/// fire time; the same values are also exported as `$AGT_X` environment variables on the spawned
/// process. An empty `shortcut` means palette-only (no keybind).
public struct CustomCommand: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// Display name, shown in the palette and used in the failure banner.
    public var name: String
    /// The shell line run via `/bin/sh -c`, with `{AGT_X}` tokens expanded at fire time.
    public var command: String
    /// The keybind string (e.g. `cmd+shift+e` or `ctrl+a>b`); empty means palette-only.
    public var shortcut: String

    public init(id: UUID = UUID(), name: String, command: String, shortcut: String) {
        self.id = id
        self.name = name
        self.command = command
        self.shortcut = shortcut
    }
}

/// The already-resolved session context for a command fire: one field per `{AGT_X}` token.
///
/// The app target builds this from the active session at fire time; agtermCore only turns it into
/// the token substitutions (`expand`) and the environment dictionary (`environment`). Both derive
/// from the single `tokens` table, so the `{AGT_X}` set and the `$AGT_X` set can never drift.
public struct CommandContext: Equatable, Sendable {
    /// Which pane a command fired from. The raw values are exactly the `--pane` argument strings, so
    /// `pane.rawValue` is always a valid `session.type`/`session.text --pane` value.
    public enum Pane: String, Equatable, Sendable {
        case left
        case right
    }

    public var sessionID: String
    public var sessionName: String
    public var sessionPWD: String
    public var workspaceID: String
    public var workspaceName: String
    public var windowID: String
    public var windowName: String
    /// The pane that had focus at fire time — `.left` (main) or `.right` (split). Reflects the pane's
    /// physical surface slot: a session that has only ever had a main pane reports `.left`, but a promoted
    /// split survivor (the primary pane exited and the split pane took over) reports `.right`, since that
    /// surface still lives in the `splitSurface` slot and is where `session.type --pane` reaches it. Typed
    /// (not a raw `String`) so `rawValue` can only be `left`/`right`; it is consumed as the `$AGT_PANE` env
    /// var a script feeds back through `session type --pane` (re-validated CLI- AND server-side — the enum
    /// pins the token this emits, not the shell round-trip).
    public var pane: Pane
    public var selection: String
    public var socket: String

    public init(sessionID: String = "", sessionName: String = "", sessionPWD: String = "",
                workspaceID: String = "", workspaceName: String = "", windowID: String = "",
                windowName: String = "", pane: Pane = .left, selection: String = "", socket: String = "") {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.sessionPWD = sessionPWD
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.windowID = windowID
        self.windowName = windowName
        self.pane = pane
        self.selection = selection
        self.socket = socket
    }

    /// The single source of truth mapping each `AGT_X` token name to its resolved value in this
    /// context. Both `expand` and `environment` iterate it, so the token set and the env-var set
    /// stay symmetric. Order is irrelevant (both consumers key by name).
    var tokens: [(name: String, value: String)] {
        [("AGT_SESSION_ID", sessionID),
         ("AGT_SESSION_NAME", sessionName),
         ("AGT_SESSION_PWD", sessionPWD),
         ("AGT_WORKSPACE_ID", workspaceID),
         ("AGT_WORKSPACE_NAME", workspaceName),
         ("AGT_WINDOW_ID", windowID),
         ("AGT_WINDOW_NAME", windowName),
         ("AGT_PANE", pane.rawValue),
         ("AGT_SELECTION", selection),
         ("AGT_SOCKET", socket)]
    }

    /// The `AGT_X` token names available in a command body, in declaration order. Derived from the
    /// same `tokens` table that `expand`/`environment` use, so the Settings token reference (the UI
    /// that lists them) can't drift from the expansion set.
    public static var tokenNames: [String] {
        CommandContext().tokens.map(\.name)
    }

    /// Substitutes each `{AGT_X}` occurrence in `template` with its resolved value from this context.
    /// A token whose value is empty becomes an empty string; an unknown `{...}` is left untouched.
    ///
    /// Single-pass: the input is scanned once and each `{...}` is replaced from the token table, so a
    /// replaced value that itself contains a `{AGT_X}` literal (e.g. a selection that reads
    /// `{AGT_SOCKET}`) is NOT re-substituted.
    public func expand(_ template: String) -> String {
        let table = Dictionary(uniqueKeysWithValues: tokens.map { ($0.name, $0.value) })
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[rest.startIndex..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                // no closing brace — copy the rest verbatim and stop.
                result += rest[open...]
                return result
            }
            let name = String(rest[afterOpen..<close])
            if let value = table[name] {
                result += value
            } else {
                // not a known token — keep the `{...}` literal untouched.
                result += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    /// The `AGT_X` → value dictionary for this context, exported as environment on the spawned
    /// process. Keys mirror exactly the tokens `expand` substitutes.
    public func environment() -> [String: String] {
        Dictionary(uniqueKeysWithValues: tokens.map { ($0.name, $0.value) })
    }
}
