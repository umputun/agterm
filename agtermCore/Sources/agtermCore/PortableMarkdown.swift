#if !canImport(Darwin) && canImport(Markdown)
import Foundation
import Markdown

// the attributed Markdown initializer is Darwin Foundation only; these Linux paths through swift-markdown cover
// what a headless origin checks: it validates and discovers, the Mac renders

/// MarkdownImageCollector lists every picture source in document order, for `MarkdownPage`.
struct MarkdownImageCollector: MarkupWalker {
    private(set) var sources: [String] = []

    static func sources(in markdown: String) -> [String] {
        var collector = MarkdownImageCollector()
        collector.visit(Document(parsing: markdown))
        return collector.sources
    }

    mutating func visitImage(_ image: Markdown.Image) {
        if let source = image.source { sources.append(source) }
        descendInto(image)
    }
}

extension HudMarkdown {
    /// paintsVisibleText reports a non-space cell after the renderer's own `sanitized`.
    static func paintsVisibleText(_ source: String) -> Bool {
        paints(Document(parsing: source.precomposedStringWithCanonicalMapping))
    }

    private static func paints(_ node: any Markup) -> Bool {
        let text: String?
        switch node {
        case is ThematicBreak: return true
        case let leaf as Markdown.Text: text = leaf.string
        case let code as InlineCode: text = code.code
        case let block as CodeBlock: text = block.code
        case let html as InlineHTML: text = html.rawHTML
        case let html as HTMLBlock: text = html.rawHTML
        default: text = nil
        }
        if let text {
            return sanitized(text).unicodeScalars.contains { !$0.properties.isWhitespace }
        }
        return node.children.contains { paints($0) }
    }
}

extension SessionInfoMarkup {
    private struct Attributes: Decodable {
        let color: String?
        let dim: Bool?
    }

    // a literal head keeps the line one inline paragraph, as Foundation's inline-only mode reads it: a
    // leading `#`, `>` or list marker stays text, and leading spaces are kept. It ends in a space so a source
    // opening with `_x_` is not intraword, where CommonMark refuses underscore emphasis.
    private static let inlineHead = "agterm "

    static func portableSpans(_ source: String) throws(ParseError) -> [SessionInfoSpan] {
        // block parsing drops a trailing newline and turns `x\n---` into a heading, so a raw line break is
        // refused before it can vanish; one decoded from an entity is caught by the shared check afterwards
        let breaks: Set<UInt32> = [0x0A, 0x0D, 0x2028, 0x2029, 0x85]
        guard !source.unicodeScalars.contains(where: { breaks.contains($0.value) }) else { throw .lineBreak }
        var spans: [SessionInfoSpan] = []
        try collect(Document(parsing: inlineHead + source), style: SessionInfoSpan(text: ""), into: &spans)
        // the parser trims a paragraph's trailing space, so a blank source comes back as the bare word
        let word = inlineHead.trimmingCharacters(in: .whitespaces)
        guard let first = spans.first, first.text.hasPrefix(word) else { throw .invalidMarkdown }
        spans[0].text.removeFirst(first.text.hasPrefix(inlineHead) ? inlineHead.count : word.count)
        return spans.filter { !$0.text.isEmpty }
    }

    private static func collect(_ node: any Markup, style: SessionInfoSpan,
                                into spans: inout [SessionInfoSpan]) throws(ParseError) {
        var nested = style
        switch node {
        case let leaf as Markdown.Text:
            append(leaf.string, style: style, to: &spans)
            return
        case let code as InlineCode:
            nested.code = true
            append(code.code, style: nested, to: &spans)
            return
        case let html as InlineHTML:
            append(html.rawHTML, style: style, to: &spans)
            return
        case is SoftBreak, is LineBreak:
            append("\n", style: style, to: &spans)
            return
        case is Strong:
            nested.bold = true
        case is Emphasis:
            nested.italic = true
        case let attributed as InlineAttributes:
            let decoder = JSONDecoder()
            decoder.allowsJSON5 = true
            let values: Attributes
            do {
                values = try decoder.decode(Attributes.self, from: Data(("{" + attributed.attributes + "}").utf8))
            } catch {
                throw .invalidMarkdown
            }
            if let name = values.color {
                guard let color = TintColor(rawValue: name.lowercased()) else { throw .unknownColor(name) }
                nested.color = color
            }
            if let dim = values.dim { nested.dim = dim }
        default:
            break
        }
        for (index, child) in node.children.enumerated() {
            // a second block means the source held a line break Foundation would have kept as text
            if index > 0, node is Document { append("\n", style: style, to: &spans) }
            try collect(child, style: nested, into: &spans)
        }
    }

    private static func append(_ text: String, style: SessionInfoSpan, to spans: inout [SessionInfoSpan]) {
        guard !text.isEmpty else { return }
        var span = style
        span.text = text
        if let last = spans.last, last.sameStyle(as: span) {
            spans[spans.count - 1].text += text
            return
        }
        spans.append(span)
    }
}
#endif
