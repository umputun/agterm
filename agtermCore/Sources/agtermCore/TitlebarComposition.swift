/// The two title-bar lines, composed host-free so the whole matrix is unit-testable — the SwiftUI view
/// owns only layout and truncation. Follows `InterfaceElement.titlebarGroupDividers`, hoisted for the
/// same reason.
public struct TitlebarComposition: Sendable, Equatable {
    /// Line one. Empty when every part it can carry is hidden or absent.
    public let title: String
    /// Line two, empty outside `.normal` — the compact and hidden bars are one row or none.
    public let subtitle: String

    /// What the title bar has to work with, each already resolved by the caller: a part hidden by its
    /// `InterfaceElement` toggle arrives nil, which is why `compose` never sees the settings.
    public struct Parts: Sendable, Equatable {
        /// The active session's display name, or nil when hidden. The app passes "Agterm" for no session.
        public var sessionName: String?
        /// The window's USER-SET name; nil for an auto "window N" name as well as when hidden.
        public var windowName: String?
        /// `Session.context`; nil when unset or hidden.
        public var context: String?
        /// `Session.subtitleDetail` — the focused pane's terminal title or its cwd.
        public var detail: String

        public init(sessionName: String? = nil, windowName: String? = nil,
                    context: String? = nil, detail: String = "") {
            self.sessionName = sessionName
            self.windowName = windowName
            self.context = context
            self.detail = detail
        }
    }

    /// Joins the session and window names; the em dash predates the context and is unchanged.
    static let identitySeparator = " — "
    /// Sits between the identity and the context on a compact bar's single row.
    static let contextSeparator = " · "

    /// Lays the parts out for one toolbar mode.
    ///
    /// Compact puts the context AFTER the identity so the view's tail truncation eats the context first:
    /// `ToolbarMode` is independent of sidebar visibility, so a compact bar with the sidebar hidden is the
    /// only place the session name appears at all. Normal gives the context line two, REPLACING the cwd
    /// detail rather than sharing the row, which would truncate both. Hidden composes nothing — neither
    /// title bar renders a label in that mode.
    public static func compose(_ parts: Parts, mode: ToolbarMode) -> TitlebarComposition {
        let identity: String
        switch (parts.sessionName, parts.windowName) {
        case let (session?, window?): identity = session + identitySeparator + window
        case let (session?, nil): identity = session
        case let (nil, window?): identity = window
        case (nil, nil): identity = ""
        }
        switch mode {
        case .hidden:
            return TitlebarComposition(title: "", subtitle: "")
        case .compact:
            let segments = [identity, parts.context ?? ""].filter { !$0.isEmpty }
            return TitlebarComposition(title: segments.joined(separator: contextSeparator), subtitle: "")
        case .normal:
            return TitlebarComposition(title: identity, subtitle: parts.context ?? parts.detail)
        }
    }
}
