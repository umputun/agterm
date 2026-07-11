import Foundation

/// Resolves a useful starting directory for folder-picking panels. Candidates are tried in order;
/// stale saved paths fall through to the next candidate, then finally to the user's home directory.
public enum DirectoryPanelDefaults {
    public static func url(paths: String?...) -> URL {
        url(paths: paths)
    }

    public static func url(paths: [String?]) -> URL {
        for path in paths {
            if let url = existingDirectoryURL(for: path) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static func existingDirectoryURL(for path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }
}
