import Foundation

/// MarkdownAssets is the renderer a markdown page runs and the stylesheet it wears, read once from the
/// bundle's `markdown` folder. A missing file reads as empty, which leaves the page blank rather than failing.
struct MarkdownAssets: Sendable {
    static let shared = MarkdownAssets(bundle: .main)

    /// script is markdown-it, highlight.js and the page's own render.js, in the order they depend on each other.
    let script: String
    let style: String

    init(bundle: Bundle) {
        let read = { (name: String, ext: String) -> String in
            guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "markdown") else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        script = ["markdown-it-14.1.0.min", "highlight-11.11.1.min", "render"].map { read($0, "js") }.joined(separator: ";\n")
        style = read("page", "css")
    }
}
