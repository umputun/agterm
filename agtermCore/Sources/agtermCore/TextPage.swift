import Foundation

/// TextPage is the page a text overlay shows: a source, config, log or other text file named by untrusted
/// output, shown read-only. The text travels as escaped, inert data and the page loads nothing.
public enum TextPage {
    /// maxBytes bounds the file a page reads.
    public static let maxBytes = 4 << 20
    /// maxHighlightBytes bounds the text the page highlights; a larger file renders plain. Highlighting
    /// measured about 0.23 s over plain at 256 KB in WebKit, and 1.2 s at 1 MB.
    public static let maxHighlightBytes = 256 << 10
    /// defaultTail is how many lines a log page keeps when the request names none; maxTail bounds a request.
    public static let defaultTail = 5_000
    public static let maxTail = 100_000
    /// maxTailBytes bounds what a log page reads from the file's end, so one huge line cannot pull in the file.
    public static let maxTailBytes = 2 << 20
    private static let logExtensions: Set<String> = ["log", "out"]
    private static let diffLanguage = "diff"

    private static let languages: [String: String] = [
        "swift": "swift", "go": "go", "py": "python", "rb": "ruby", "rs": "rust",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "ts": "typescript",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "m": "objectivec", "mm": "objectivec",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "cs": "csharp", "php": "php", "pl": "perl", "pm": "perl",
        "lua": "lua", "r": "r", "sql": "sql", "css": "css", "scss": "scss", "less": "less", "graphql": "graphql",
        "sh": "bash", "bash": "bash", "zsh": "bash", "json": "json", "yaml": "yaml", "yml": "yaml",
        "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini", "xml": "xml", "plist": "xml",
        "diff": diffLanguage, "patch": diffLanguage, "mk": "makefile", "vb": "vbnet",
    ]
    private static let plainExtensions: Set<String> = ["txt", "text", "log", "out", "csv", "tsv", "env", "lock"]
    private static let basenameLanguages: [String: String] = [
        "Makefile": "makefile", "GNUmakefile": "makefile",
        ".bashrc": "bash", ".zshrc": "bash", ".profile": "bash", ".bash_profile": "bash", ".zprofile": "bash",
        ".gitconfig": "ini", ".editorconfig": "ini",
    ]
    private static let plainBasenames: Set<String> = ["Dockerfile", "LICENSE", "README", "CHANGELOG", "Procfile", ".gitignore", ".env"]

    /// language is the bundled highlight.js language for `path`, by lowercased extension and then by exact
    /// file name; nil means the file shows as plain text, or is not a text page at all.
    public static func language(forFile path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return languages[(name as NSString).pathExtension.lowercased()] ?? basenameLanguages[name]
    }

    /// isEligible says whether a clicked `path` opens as a text page. Markdown, HTML and SVG are not text
    /// pages: the first two have their own pages, and SVG is a document an author may expect rendered.
    public static func isEligible(file path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return language(forFile: path) != nil || plainExtensions.contains((name as NSString).pathExtension.lowercased())
            || plainBasenames.contains(name)
    }

    /// isDiff says whether `path` names a patch, whose plain page steps between its changes.
    public static func isDiff(file path: String) -> Bool {
        language(forFile: path) == diffLanguage
    }

    /// diffLanguages maps each path a patch's `--- ` or `+++ ` row names, as the row spells it up to a tab, to the
    /// file's language. A changed row can look like a header, so the renderer looks up only rows outside hunks.
    static func diffLanguages(in text: String) -> [String: String] {
        var found: [String: String] = [:]
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let row = TerminalText.strippingEscapes(String(raw))
            guard row.hasPrefix("--- ") || row.hasPrefix("+++ ") else { continue }
            let path = String(row.dropFirst(4).prefix { $0 != "\t" })
            let file = path.count > 1 && path.hasPrefix("\"") && path.hasSuffix("\"") ? String(path.dropFirst().dropLast()) : path
            if let language = language(forFile: file) { found[path] = language }
        }
        return found
    }

    /// diffSections lists a patch's files in patch order, each at the line its header starts on. A section opens at a
    /// `diff ` row, or at a `--- ` row directly followed by `+++ ` outside a `diff ` header, so rename, mode and binary
    /// sections count. Rows inside a hunk are never headers. A CR ends a line too, as the HTML parser makes it one.
    static func diffSections(in text: String) -> [DiffSection] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let rows = lines.components(separatedBy: "\n").map(TerminalText.strippingEscapes)
        var sections: [DiffSection] = []
        // the `diff --git` section still waiting for its `---` row, and whether its paths carry `a/` and `b/`
        var open: (index: Int, prefixed: Bool)?
        var old = 0, added = 0
        var index = 0
        while index < rows.count {
            let row = rows[index]
            defer { index += 1 }
            if old > 0 || added > 0 {
                if row.hasPrefix("\\") { continue }
                if !row.hasPrefix("+") { old -= 1 }
                if !row.hasPrefix("-") { added -= 1 }
                if old <= 0, added <= 0 { old = 0; added = 0 }
                continue
            }
            if row.hasPrefix("diff --git ") {
                let (from, to) = gitPaths(String(row.dropFirst(11)))
                let prefixed = from.hasPrefix("a/") && to.hasPrefix("b/")
                sections.append(DiffSection(path: prefixed ? String(to.dropFirst(2)) : to, line: index))
                open = (sections.count - 1, prefixed)
                continue
            }
            if row.hasPrefix("diff ") {
                open = nil
                continue
            }
            if row.hasPrefix("--- "), index + 1 < rows.count, rows[index + 1].hasPrefix("+++ ") {
                let from = headerPath(row), to = headerPath(rows[index + 1])
                var path = to == "/dev/null" ? from : to
                if let section = open {
                    if section.prefixed, path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
                    sections[section.index] = DiffSection(path: path, line: sections[section.index].line)
                } else {
                    sections.append(DiffSection(path: path, line: index))
                }
                open = nil
                index += 1
                continue
            }
            if let counts = hunkCounts(row) { (old, added) = counts }
        }
        return sections
    }

    /// hunkCounts reads a hunk header's old and new line counts, each 1 when the header leaves it out.
    private static func hunkCounts(_ row: String) -> (Int, Int)? {
        guard let match = row.firstMatch(of: /^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/) else { return nil }
        return (match.1.flatMap { Int($0) } ?? 1, match.2.flatMap { Int($0) } ?? 1)
    }

    /// headerPath is a `---` or `+++` row's path, unquoted, without the timestamp a plain `diff -u` adds after a tab.
    private static func headerPath(_ row: String) -> String {
        let path = String(row.dropFirst(4).prefix { $0 != "\t" })
        return path.hasPrefix("\"") ? unquoted(path).value : path
    }

    /// gitPaths splits a `diff --git` row's two paths, each quoted or not on its own. Unquoted paths may hold spaces, so
    /// an even split of two equal halves wins, then the last ` b/`, then the first space.
    private static func gitPaths(_ rest: String) -> (String, String) {
        if rest.hasPrefix("\"") {
            let first = unquoted(rest)
            let tail = rest[first.end...].drop { $0 == " " }
            return (first.value, tail.hasPrefix("\"") ? unquoted(String(tail)).value : String(tail))
        }
        if let quote = rest.range(of: " \"", options: .backwards) {
            return (String(rest[..<quote.lowerBound]), unquoted(String(rest[rest.index(after: quote.lowerBound)...])).value)
        }
        let chars = Array(rest)
        if chars.count % 2 == 1, chars[chars.count / 2] == " ",
           chars[..<(chars.count / 2)] == chars[(chars.count / 2 + 1)...] {
            let half = String(chars[..<(chars.count / 2)])
            return (half, half)
        }
        if rest.hasPrefix("a/"), let split = rest.range(of: " b/", options: .backwards) {
            return (String(rest[..<split.lowerBound]), String(rest[rest.index(after: split.lowerBound)...]))
        }
        guard let space = rest.firstIndex(of: " ") else { return (rest, rest) }
        return (String(rest[..<space]), String(rest[rest.index(after: space)...]))
    }

    /// unquoted decodes the C-style quoted path git writes for unusual names, whose octal escapes are UTF-8 bytes,
    /// and returns where the closing quote ends.
    private static func unquoted(_ quoted: String) -> (value: String, end: String.Index) {
        var bytes: [UInt8] = []
        var index = quoted.index(after: quoted.startIndex)
        while index < quoted.endIndex {
            let char = quoted[index]
            index = quoted.index(after: index)
            if char == "\"" { return (String(decoding: bytes, as: UTF8.self), index) }
            guard char == "\\", index < quoted.endIndex else {
                bytes.append(contentsOf: Array(String(char).utf8))
                continue
            }
            let escaped = quoted[index]
            index = quoted.index(after: index)
            let octal = String(escaped) + quoted[index...].prefix(2)
            if octal.count == 3, octal.allSatisfy({ ("0"..."7").contains($0) }), let byte = UInt8(octal, radix: 8) {
                bytes.append(byte)
                index = quoted.index(index, offsetBy: 2)
                continue
            }
            let named: [Character: UInt8] = ["n": 0x0A, "t": 0x09, "r": 0x0D, "a": 0x07, "b": 0x08, "f": 0x0C, "v": 0x0B]
            bytes.append(contentsOf: named[escaped].map { [$0] } ?? Array(String(escaped).utf8))
        }
        return (String(decoding: bytes, as: UTF8.self), quoted.endIndex)
    }

    /// isLog says whether a plain click on `path` opens it as a log page, following its end.
    public static func isLog(file path: String) -> Bool {
        logExtensions.contains(((path as NSString).lastPathComponent as NSString).pathExtension.lowercased())
    }

    /// validate returns the file's text, nil when it is not valid UTF-8 or holds a NUL, which marks a binary.
    public static func validate(_ data: Data) -> String? {
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// SearchState is the search a built page starts with: the model's query and revision, and the match it showed
    /// last, from 1 and 0 for none.
    public struct SearchState: Equatable, Sendable {
        public let query: String
        public let revision: Int
        public let current: Int

        public init(query: String, revision: Int, current: Int) {
            self.query = query
            self.revision = revision
            self.current = current
        }
    }

    /// html is the document the renderer fills: the text as the content of a hidden element, the language
    /// and target line as attributes, and `style`, the app's own stylesheet. The language is dropped over
    /// `maxHighlightBytes`, so the renderer shows that text plain. The policy loads nothing at all. The holder
    /// is a `div`: the parser drops a newline right after `<pre>`, which would shift every line number.
    /// A log page (`log` set) carries its follow state instead of a line, and the renderer draws no gutter; `anchor`
    /// is the scroll offset a rebuilt page reopens at, a paused log page's or a plain page's.
    /// A plain page of a diff is marked whatever its size, so change navigation outlives the highlighting limit;
    /// `change` is the change a rebuilt page reopens on, from 1, still the step's origin when `entered`, and `file` the
    /// file it keeps shown, from 1. Under the limit a diff also carries `diffLanguages` as JSON, so each file's lines
    /// are highlighted in that file's language. `wrap` opens the page with long lines wrapped.
    public static func html(text: String, language: String?, line: Int?, style: String, log: TextLogState? = nil,
                            anchor: Double? = nil, search: SearchState? = nil, change: Int? = nil,
                            entered: Bool = false, file: Int? = nil, wrap: Bool = false) -> String {
        var attributes = ""
        let highlighted = text.utf8.count <= maxHighlightBytes
        if log == nil, language == diffLanguage {
            attributes += " data-diff"
            if let change, change > 0 { attributes += " data-change=\"\(change)\"" }
            if entered { attributes += " data-entered" }
            if let file, file > 0 { attributes += " data-file=\"\(file)\"" }
            let files = highlighted ? diffLanguages(in: text) : [:]
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if !files.isEmpty, let json = try? encoder.encode(files) {
                attributes += " data-files=\"\(MarkdownPage.escaped(String(decoding: json, as: UTF8.self)))\""
            }
            let sections = diffSections(in: text)
            if !sections.isEmpty, let json = try? encoder.encode(sections) {
                attributes += " data-sections=\"\(MarkdownPage.escaped(String(decoding: json, as: UTF8.self)))\""
            }
        }
        if let search {
            attributes += " data-revision=\"\(search.revision)\""
            if !search.query.isEmpty {
                attributes += " data-query=\"\(MarkdownPage.escaped(search.query))\" data-current=\"\(search.current)\""
            }
        }
        if let language, highlighted {
            attributes += " data-language=\"\(MarkdownPage.escaped(language))\""
        }
        if let log {
            attributes += " data-log data-following=\"\(log.following)\""
            if log.report.clipped { attributes += " data-clipped" }
            if log.report.waiting { attributes += " data-waiting" }
            if log.report.unreadable { attributes += " data-unreadable" }
        } else if let line {
            attributes += " data-line=\"\(line)\""
        }
        if let anchor, anchor.isFinite { attributes += " data-anchor=\"\(anchor)\"" }
        if wrap { attributes += " data-wrap" }
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">\
        <style>\(style)</style></head><body>\
        <div id="agterm-text" hidden\(attributes)>\(MarkdownPage.escaped(text))</div>\
        <main id="agterm-page"></main></body></html>
        """
    }
}

/// DiffSection is one file of a patch: the path it shows and the 0-based line its header starts on.
struct DiffSection: Codable, Equatable, Sendable {
    let path: String
    let line: Int
}
