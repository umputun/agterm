import Foundation

/// MarkdownFile judges a markdown file named by untrusted output by its descriptor alone, before a page reads it.
public enum MarkdownFile {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(String)
        case notText(String)

        public init(_ failure: BoundedFile.Failure, path: String) {
            self = failure == .tooLarge ? .tooLarge(path) : .unreadable(path)
        }

        public var description: String {
            switch self {
            case .unreadable(let path): "unreadable markdown file: \(path)"
            case .tooLarge(let path): "markdown file too large (over \(MarkdownPage.maxBytes >> 20) MB): \(path)"
            case .notText(let path): "not a UTF-8 text file: \(path)"
            }
        }
    }

    /// check decides whether `path` can open as a page without reading it.
    public static func check(path: String) -> Result<Void, Failure> {
        BoundedFile.check(path: path, maxBytes: MarkdownPage.maxBytes).mapError { Failure($0, path: path) }
    }

    /// checkDetached runs `check` off the main actor, for a click: opening a file on slow storage can block.
    public static func checkDetached(path: String) async -> Result<Void, Failure> {
        await Task.detached(priority: .userInitiated) { check(path: path) }.value
    }
}
