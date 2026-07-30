import Foundation

/// A user-defined command: a shell line run via `/bin/sh -c`, optionally bound to a keyboard shortcut
/// and always listed in the action palette. The body may carry `{AGT_X}` template tokens (see
/// `CommandContext`), expanded at fire time and also exported as `$AGT_X` environment variables on the
/// spawned process. An empty `shortcut` means palette-only (no keybind).
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

/// The already-resolved session context for a command fire: one field per `{AGT_X}` token. The app
/// target builds it from the active session at fire time; agtermCore only derives the token
/// substitutions (`expand`) and the environment dictionary (`environment`), both off the single `tokens`
/// table, so the `{AGT_X}` set and the `$AGT_X` set can never drift.
public struct CommandContext: Equatable, Sendable {
    /// Which pane a command fired from. The raw values are exactly the `--pane` argument strings, so
    /// `pane.rawValue` is always a valid `session.type`/`session.text --pane` value.
    public enum Pane: String, Equatable, Sendable {
        case left
        case right
        case scratch
    }

    public var sessionID: String
    public var sessionName: String
    public var sessionPWD: String
    public var workspaceID: String
    public var workspaceName: String
    public var windowID: String
    public var windowName: String
    /// The pane that had focus at fire time — `.left` (main), `.right` (split), or `.scratch` (the
    /// session's scratch terminal). `.left` for any single-pane session, including a promoted split
    /// survivor: when the primary pane exits, `closePrimaryPane` moves the surviving split pane into the
    /// main slot, so it reports `.left` and `session.type --pane left` reaches it. Typed, so `rawValue`
    /// can only be `left`/`right`/`scratch`; it is consumed as the `$AGT_PANE` env var a script feeds
    /// back through `session type --pane` (re-validated CLI- AND server-side — the enum pins the token
    /// emitted here, not the shell round-trip).
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

    /// The `AGT_X` token names available in a command body, in declaration order. Off the same `tokens`
    /// table `expand`/`environment` use, so the Settings token reference (the UI listing them) can't
    /// drift from the expansion set.
    public static var tokenNames: [String] {
        CommandContext().tokens.map(\.name)
    }

    /// The token base names whose value comes from an active session/workspace/selection. In a
    /// session-free context each expands EMPTY, which is dangerous — an empty `{AGT_SESSION_PWD}` turns
    /// `rm -rf …/*` into a root glob. `AGT_SOCKET`/`AGT_WINDOW`/`AGT_PANE` are excluded: they resolve
    /// with no session, which is what keeps a launcher command firable in an emptied window.
    public static let sessionScopedTokenBases = ["AGT_SESSION", "AGT_WORKSPACE", "AGT_SELECTION"]

    /// Whether `commandBody` references any session-scoped token (`{AGT_X}`, `$AGT_X` or `${AGT_X}` — a
    /// plain substring match, the base names being specific enough not to occur by accident). The
    /// empty-window keybind keeps such a command inert with no active session (like the palette's no-op)
    /// instead of firing it with silently-empty tokens.
    public static func referencesSessionScopedContext(_ commandBody: String) -> Bool {
        sessionScopedTokenBases.contains { commandBody.contains($0) }
    }

    /// Substitutes each `{AGT_X}` occurrence in `template` with its resolved value from this context; an
    /// empty value becomes an empty string, an unknown `{...}` is left untouched. Single-pass, so a
    /// replaced value that itself contains a `{AGT_X}` literal (e.g. a selection reading `{AGT_SOCKET}`)
    /// is NOT re-substituted.
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
