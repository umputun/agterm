import Foundation
import agtermCore

/// TextProbe reads a text file named by untrusted output through `BoundedFile`. Its check reads and validates
/// the content too, so a binary file fails the click and is revealed instead of opening an empty page.
enum TextProbe {
    enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(String)
        case notText(String)

        var description: String {
            switch self {
            case .unreadable(let path): "unreadable text file: \(path)"
            case .tooLarge(let path): "text file too large (over \(TextPage.maxBytes >> 20) MB): \(path)"
            case .notText(let path): "not a UTF-8 text file: \(path)"
            }
        }
    }

    static func check(path: String) -> Result<Void, Failure> {
        load(path: path).map { _ in () }
    }

    static func load(path: String) -> Result<String, Failure> {
        BoundedFile.read(path: path, maxBytes: TextPage.maxBytes)
            .mapError { $0 == .tooLarge ? .tooLarge(path) : .unreadable(path) }
            .flatMap { data in TextPage.validate(data).map(Result.success) ?? .failure(.notText(path)) }
    }

    /// checkDetached runs `check` off the main actor, for a click: opening a file on slow storage can block.
    static func checkDetached(path: String) async -> Result<Void, Failure> {
        await Task.detached(priority: .userInitiated) { check(path: path) }.value
    }
}
