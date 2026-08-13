import Foundation

/// One `dashboard` target: a resolvable head plus an optional pane selector. `pane` nil is the bare form,
/// which expands to every pane of the session; `.primary`/`.split` select that one cell. Parsing is
/// host-free so `ControlDispatcher` validates and `ControlServer` resolves against ONE grammar.
public struct DashboardTarget: Equatable, Sendable {
    /// The part `ControlResolve.resolve` matches: `active`, a full UUID, or a unique prefix.
    public let head: String

    /// The selected pane, or nil for the bare form. Never `.scratch`/`.overlay` — `DashboardMember`
    /// excludes those as cells.
    public let pane: TerminalZoomSurface?

    init(head: String, pane: TerminalZoomSurface?) {
        self.head = head
        self.pane = pane
    }

    /// Parse a raw `dashboard` target, returning nil when the pane suffix is malformed.
    ///
    /// Splitting on the FIRST colon is safe because a valid head never contains one — `ControlResolve`
    /// accepts only `active`, a full UUID, or a UUID prefix. So `surface:<uuid>:left` (the `surface.zoom`
    /// form) fails here instead of half-resolving to a head of `surface`.
    ///
    /// Positional and role aliases are accepted case-insensitively. Read-back remains `left`/`right`, so
    /// adding aliases does not change the wire representation existing callers consume.
    public init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":") else {
            guard !rawValue.isEmpty else { return nil }
            self.init(head: rawValue, pane: nil)
            return
        }
        let head = String(rawValue[rawValue.startIndex..<colon])
        let suffix = String(rawValue[rawValue.index(after: colon)...]).lowercased()
        guard !head.isEmpty else { return nil }
        switch suffix {
        case "left", "top", "primary": self.init(head: head, pane: .primary)
        case "right", "bottom", "split": self.init(head: head, pane: .split)
        default: return nil
        }
    }
}

/// A `DashboardTarget` whose head has been resolved to a session. `pane` keeps the same meaning: nil is
/// the bare form taking every pane, an explicit value takes that cell alone.
public struct ResolvedDashboardTarget: Equatable, Sendable {
    public let session: UUID
    public let pane: TerminalZoomSurface?

    public init(session: UUID, pane: TerminalZoomSurface?) {
        self.session = session
        self.pane = pane
    }
}
