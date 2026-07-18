import Foundation

/// Resolves a filesystem URL handed to the app by `open -a agterm <path>` (the OS "open terminal here"
/// integration) to the directory a new session should start in: the path itself when it is a directory,
/// else its parent directory when it is an existing file. Returns nil for a non-file URL or a path that
/// does not exist, so the caller opens no stray session.
public enum OpenPathResolver {
    public static func directory(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
    }
}
