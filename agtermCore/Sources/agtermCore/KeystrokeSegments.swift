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

    /// The same keystrokes as typed text for `zmx type`: the runs as UTF-8 and one CR per Return. The
    /// daemon encodes each CR as a Return key for the keyboard mode its program asked for, which is what
    /// the surface's own key path does.
    public static func ptyBytes(_ text: String) -> [UInt8] {
        split(text).flatMap { segment -> [UInt8] in
            switch segment {
            case .text(let run): Array(run.utf8)
            case .returnKey: [0x0D]
            }
        }
    }
}
