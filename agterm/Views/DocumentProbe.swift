import Foundation
import agtermCore

/// DocumentProbe reads an HTML file a terminal click named. The click validates the content before it takes the
/// overlay slot, so a binary or oversized file is revealed instead of opening a failed page.
enum DocumentProbe {
    enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(String)
        case notText(String)

        var description: String {
            switch self {
            case .unreadable(let path): "unreadable html file: \(path)"
            case .tooLarge(let path): "html file too large (over \(DocumentPage.maxBytes >> 20) MB): \(path)"
            case .notText(let path): "not a UTF-8 html file: \(path)"
            }
        }
    }

    static func load(path: String) -> Result<String, Failure> {
        BoundedFile.read(path: path, maxBytes: DocumentPage.maxBytes)
            .mapError { $0 == .tooLarge ? .tooLarge(path) : .unreadable(path) }
            .flatMap { html($0, path: path) }
    }

    /// html validates bytes already in hand, a file fetched from another Mac included; `path` only names it.
    static func html(_ data: Data, path: String) -> Result<String, Failure> {
        DocumentPage.page(data).map(Result.success) ?? .failure(.notText(path))
    }

    /// loadDetached runs `load` off the main actor: opening a file on slow storage can block.
    static func loadDetached(path: String) async -> Result<String, Failure> {
        await Task.detached(priority: .userInitiated) { load(path: path) }.value
    }
}
