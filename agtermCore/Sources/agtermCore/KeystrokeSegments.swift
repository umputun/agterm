/// A host-free description of the synthetic keystrokes used by `session.type`.
public enum KeystrokeSegment: Equatable, Sendable {
    case text(String)
    case returnKey
}

/// `PacedKeystrokes` is a typed payload split around its final Return: `head` is sent at once,
/// and when `pacedReturn` is set one more Return follows after `KeystrokeSegments.submitGap`.
public struct PacedKeystrokes: Equatable, Sendable {
    public let head: [KeystrokeSegment]
    public let pacedReturn: Bool

    public init(head: [KeystrokeSegment], pacedReturn: Bool) {
        self.head = head
        self.pacedReturn = pacedReturn
    }
}

/// Splits injected text into printable runs and Return keypresses.
public enum KeystrokeSegments {
    /// `submitGap` is the seconds between a payload's text and its final Return: Claude Code takes a
    /// Return that arrives in the same burst as a long text run as pasted content and does not submit (#679).
    public static let submitGap = 0.01

    /// `paced` holds back the final Return of a payload that ends in a line ending and has text before it;
    /// earlier Returns stay in `head`, and a payload of Returns alone is not paced.
    public static func paced(_ text: String) -> PacedKeystrokes {
        let segments = split(text)
        let hasText = segments.contains { if case .text = $0 { true } else { false } }
        guard segments.last == .returnKey, hasText else { return PacedKeystrokes(head: segments, pacedReturn: false) }
        return PacedKeystrokes(head: Array(segments.dropLast()), pacedReturn: true)
    }

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
        ptyBytes(split(text))
    }

    public static func ptyBytes(_ segments: [KeystrokeSegment]) -> [UInt8] {
        segments.flatMap { segment -> [UInt8] in
            switch segment {
            case .text(let run): Array(run.utf8)
            case .returnKey: [0x0D]
            }
        }
    }
}
