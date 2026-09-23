import Foundation

/// The outcome of checking a `session.context` value, carrying the message the control response reports
/// on rejection so the caller learns which rule it broke.
enum SessionContextValidation: Sendable, Equatable {
    case valid(String)
    case invalid(String)
}

extension Session {
    /// Largest accepted `context`, in UTF-8 BYTES. It bounds the snapshot and the JSON read-back, not the
    /// rendered width — the title bar truncates for pixels on its own. A character count is not a byte
    /// bound, so anything non-ASCII would slip past one.
    nonisolated static let contextByteLimit = 256

    /// Checks a `session.context` value, trimming outer spaces and returning the trimmed string. Rejects an
    /// empty result, one over `contextByteLimit`, and any control character or line/paragraph separator.
    /// A blank set is a rejection rather than a clear: `--clear` is the only clearing form, so there is no
    /// second undocumented path to nil.
    ///
    /// The scan reads `raw`, NOT `trimmed`: trimming first would silently repair `"PR #517\n"` into a valid
    /// value, which both accepts input the contract rejects and lets the snapshot decoder rewrite a
    /// hand-edited value instead of dropping it.
    ///
    /// `nonisolated` so `SessionSnapshot`'s decoder can drop an invalid stored value; it only reads a String.
    nonisolated static func validateContext(_ raw: String) -> SessionContextValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .invalid("context must not be empty (use --clear to remove it)") }
        if trimmed.utf8.count > contextByteLimit {
            return .invalid("context must be at most \(contextByteLimit) UTF-8 bytes")
        }
        if raw.unicodeScalars.contains(where: breaksContextLine) {
            return .invalid("context must not contain control characters or line breaks")
        }
        return .valid(trimmed)
    }

    /// Whether a scalar would break the single-line title-bar label. `lineSeparator` and
    /// `paragraphSeparator` (U+2028/U+2029) are NOT control characters, so a `Cc`-only check misses both.
    private nonisolated static func breaksContextLine(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}
