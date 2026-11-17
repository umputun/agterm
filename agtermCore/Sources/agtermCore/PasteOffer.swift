import Foundation

/// PasteOffer is what one paste or drop offers, read off a pasteboard by the app: URLs, text, and PNG bytes of an
/// image. `action` applies the single precedence every paste and drop entry point shares.
public struct PasteOffer: Equatable, Sendable {
    public let urls: [URL]
    public let text: String?
    public let image: Data?

    /// Action is the one thing a paste inserts or transfers.
    public enum Action: Equatable, Sendable {
        case urls([URL])
        case text(String)
        case image(Data)
    }

    /// init drops URLs that contribute no text, and empty text or image data.
    public init(urls: [URL] = [], text: String? = nil, image: Data? = nil) {
        self.urls = urls.filter { !Self.urlText($0).isEmpty }
        self.text = text.flatMap { $0.isEmpty ? nil : $0 }
        self.image = image.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var action: Action? {
        if !urls.isEmpty { return .urls(urls) }
        if let text { return .text(text) }
        return image.map(Action.image)
    }

    /// fileURLs are the offered URLs naming local files, in offer order.
    public var fileURLs: [URL] { urls.filter(\.isFileURL) }

    /// urlText is the text one URL contributes: a shell-escaped path for a file URL, so a path with spaces lands
    /// as one argument, else the escaped absolute string.
    public static func urlText(_ url: URL) -> String {
        ShellEscape.path(url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString)
    }

    /// insertText joins the offered URLs as a paste inserts them, each file URL replaced by the next of
    /// `filePaths` (the same files staged elsewhere) and every other URL kept as `urlText` gives it. Nil unless
    /// there is exactly one staged path per file URL, so a short reply never lets a viewer path through.
    public func insertText(filePaths: [String]) -> String? {
        guard filePaths.count == fileURLs.count else { return nil }
        var staged = filePaths.makeIterator()
        return urls.map { url in
            guard url.isFileURL, let path = staged.next() else { return Self.urlText(url) }
            return ShellEscape.path(path)
        }.joined(separator: " ")
    }
}
