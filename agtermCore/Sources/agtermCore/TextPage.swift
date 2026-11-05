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

    private static let languages: [String: String] = [
        "swift": "swift", "go": "go", "py": "python", "rb": "ruby", "rs": "rust",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "ts": "typescript",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "m": "objectivec", "mm": "objectivec",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "cs": "csharp", "php": "php", "pl": "perl", "pm": "perl",
        "lua": "lua", "r": "r", "sql": "sql", "css": "css", "scss": "scss", "less": "less", "graphql": "graphql",
        "sh": "bash", "bash": "bash", "zsh": "bash", "json": "json", "yaml": "yaml", "yml": "yaml",
        "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini", "xml": "xml", "plist": "xml",
        "diff": "diff", "patch": "diff", "mk": "makefile", "vb": "vbnet",
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
    /// pages: the first has its own page, the others are documents an author may expect rendered.
    public static func isEligible(file path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return language(forFile: path) != nil || plainExtensions.contains((name as NSString).pathExtension.lowercased())
            || plainBasenames.contains(name)
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

    /// html is the document the renderer fills: the text as the content of a hidden element, the language
    /// and target line as attributes, and `style`, the app's own stylesheet. The language is dropped over
    /// `maxHighlightBytes`, so the renderer shows that text plain. The policy loads nothing at all. The holder
    /// is a `div`: the parser drops a newline right after `<pre>`, which would shift every line number.
    /// A log page (`log` set) carries its follow state instead of a line, and the renderer draws no gutter.
    public static func html(text: String, language: String?, line: Int?, style: String, log: TextLogState? = nil) -> String {
        var attributes = ""
        if let language, text.utf8.count <= maxHighlightBytes {
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
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">\
        <style>\(style)</style></head><body>\
        <div id="agterm-text" hidden\(attributes)>\(MarkdownPage.escaped(text))</div>\
        <main id="agterm-page"></main></body></html>
        """
    }
}
