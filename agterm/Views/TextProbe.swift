import Foundation
import agtermCore

/// TextProbe reads a text file named by untrusted output through `BoundedFile`. Its check reads and validates
/// the content too, so a binary file fails the click and is revealed instead of opening an empty page. A log is
/// read from its end, so its size is never refused.
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
            .flatMap { text($0, path: path) }
    }

    /// text validates bytes already in hand, a file fetched from another Mac included; `path` only names it.
    static func text(_ data: Data, path: String) -> Result<String, Failure> {
        TextPage.validate(data).map(Result.success) ?? .failure(.notText(path))
    }

    /// checkDetached runs `check` off the main actor, for a click: opening a file on slow storage can block.
    static func checkDetached(path: String) async -> Result<Void, Failure> {
        await Task.detached(priority: .userInitiated) { check(path: path) }.value
    }

    /// LogRead is what a log page shows and the version of the file it came from; `snapshot` is nil when the file's
    /// end is binary, so an unchanged binary file is not read again.
    struct LogRead: Sendable, Equatable {
        let snapshot: LogTail.Snapshot?
        let stamp: BoundedFile.FileStamp
    }

    /// checkLog reads the last `tail` lines of a log the way its page will, so a binary or unreadable file is refused at
    /// any size, and only for the lines the page shows.
    static func checkLog(path: String, tail: Int = TextPage.defaultTail) -> Result<Void, Failure> {
        loadLog(path: path, tail: tail).flatMap { $0?.snapshot == nil ? .failure(.notText(path)) : .success(()) }
    }

    /// loadLog reads the last `tail` lines of `path` within `TextPage.maxTailBytes`; nil when the file still has
    /// `unchangedFrom`'s stamp, which costs one `fstat` and no read.
    static func loadLog(path: String, tail: Int, unchangedFrom: BoundedFile.FileStamp? = nil) -> Result<LogRead?, Failure> {
        BoundedFile.readTail(path: path, maxBytes: TextPage.maxTailBytes, unchangedFrom: unchangedFrom)
            .mapError { _ in .unreadable(path) }
            .map { read in
                read.map { LogRead(snapshot: LogTail.snapshot($0.data, offset: $0.offset, maxLines: tail), stamp: $0.stamp) }
            }
    }

    /// checkLogDetached runs `checkLog` off the main actor, for a click.
    static func checkLogDetached(path: String) async -> Result<Void, Failure> {
        await Task.detached(priority: .userInitiated) { checkLog(path: path) }.value
    }
}
