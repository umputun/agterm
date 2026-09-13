/// The two title-bar lines, composed host-free so the whole matrix is unit-testable — the SwiftUI view
/// owns only layout and truncation. Follows `InterfaceElement.titlebarGroupDividers`, hoisted for the
/// same reason.
public struct TitlebarComposition: Sendable, Equatable {
    /// Line one's workspace, session and window identity.
    public let title: String
    /// The SSH target following the identity, styled and truncated separately by the view.
    public var host: String?
    /// Compact context, including its separator when another line-one part precedes it.
    public var tail: String = ""
    /// Line two, empty outside `.normal` — the compact and hidden bars are one row or none.
    public let subtitle: String

    /// What the title bar has to work with, each already resolved by the caller: a part hidden by its
    /// `InterfaceElement` toggle arrives nil, which is why `compose` never sees the settings.
    public struct Parts: Sendable, Equatable {
        /// The name of the workspace holding the active session; nil when hidden (the default) or when
        /// no session is selected. `compose` caps it at `workspaceNameLimit` characters and drops a blank one.
        public var workspaceName: String?
        /// The active session's display name, or nil when hidden. The app passes "Agterm" for no session.
        public var sessionName: String?
        /// The window's USER-SET name; nil for an auto "window N" name as well as when hidden.
        public var windowName: String?
        /// `Session.context`; nil when unset or hidden.
        public var context: String?
        /// `Session.subtitleDetail` — the focused pane's terminal title or its cwd.
        public var detail: String
        public var remoteHost: String?

        public init(workspaceName: String? = nil, sessionName: String? = nil, windowName: String? = nil,
                    context: String? = nil, detail: String = "", remoteHost: String? = nil) {
            self.workspaceName = workspaceName
            self.sessionName = sessionName
            self.windowName = windowName
            self.context = context
            self.detail = detail
            self.remoteHost = remoteHost
        }
    }

    /// Joins the workspace, session and window names; the em dash predates the context and is unchanged.
    static let identitySeparator = " — "
    /// Characters of the workspace name kept before an ellipsis. The identity is one tail-truncated text,
    /// so an uncapped prefix would push the session name off the bar with the sidebar hidden.
    static let workspaceNameLimit = 24
    /// Sits between the identity and the context on a compact bar's single row.
    static let contextSeparator = " · "

    /// Lays the parts out for one toolbar mode.
    ///
    /// Compact puts the context LAST, after the identity and the host, so the view's lower layout priority
    /// on `tail` drops the context first: `ToolbarMode` is independent of sidebar visibility, so a compact
    /// bar with the sidebar hidden is the only place the session name appears at all. Normal gives the
    /// context line two, REPLACING the cwd detail rather than sharing the row, which would truncate both.
    /// Hidden composes nothing — neither title bar renders a label in that mode.
    public static func compose(_ parts: Parts, mode: ToolbarMode) -> TitlebarComposition {
        let identity = [parts.workspaceName.flatMap(cappedWorkspaceName), parts.sessionName, parts.windowName]
            .compactMap { $0 }
            .joined(separator: identitySeparator)
        switch mode {
        case .hidden:
            return TitlebarComposition(title: "", subtitle: "")
        case .compact:
            let context = parts.context ?? ""
            let separator = !identity.isEmpty || parts.remoteHost != nil ? contextSeparator : ""
            return TitlebarComposition(title: identity, host: parts.remoteHost,
                                      tail: context.isEmpty ? "" : separator + context, subtitle: "")
        case .normal:
            return TitlebarComposition(title: identity, host: parts.remoteHost, subtitle: parts.context ?? parts.detail)
        }
    }

    /// Nil for a blank name: `renameWorkspace` rejects one, but a snapshot rebuild does not.
    static func cappedWorkspaceName(_ name: String) -> String? {
        guard let trimmed = name.trimmedOrNil else { return nil }
        guard trimmed.count > workspaceNameLimit else { return trimmed }
        return trimmed.prefix(workspaceNameLimit) + "…"
    }
}
