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

    /// LogRead is what a log page shows and the version of the file it came from.
    struct LogRead: Sendable, Equatable {
        let snapshot: LogTail.Snapshot
        let stamp: BoundedFile.FileStamp
    }

    /// checkLog reads the end of a log the way its page will, so a binary or unreadable file is refused at any size.
    static func checkLog(path: String) -> Result<Void, Failure> {
        loadLog(path: path, tail: TextPage.defaultTail).map { _ in () }
    }

    /// loadLog reads the last `tail` lines of `path` within `TextPage.maxTailBytes`; nil when the file still has
    /// `unchangedFrom`'s stamp, which costs one `fstat` and no read.
    static func loadLog(path: String, tail: Int, unchangedFrom: BoundedFile.FileStamp? = nil) -> Result<LogRead?, Failure> {
        BoundedFile.readTail(path: path, maxBytes: TextPage.maxTailBytes, unchangedFrom: unchangedFrom)
            .mapError { _ in .unreadable(path) }
            .flatMap { read in
                guard let read else { return .success(nil) }
                return LogTail.snapshot(read.data, fromFileStart: read.fromFileStart, maxLines: tail)
                    .map { .success(LogRead(snapshot: $0, stamp: read.stamp)) } ?? .failure(.notText(path))
            }
    }

    /// checkLogDetached runs `checkLog` off the main actor, for a click.
    static func checkLogDetached(path: String) async -> Result<Void, Failure> {
        await Task.detached(priority: .userInitiated) { checkLog(path: path) }.value
    }
}
