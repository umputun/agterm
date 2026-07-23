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

/// The outcome of resolving the combined size + anchor for `session.overlay.open`: a concrete size (no
/// size arg → `.full`) and anchor (no `--anchor` → `.center`), or a validation failure carrying the
/// canonical error string.
public enum OverlayOpenResolution: Equatable, Sendable {
    case resolved(size: OverlaySize, anchor: OverlayAnchor)
    case invalid(String)
}

/// The outcome of resolving the combined size + anchor for `session.overlay.resize`: an optional size (nil
/// = keep the current size) and optional anchor (nil = keep the current anchor), or a validation failure
/// carrying the canonical error string.
public enum OverlayResizeResolution: Equatable, Sendable {
    case resolved(size: OverlaySize?, anchor: OverlayAnchor?)
    case invalid(String)
}

/// Host-free validation of the `session.overlay.open`/`.resize` size + anchor args, the SINGLE source of
/// the one-of / range / pairing rules and their error strings. Both the control dispatcher and the
/// `agtermctl` CLI resolve the args through `resolveOpen`/`resolveResize` and map an `.invalid` result to
/// their own error type (`ControlResponse` vs `ValidationError`), so the two surfaces cannot drift.
public enum OverlayArgs {
    /// Which overlay verb is validating: carries the error-message prefix and whether `--full` is a valid
    /// size mode (resize only).
    public enum Command: Sendable {
        case open, resize
        var name: String { self == .open ? "session.overlay.open" : "session.overlay.resize" }
        var allowsFull: Bool { self == .resize }
    }

    /// Resolves the `session.overlay.open` size + anchor: absence of any size arg means a full-pane overlay
    /// (open has no `--full`) and absence of `--anchor` means `.center`. An `--anchor` is only meaningful
    /// for a floating overlay, so an anchor over a full-pane open is rejected.
    public static func resolveOpen(sizePercent: Int?, cols: Int?, rows: Int?,
                                   anchor rawAnchor: String?) -> OverlayOpenResolution {
        let size: OverlaySize
        switch parseSize(sizePercent: sizePercent, cols: cols, rows: rows, full: false, command: .open) {
        case .invalid(let message): return .invalid(message)
        case .unspecified: size = .full
        case .size(let parsed): size = parsed
        }
        switch parseAnchor(rawAnchor) {
        case .invalid(let message): return .invalid(message)
        case .absent: return .resolved(size: size, anchor: .center)
        case .anchor(let parsed):
            guard size != .full else {
                return .invalid("--anchor requires a floating overlay: use --size-percent or --cols/--rows")
            }
            return .resolved(size: size, anchor: parsed)
        }
    }

    /// Resolves the `session.overlay.resize` size + anchor: a nil size keeps the current size and a nil
    /// anchor keeps the current anchor, so at least one of {a size mode, `--anchor`} must be set. `--full`
    /// reverts to the full-pane overlay and cannot carry an anchor.
    public static func resolveResize(sizePercent: Int?, cols: Int?, rows: Int?, full: Bool,
                                     anchor rawAnchor: String?) -> OverlayResizeResolution {
        let size: OverlaySize?
        switch parseSize(sizePercent: sizePercent, cols: cols, rows: rows, full: full, command: .resize) {
        case .invalid(let message): return .invalid(message)
        case .unspecified: size = nil
        case .size(let parsed): size = parsed
        }
        let anchor: OverlayAnchor?
        switch parseAnchor(rawAnchor) {
        case .invalid(let message): return .invalid(message)
        case .absent: anchor = nil
        case .anchor(let parsed): anchor = parsed
        }
        if case .some(.full) = size, anchor != nil {
            return .invalid("--full cannot be combined with --anchor")
        }
        if size == nil, anchor == nil {
            return .invalid("session.overlay.resize requires a size (--full, --size-percent, --cols/--rows) or --anchor")
        }
        return .resolved(size: size, anchor: anchor)
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
                return .invalid("\(command.name): provide both --cols and --rows")
            }
            guard cols >= 1, rows >= 1 else {
                return .invalid("\(command.name): --cols and --rows must be >= 1")
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
