import Foundation

/// Resolves a filesystem URL handed to the app by `open -a agterm <path>` (the OS "open terminal here"
/// integration) to the directory a new session starts in: the path itself when a directory, else its parent
/// when an existing file. Nil for a non-file URL or a missing path, so the caller opens no stray session.
public enum OpenPathResolver {
    public static func directory(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
    }
}
