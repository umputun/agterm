import Foundation

/// MarkdownLinkGrant is what a markdown page may follow links within: its file and that file's folder, both with
/// symlinks resolved when the page opens and fixed for its life.
public struct MarkdownLinkGrant: Codable, Equatable, Sendable {
    public let path: String
    public let root: String

    public init(path: String, root: String) {
        self.path = path
        self.root = root
    }
}

/// MarkdownPage is the page a markdown overlay shows. The app reads the file and the local pictures it
/// references, and this builds the document a bundled renderer turns into HTML. The markdown comes from a
/// clicked path in untrusted output, so its text and the picture map travel as escaped, inert data; the page
/// can load only the `data:` pictures the app embedded.
public enum MarkdownPage {
    /// maxBytes bounds the markdown file a page reads.
    public static let maxBytes = 4 << 20
    /// maxImageBytes bounds the pictures one page embeds, all of them together.
    public static let maxImageBytes = 32 << 20
    /// maxImagePixels bounds the decoded pictures one page embeds, all of them together: the budget one image
    /// page has, since several small compressed files can promise more pixels than one large one.
    public static let maxImagePixels = ImagePage.maxPixels
    /// maxImages bounds the distinct picture files one page probes, a failed probe included. `render.js`
    /// separately shows at most this many picture occurrences.
    public static let maxImages = 256

    /// Image is one picture reference and the local file it may embed.
    public struct Image: Equatable, Sendable {
        /// reference is the reference as written, percent-decoded: the form the renderer looks it up by,
        /// since the two parsers encode a reference differently.
        public let reference: String
        public let path: String
    }

    /// Embedded is the pictures a page carries: each file's data URI once in `uris`, and every reference that
    /// names it as an index into them, so a picture referenced under many spellings is still one copy.
    public struct Embedded: Encodable, Equatable, Sendable {
        public var uris: [String] = []
        public var references: [String: Int] = [:]

        public init(uris: [String] = [], references: [String: Int] = [:]) {
            self.uris = uris
            self.references = references
        }
    }

    /// imageReferences lists each picture `markdown` references that names a file inside `folder`, the
    /// markdown file's own folder, after symlinks on both sides are resolved; in document order, each
    /// reference once. A remote, a `data:` or an escaping reference is left out and renders as its alt text.
    public static func imageReferences(in markdown: String, folder: String) -> [Image] {
        references(in: markdown) { localPath($0, folder: folder) }
    }

    /// remoteImageReferences lists the same references for a markdown file on another Mac, `folder` being its
    /// folder there, checked lexically only; a markdown-spelled one is left out, since that Mac serves it as text.
    public static func remoteImageReferences(in markdown: String, folder: String) -> [Image] {
        references(in: markdown) { isMarkdown($0) ? nil : lexicalPath($0, folder: folder) }
    }

    /// linkGrant is what a page opened on `path` may follow links within, nil when its links stay text: a relative
    /// path, a target that is not markdown, or a folder that is `/` or `home`, all judged with symlinks resolved.
    public static func linkGrant(for path: String, home: String = NSHomeDirectory()) -> MarkdownLinkGrant? {
        guard path.hasPrefix("/") else { return nil }
        let file = real(path)
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().path
        guard isMarkdown(file), root != "/", root != real(home) else { return nil }
        return MarkdownLinkGrant(path: file, root: root)
    }

    /// linkedDocument is the path a link page reads for `requested`, an absolute path already percent-decoded:
    /// the request normalized, so its pictures come from the folder its links resolve against. Nil unless both
    /// the request and its symlink-resolved target are markdown strictly inside the grant's root, so a
    /// `guide.md` alias of a `.env` is refused.
    public static func linkedDocument(_ requested: String, grant: MarkdownLinkGrant) -> String? {
        guard requested.hasPrefix("/"), isMarkdown(requested),
              let lexical = lexicalPath(requested, folder: grant.root) else { return nil }
        let file = real(lexical)
        return isMarkdown(file) && file != grant.root && HtmlOverlay.contains(grant.root, file) ? lexical : nil
    }

    private static func isMarkdown(_ path: String) -> Bool {
        LinkPolicy.markdownExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func references(in markdown: String, path: (String) -> String?) -> [Image] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return [] }
        var found: [Image] = [], seen: Set<String> = []
        for run in parsed.runs {
            guard let url = run.imageURL else { continue }
            let reference = url.relativeString.removingPercentEncoding ?? url.relativeString
            guard seen.insert(reference).inserted, let path = path(reference) else { continue }
            found.append(Image(reference: reference, path: path))
        }
        return found
    }

    /// localPath resolves one decoded reference against `folder`, nil unless it names a file inside it. The
    /// lexical check runs first, so a reference outside the folder is refused without touching the filesystem.
    static func localPath(_ reference: String, folder: String) -> String? {
        guard let lexical = lexicalPath(reference, folder: folder) else { return nil }
        let realRoot = real(LinkPolicy.lexicallyNormalizedAbsolutePath(folder)), file = real(lexical)
        return file != realRoot && HtmlOverlay.contains(realRoot, file) ? file : nil
    }

    /// lexicalPath joins one decoded reference to `folder` and normalizes it without reading the filesystem,
    /// nil unless the result lies strictly inside the folder: no `~`, no scheme, no `..` escape.
    public static func lexicalPath(_ reference: String, folder: String) -> String? {
        guard folder.hasPrefix("/"), !reference.isEmpty else { return nil }
        let candidate: String
        if reference.hasPrefix("/") {
            candidate = reference
        } else if reference.hasPrefix("~") || hasScheme(reference) {
            return nil
        } else {
            candidate = folder + "/" + reference
        }
        let root = LinkPolicy.lexicallyNormalizedAbsolutePath(folder)
        let lexical = LinkPolicy.lexicallyNormalizedAbsolutePath(candidate)
        return lexical != root && HtmlOverlay.contains(root, lexical) ? lexical : nil
    }

    private static func hasScheme(_ reference: String) -> Bool {
        guard let colon = reference.firstIndex(of: ":") else { return false }
        let scheme = reference[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }

    private static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// html is the document the renderer fills: the markdown as the text of a hidden element, the embedded
    /// pictures as a JSON attribute, and `style`, the app's own stylesheet. Everything authored is HTML-escaped,
    /// never placed inside a script element, and the policy loads nothing but `data:` pictures. The holder is a
    /// `div`: the parser drops a newline right after `<pre>`, which would move a `---` up to the first line.
    /// `links` lets the renderer keep relative links to neighbouring markdown files.
    public static func html(markdown: String, images: Embedded, style: String, links: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let map = (try? encoder.encode(images)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">\
        <style>\(style)</style></head><body>\
        <div id="agterm-markdown" hidden data-images="\(escaped(map))"\(links ? #" data-links="local""# : "")>\(escaped(markdown))</div>\
        <main id="agterm-page"></main></body></html>
        """
    }

    /// escaped walks scalars, not Characters: a quote fused with a combining mark is one Character
    /// that would match no case and pass through.
    static func escaped(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            case "'": out.append(contentsOf: "&#39;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}
