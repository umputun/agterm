import Foundation

/// The outcome of validating the overlay SIZE args (`--size-percent` / `--cols` / `--rows`, and `--full`
/// on resize): a resolved size mode, no size arg present (open → full, resize → keep current), or a
/// validation failure carrying the canonical error string.
public enum OverlaySizeParse: Equatable, Sendable {
    case size(OverlaySize)
    case unspecified
    case invalid(String)
}

/// The outcome of parsing the `--anchor` selector: the parsed anchor, no `--anchor` present, or a
/// validation failure carrying the canonical error string.
public enum OverlayAnchorParse: Equatable, Sendable {
    case anchor(OverlayAnchor)
    case absent
    case invalid(String)
}

/// Host-free validation of the `session.overlay.open`/`.resize` size + anchor args, the SINGLE source of
/// the one-of / range / pairing rules and their error strings. Both the control dispatcher and the
/// `agtermctl` CLI call these and map the result to their own error type (`ControlResponse` vs
/// `ValidationError`), so the two surfaces cannot drift.
public enum OverlayArgs {
    /// Which overlay verb is validating: carries the error-message prefix and whether `--full` is a valid
    /// size mode (resize only). Folding the correlated command-name/allow-full pair keeps `parseSize` within
    /// the parameter-count limit.
    public enum Command: Sendable {
        case open, resize
        var name: String { self == .open ? "session.overlay.open" : "session.overlay.resize" }
        var allowsFull: Bool { self == .resize }
    }

    /// Validates the size args and resolves the `OverlaySize`. At most one size mode may be set; a percent
    /// is a hard `1...100` error (Decision 3); `cols`/`rows` are both-or-neither and each `>= 1`. `command`
    /// prefixes the per-command errors and gates the resize-only `--full` mode (open has no `--full`, so a
    /// stray `full` is ignored there).
    public static func parseSize(sizePercent: Int?, cols: Int?, rows: Int?, full: Bool,
                                 command: Command) -> OverlaySizeParse {
        let fullMode = command.allowsFull && full
        let hasCells = cols != nil || rows != nil
        let modeCount = (fullMode ? 1 : 0) + (sizePercent != nil ? 1 : 0) + (hasCells ? 1 : 0)
        if modeCount > 1 {
            let modes = command.allowsFull ? "--full, --size-percent, or --cols/--rows" : "--size-percent or --cols/--rows"
            return .invalid("\(command.name): use only one of \(modes)")
        }
        if fullMode { return .size(.full) }
        if let sizePercent {
            guard (1...100).contains(sizePercent) else {
                return .invalid("\(command.name): --size-percent must be 1...100")
            }
            return .size(.percent(sizePercent))
        }
        if hasCells {
            guard let cols, let rows else {
                return .invalid("provide both --cols and --rows")
            }
            guard cols >= 1, rows >= 1 else {
                return .invalid("--cols and --rows must be >= 1")
            }
            return .size(.cells(cols: cols, rows: rows))
        }
        return .unspecified
    }

    /// Parses `--anchor` to an `OverlayAnchor`: `.absent` when omitted, `.anchor` when valid, or `.invalid`
    /// with the `unknown anchor` message listing the nine positions.
    public static func parseAnchor(_ raw: String?) -> OverlayAnchorParse {
        guard let raw else { return .absent }
        guard let parsed = OverlayAnchor(rawValue: raw) else {
            let valid = OverlayAnchor.allCases.map(\.rawValue).joined(separator: "|")
            return .invalid("unknown anchor: \(raw) (\(valid))")
        }
        return .anchor(parsed)
    }
}
