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

    /// Route is what happens to an offer before anything is inserted.
    public enum Route: Equatable, Sendable {
        /// asIs inserts the offer unchanged: text, web addresses, or paths of files the pane's program can open.
        case asIs
        /// stageHere saves the image on this Mac and inserts its path.
        case stageHere
        /// sendToOrigin copies the files or the image to the host running the pane's program and inserts its paths.
        case sendToOrigin
    }

    /// route is the offer's `Route` for a pane whose program runs on another host (`onOrigin`) or on this Mac.
    public func route(onOrigin: Bool) -> Route {
        switch action {
        case .urls: onOrigin && !fileURLs.isEmpty ? .sendToOrigin : .asIs
        case .image: onOrigin ? .sendToOrigin : .stageHere
        case .text, nil: .asIs
        }
    }

    /// asIsText is the text an `asIs` offer inserts: the URLs joined as `urlText` gives them, else the text.
    public var asIsText: String? {
        urls.isEmpty ? text : urls.map(Self.urlText).joined(separator: " ")
    }

    /// imageName names a pasted image after the moment it was pasted, `clipboard-20261117-153012.png`.
    public static func imageName(at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = [parts.year, parts.month, parts.day].map { String(format: "%02d", $0 ?? 0) }.joined()
            + "-" + [parts.hour, parts.minute, parts.second].map { String(format: "%02d", $0 ?? 0) }.joined()
        return "clipboard-\(stamp).png"
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
