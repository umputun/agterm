import Foundation

/// LinkHover is the text a pane shows for the link under a ⌘-held pointer. The link is terminal output drawn in
/// app chrome, and the label exists to show where a link really goes, so format characters that could reorder
/// or hide part of it are replaced before display.
public enum LinkHover {
    static let maxLength = 120

    /// label names the hovered link's target: the session a resolving `agterm://session/` link selects, else the
    /// link itself, on one line and cut in the middle past `maxLength`.
    public static func label(for url: String, sessionName: (UUID) -> String?) -> String {
        if let id = LinkPolicy.sessionLink(url), let name = sessionName(id) {
            return truncated("Session: " + neutralized(name))
        }
        return truncated(neutralized(url))
    }

    static func neutralized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { isUnsafe($0) ? "\u{FFFD}" : $0 }))
    }

    static func truncated(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let half = (maxLength - 1) / 2
        return text.prefix(half) + "…" + text.suffix(maxLength - 1 - half)
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}
