import Foundation

/// DocumentPage is an HTML file a terminal click opens: its text is loaded as the page, with no file grant or bridge,
/// since terminal output named it.
public enum DocumentPage {
    /// extensions lists the local file extensions a click opens as a document page.
    public static let extensions: Set<String> = ["html", "htm"]
    /// maxBytes bounds the file a page reads.
    public static let maxBytes = 4 << 20
    // subresource loads never pass the navigation policy; the app's rule list also blocks the link hints this cannot
    static let policy = #"<meta http-equiv="Content-Security-Policy" "#
        + #"content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; media-src data:">"#

    /// page returns the file's text with `policy` ahead of its content, nil when `TextPage.validate` refuses it.
    public static func page(_ data: Data) -> String? {
        TextPage.validate(data).map(withPolicy)
    }

    // after a leading doctype, since any tag ahead of it puts the page in quirks mode; only HTML's ASCII whitespace may
    // precede it, as anything else starts the body, where the parser ignores a CSP meta. Scalars, not Characters: a
    // combining mark after the doctype's `>` would hide it inside one Character
    static func withPolicy(_ html: String) -> String {
        let blank: Set<Unicode.Scalar> = ["\t", "\n", "\u{0C}", "\r", " "]
        let scalars = html.unicodeScalars
        let rest = scalars[(scalars.firstIndex { !blank.contains($0) } ?? scalars.endIndex)...]
        guard String(String.UnicodeScalarView(rest.prefix(9))).lowercased() == "<!doctype",
              let end = rest.firstIndex(of: ">") else { return policy + html }
        var page = String.UnicodeScalarView(scalars[...end])
        page.append(contentsOf: policy.unicodeScalars)
        page.append(contentsOf: scalars[scalars.index(after: end)...])
        return String(page)
    }
}
