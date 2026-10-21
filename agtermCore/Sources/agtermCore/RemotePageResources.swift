import Foundation

/// RemotePageResources decides which file on this Mac a page channel's resource request may read. A replica asks
/// by the origin path its scheme URL carries, so a request is an absolute path on this Mac.
public enum RemotePageResources {
    /// resolve maps `requested` to the file the page may read, nil when it may not: with no grant only the page's
    /// own file, with a grant any file inside it. Both sides are standardized and their symlinks resolved before
    /// the check, so a `..` or a link that escapes the folder is refused. The path arrives already decoded
    /// from the scheme URL.
    public static func resolve(_ requested: String, source: HtmlSource) -> String? {
        guard case .file(let path, let grantRoot) = source, requested.hasPrefix("/") else { return nil }
        let file = real(requested)
        guard let grantRoot else { return file == real(path) ? file : nil }
        return HtmlOverlay.contains(real(grantRoot), file) && file != real(grantRoot) ? file : nil
    }

    private static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
