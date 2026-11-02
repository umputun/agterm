import Foundation

/// SessionInfoSpan is one styled run of a session info line. Host-free, so the app maps it to fonts and colors.
public struct SessionInfoSpan: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var dim = false
    public var color: TintColor?

    public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, dim: Bool = false,
                color: TintColor? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.dim = dim
        self.color = color
    }

    func sameStyle(as other: SessionInfoSpan) -> Bool {
        bold == other.bold && italic == other.italic && code == other.code && dim == other.dim && color == other.color
    }
}

/// SessionInfo is a session's caller-set sidebar info line: the source as sent, whether it is markdown, its
/// configured expiry in seconds (0 for none), and the spans the row draws.
public struct SessionInfo: Equatable, Sendable {
    /// maxSourceBytes caps the source in UTF-8 bytes; markup syntax counts toward it.
    public static let maxSourceBytes = 512

    public let source: String
    public let markdown: Bool
    public let hideAfter: Double
    public let spans: [SessionInfoSpan]

    /// make validates a set and parses its source; a failure carries the control response message.
    public static func make(source: String, markdown: Bool, hideAfter: Double) -> Result<SessionInfo, SessionInfoRejection> {
        guard source.utf8.count <= maxSourceBytes else {
            return .failure(SessionInfoRejection(message: "info text is over \(maxSourceBytes) bytes"))
        }
        guard HudSpec.isValidHideAfter(hideAfter) else {
            return .failure(SessionInfoRejection(message: "--hide-after must be 0...\(Int(HudSpec.maxHideAfter)) seconds"))
        }
        do {
            let spans = try SessionInfoMarkup.spans(source, markdown: markdown)
            return .success(SessionInfo(source: source, markdown: markdown, hideAfter: hideAfter, spans: spans))
        } catch {
            return .failure(SessionInfoRejection(message: error.message))
        }
    }
}

/// SessionInfoRejection is a refused `session.info` set, worded for the control response.
public struct SessionInfoRejection: Error, Equatable {
    public let message: String
}

/// SessionInfoMarkup turns a session info source into spans. Markdown is inline-only Foundation markdown plus
/// `^[text](color: "NAME")` and `^[text](dim: true)`; a link keeps its label and drops its target. An unknown
/// attribute key is dropped by Foundation and renders unstyled, which is accepted rather than lexed for.
enum SessionInfoMarkup {
    /// ParseError is why a source was refused.
    enum ParseError: Error, Equatable {
        case empty
        case lineBreak
        case controlCharacter
        case unknownColor(String)
        case invalidMarkdown

        var message: String {
            switch self {
            case .empty: "info text is empty"
            case .lineBreak: "info text must be one line"
            case .controlCharacter: "info text contains a control character"
            case .unknownColor(let name): "unknown info color: \(name) (\(TintColor.validNamesList))"
            case .invalidMarkdown: "invalid info markdown; quote attribute values: ^[text](color: \"green\")"
            }
        }
    }

    /// spans parses `source` as markdown when `markdown` is set, otherwise as literal text. The visible text
    /// must be non-blank and one line with no control characters, checked after entities are decoded.
    static func spans(_ source: String, markdown: Bool) throws(ParseError) -> [SessionInfoSpan] {
        let spans = markdown ? try parseMarkdown(source) : [SessionInfoSpan(text: source)]
        try validate(spans.map(\.text).joined())
        return spans
    }

    private static func parseMarkdown(_ source: String) throws(ParseError) -> [SessionInfoSpan] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: source, including: \.agtermSessionInfo, options: options)
        } catch {
            throw .invalidMarkdown
        }
        var spans: [SessionInfoSpan] = []
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var color: TintColor?
            if let name = run[SessionInfoColorKey.self] {
                guard let known = TintColor(rawValue: name.lowercased()) else { throw .unknownColor(name) }
                color = known
            }
            let span = SessionInfoSpan(text: String(parsed[run.range].characters),
                                       bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized),
                                       code: intent.contains(.code), dim: run[SessionInfoDimKey.self] ?? false,
                                       color: color)
            if let last = spans.last, last.sameStyle(as: span) {
                spans[spans.count - 1].text += span.text
                continue
            }
            spans.append(span)
        }
        return spans
    }

    private static func validate(_ text: String) throws(ParseError) {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x2028, 0x2029, 0x85: throw .lineBreak
            default: if scalar.properties.generalCategory == .control { throw .controlCharacter }
            }
        }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw .empty }
    }
}

enum SessionInfoColorKey: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
    typealias Value = String
    static let name = "color"
}

enum SessionInfoDimKey: CodableAttributedStringKey, MarkdownDecodableAttributedStringKey {
    typealias Value = Bool
    static let name = "dim"
}

extension AttributeScopes {
    struct SessionInfoAttributes: AttributeScope {
        let color: SessionInfoColorKey
        let dim: SessionInfoDimKey
        let foundation: FoundationAttributes
    }

    var agtermSessionInfo: SessionInfoAttributes.Type { SessionInfoAttributes.self }
}
