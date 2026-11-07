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
        for row in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        where row.hasPrefix("--- ") || row.hasPrefix("+++ ") {
            let path = String(row.dropFirst(4).prefix { $0 != "\t" })
            let file = path.count > 1 && path.hasPrefix("\"") && path.hasSuffix("\"") ? String(path.dropFirst().dropLast()) : path
            if let language = language(forFile: file) { found[path] = language }
        }
        return found
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
    /// `change` is the change a rebuilt page reopens on, from 1. Under the limit a diff also carries `diffLanguages`
    /// as JSON, so each file's lines are highlighted in that file's language.
    public static func html(text: String, language: String?, line: Int?, style: String, log: TextLogState? = nil,
                            anchor: Double? = nil, search: SearchState? = nil, change: Int? = nil) -> String {
        var attributes = ""
        let highlighted = text.utf8.count <= maxHighlightBytes
        if log == nil, language == diffLanguage {
            attributes += " data-diff"
            if let change, change > 0 { attributes += " data-change=\"\(change)\"" }
            let files = highlighted ? diffLanguages(in: text) : [:]
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if !files.isEmpty, let json = try? encoder.encode(files) {
                attributes += " data-files=\"\(MarkdownPage.escaped(String(decoding: json, as: UTF8.self)))\""
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
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">\
        <style>\(style)</style></head><body>\
        <div id="agterm-text" hidden\(attributes)>\(MarkdownPage.escaped(text))</div>\
        <main id="agterm-page"></main></body></html>
        """
    }
}
