/// ControlTextSearchNode is a text page's query with the page's last count of matches and the current one, 0 for none.
public struct ControlTextSearchNode: Codable, Sendable, Equatable {
    public let query: String
    public let matches: Int
    public let current: Int

    public init(query: String, matches: Int, current: Int) {
        self.query = query
        self.matches = matches
        self.current = current
    }
}

/// ControlTextChangesNode is a diff page's count of changes and the one it last stepped to, 0 before any step.
public struct ControlTextChangesNode: Codable, Sendable, Equatable {
    public let count: Int
    public let current: Int

    public init(count: Int, current: Int) {
        self.count = count
        self.current = current
    }
}

/// ControlTextFilesNode is a diff page's count of files and the one in view, from 1, with its path as the page shows it.
public struct ControlTextFilesNode: Codable, Sendable, Equatable {
    public let count: Int
    public let current: Int
    public let path: String

    public init(count: Int, current: Int, path: String) {
        self.count = count
        self.current = current
        self.path = path
    }
}

/// ControlTextOverlayNode is a text page's source: the file, the highlight.js language its name maps to
/// (omitted when unmapped, and still reported for a file too large to highlight), and the line it was
/// opened at, not the line in view.
public struct ControlTextOverlayNode: Codable, Sendable, Equatable {
    public let file: String
    public let language: String?
    public let line: Int?
    /// tail is a log page's line limit; the other log fields are its live state, all omitted on a plain text page.
    public let tail: Int?
    public let following: Bool?
    public let lines: Int?
    public let clipped: Bool?
    public let waiting: Bool?
    public let unreadable: Bool?
    /// search is the page's search, omitted with no query.
    public let search: ControlTextSearchNode?
    /// changes is a diff page's change count and current change, omitted until the page reports and on other pages.
    public let changes: ControlTextChangesNode?
    /// files is a diff page's file count and the file in view, omitted until the page reports and on other pages.
    public let files: ControlTextFilesNode?
    /// wrap is true while the page wraps long lines, omitted while it does not.
    public let wrap: Bool?

    public init(file: String, language: String?, line: Int?, tail: Int? = nil, following: Bool? = nil, lines: Int? = nil,
                clipped: Bool? = nil, waiting: Bool? = nil, unreadable: Bool? = nil, search: ControlTextSearchNode? = nil,
                changes: ControlTextChangesNode? = nil, files: ControlTextFilesNode? = nil, wrap: Bool? = nil) {
        self.search = search
        self.wrap = wrap
        self.changes = changes
        self.files = files
        self.file = file
        self.language = language
        self.line = line
        self.tail = tail
        self.following = following
        self.lines = lines
        self.clipped = clipped
        self.waiting = waiting
        self.unreadable = unreadable
    }
}
