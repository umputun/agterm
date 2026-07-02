/// A host-free description of the synthetic keystrokes used by `session.type`.
public enum KeystrokeSegment: Equatable, Sendable {
    case text(String)
    case returnKey
}

/// Splits injected text into printable runs and Return keypresses.
public enum KeystrokeSegments {
    /// Normalizes CRLF and CR line endings to LF, then emits every line ending as exactly one Return.
    public static func split(_ text: String) -> [KeystrokeSegment] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.components(separatedBy: "\n")
        var segments: [KeystrokeSegment] = []
        segments.reserveCapacity(parts.count * 2)

        for (index, part) in parts.enumerated() {
            if !part.isEmpty {
                segments.append(.text(part))
            }
            if index < parts.count - 1 {
                segments.append(.returnKey)
            }
        }
        return segments
    }
}
