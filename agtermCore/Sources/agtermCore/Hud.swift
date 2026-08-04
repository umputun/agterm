/// The message a control client posts over a session while it prepares something. `position` and `spinner`
/// take their defaults when the caller omits them, so a decoded spec always carries an effective value the
/// read-back can report.
public struct HudSpec: Codable, Equatable, Sendable {
    public let message: String
    public let detail: String?
    public let spinner: Bool
    /// `#rrggbb` background for the panel's surface; nil keeps the session's terminal background.
    public let backgroundColor: String?
    /// Caller override for the panel's share of the pane; nil lets `HudLayout` size it from the message.
    public let sizePercent: Int?
    public let position: HudPosition

    /// Cap on `message` and `detail` each, enforced by the dispatcher. The panel wraps at
    /// `HudLayout.maxColumns` and is clamped to `HudLayout.maxSizePercent`, so longer text cannot be shown.
    public static let maxTextLength = 256

    public init(message: String, detail: String? = nil, spinner: Bool = false, backgroundColor: String? = nil,
                sizePercent: Int? = nil, position: HudPosition = .defaultPosition) {
        self.message = message
        self.detail = detail
        self.spinner = spinner
        self.backgroundColor = backgroundColor
        self.sizePercent = sizePercent
        self.position = position
    }

    enum CodingKeys: String, CodingKey {
        case message, detail, spinner, backgroundColor, sizePercent, position
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(String.self, forKey: .message)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        spinner = try c.decodeIfPresent(Bool.self, forKey: .spinner) ?? false
        backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor)
        sizePercent = try c.decodeIfPresent(Int.self, forKey: .sizePercent)
        position = try c.decodeIfPresent(HudPosition.self, forKey: .position) ?? .defaultPosition
    }
}

/// Where the panel sits vertically in the pane. `CaseIterable` so dispatcher validation and CLI help derive
/// from the cases rather than repeating them.
public enum HudPosition: String, Codable, CaseIterable, Sendable {
    case top, center, bottom

    /// The placement a caller who omits `--position` gets. The ONE spelling of that default: the memberwise
    /// initializer, the lenient decoder, and the dispatcher all read it, so changing it is one edit.
    public static let defaultPosition = HudPosition.center

    /// Percent of the pane height held clear at the edge for `.top`/`.bottom`; `.center` ignores it. The
    /// margin is held only while the panel is small enough to leave room — `OverlayPanelStyle.verticalOffset`
    /// centers instead of overhanging the pane, so a panel at or above `HudLayout.maxSizePercent` ignores
    /// `.top`/`.bottom` entirely.
    public static let edgeMarginPercent = 10

    /// The accepted names pipe-joined — the control server's rejection message, as `StatusShape` does.
    public static var validNamesList: String { validNames.joined(separator: "|") }

    /// The accepted names comma-joined — the prose form for `agtermctl --position` help.
    public static var validNamesPhrase: String { validNames.joined(separator: ", ") }

    private static var validNames: [String] { allCases.map(\.rawValue) }
}

/// Terminal cell and pane dimensions the app measures for the sizing math. Double-backed, so no
/// CoreGraphics type crosses the module boundary.
public struct PaneMetrics: Equatable, Sendable {
    public let cellWidth: Double
    public let cellHeight: Double
    public let paneWidth: Double
    public let paneHeight: Double

    public init(cellWidth: Double, cellHeight: Double, paneWidth: Double, paneHeight: Double) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paneWidth = paneWidth
        self.paneHeight = paneHeight
    }
}

/// Pure layout math for the HUD panel: message to a cell box, cell box to the pane percentage the overlay
/// slot understands, and the exact bytes the helper script reads. Host-free (`Int`/`Double` only) so
/// `swift test` covers it with no app host.
public enum HudLayout {
    /// Widest content line before wrapping; the frame padding sits outside it.
    public static let maxColumns = 60
    public static let maxSizePercent = 80
    public static let minSizePercent = 10

    /// The only HUD-SPECIFIC variable the app puts in the helper's environment (it also inherits the session
    /// environment and the overlay wrapper's own two): the path to the body file. Everything that an update
    /// may change — the box, the spinner, the owning pid — rides in that file's header line instead, since a
    /// running process cannot see its environment change and re-spawning would blink the panel.
    public static let fileEnvKey = "AGTERM_HUD_FILE"

    /// Frame padding in cells, applied on both sides of the content.
    static let horizontalPadding = 2
    static let verticalPadding = 1
    /// Cells the spinner glyph and its trailing space claim, so turning the spinner on cannot rewrap text.
    static let spinnerWidth = 2

    /// clampSizePercent bounds a CALLER'S `--size-percent` into the same range the measured path produces.
    /// The maximum is the invariant `OverlayHudError.fullResize` states for `--full`, one layer down: a HUD
    /// is a message ABOUT a session and must never cover it, and 100 would do exactly that. The read-back
    /// reports the clamped value, so a caller sees what the panel actually took.
    public static func clampSizePercent(_ requested: Int) -> Int {
        min(max(requested, minSizePercent), maxSizePercent)
    }

    /// box returns the cell box the panel needs for `spec`: the wrapped content plus the frame padding.
    ///
    /// Width is COUNTED IN CHARACTERS, not display columns, which the helper's own `${#line}` matches under
    /// the UTF-8 locale it forces. A double-width glyph (CJK, most emoji) therefore advances two columns
    /// against a box sized for one and overflows the frame — an accepted limitation, since correcting it
    /// needs an East-Asian-width table on both sides of the file.
    public static func box(for spec: HudSpec) -> (columns: Int, rows: Int) {
        let lines = bodyLines(for: spec)
        let widest = lines.map(\.count).max() ?? 0
        let content = max(widest + (spec.spinner ? spinnerWidth : 0), 1)
        return (columns: content + horizontalPadding * 2, rows: max(lines.count, 1) + verticalPadding * 2)
    }

    /// sizePercent returns the single percentage the overlay slot applies to BOTH pane dimensions, so it is
    /// the larger of the two needs, clamped into `minSizePercent...maxSizePercent`. A pane with no measured
    /// size resolves to `maxSizePercent`: nothing is known to fit, so the panel takes the most room allowed.
    public static func sizePercent(box: (columns: Int, rows: Int), pane: PaneMetrics) -> Int {
        let width = percent(Double(max(box.columns, 0)) * pane.cellWidth, of: pane.paneWidth)
        let height = percent(Double(max(box.rows, 0)) * pane.cellHeight, of: pane.paneHeight)
        return min(max(max(width, height), minSizePercent), maxSizePercent)
    }

    /// renderedBody returns the bytes written to `fileEnvKey`'s file: a `<columns> <rows> <spinner> <pid>`
    /// header line, then the wrapped message block, a single empty line, and the wrapped detail block.
    /// Content lines are never empty, so that one empty line is what tells the helper where the dimmed
    /// detail starts. The header is what lets an update change the box or the spinner without a re-spawn —
    /// the helper re-reads this file every tick and never consults its own environment for either.
    ///
    /// `ownerPid` is the pid of the process WRITING the file, and it is how a hard-killed app (crash,
    /// `kill -9`) stops its painter: that path runs no surface teardown, so the file survives and no SIGHUP
    /// reaches the helper, whose pty session leader is `login` rather than the app.
    public static func renderedBody(for spec: HudSpec, ownerPid: Int32) -> String {
        let box = box(for: spec)
        let header = "\(box.columns) \(box.rows) \(spec.spinner ? 1 : 0) \(ownerPid)\n"
        return header + bodyLines(for: spec).map { $0 + "\n" }.joined()
    }

    static func bodyLines(for spec: HudSpec) -> [String] {
        var lines = wrap(spec.message, columns: maxColumns)
        let detail = wrap(spec.detail ?? "", columns: maxColumns)
        guard !detail.isEmpty else { return lines }
        if !lines.isEmpty { lines.append("") }
        lines.append(contentsOf: detail)
        return lines
    }

    /// wrap breaks `text` into lines of at most `columns` characters, treating a newline as a hard break and
    /// splitting a word longer than the line. Blank lines are dropped, which is what keeps the single empty
    /// line in `renderedBody` unambiguous as the message/detail separator.
    static func wrap(_ text: String, columns: Int) -> [String] {
        let width = max(columns, 1)
        var lines: [String] = []
        for paragraph in text.split(separator: "\n") {
            var current = ""
            for chunk in paragraph.split(separator: " ") {
                var word = String(chunk)
                while word.count > width {
                    if !current.isEmpty { lines.append(current); current = "" }
                    lines.append(String(word.prefix(width)))
                    word = String(word.dropFirst(width))
                }
                if word.isEmpty { continue }
                if current.isEmpty {
                    current = word
                } else if current.count + 1 + word.count <= width {
                    current += " " + word
                } else {
                    lines.append(current)
                    current = word
                }
            }
            if !current.isEmpty { lines.append(current) }
        }
        return lines
    }

    private static func percent(_ size: Double, of available: Double) -> Int {
        guard available > 0 else { return maxSizePercent }
        return Int((size / available * 100).rounded(.up))
    }
}
