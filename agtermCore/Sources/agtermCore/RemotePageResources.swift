import Foundation

/// RemotePageResources decides which file on this Mac a page channel's resource request may read. A replica asks
/// by the origin path its scheme URL carries, so a request is an absolute path on this Mac.
public enum RemotePageResources {
    /// resolve maps `requested` to the file the page may read, nil when it may not: with no grant only the page's
    /// own file, with a grant any file inside it. Both sides are standardized and their symlinks resolved before
    /// the check, so a `..` or a link that escapes the folder is refused. The path arrives already decoded
    /// from the scheme URL. A content page (image, markdown, text, document) is never served through here: see `content`.
    public static func resolve(_ requested: String, source: HtmlSource) -> String? {
        guard case .file(let path, let grantRoot) = source, requested.hasPrefix("/") else { return nil }
        let file = real(requested)
        guard let grantRoot else { return file == real(path) ? file : nil }
        return HtmlOverlay.contains(real(grantRoot), file) && file != real(grantRoot) ? file : nil
    }

    /// ContentResource is one file a content page may read, with the byte cap it is read under and whether its
    /// bytes must carry a picture signature before any of them is sent.
    public struct ContentResource: Equatable, Sendable {
        public let path: String
        public let maxBytes: Int
        public let picture: Bool
    }

    /// content maps `requested` to the file a content page may read, nil when it may not: an image or text page
    /// reads only its own file, as does a document page; a markdown page its own file and the pictures inside its folder, symlinks
    /// resolved on this Mac. A markdown page's other file is served only as a picture, whatever its name. With `links`,
    /// a markdown-spelled request is served only through `linkedDocument`, and pictures come from anywhere in its root.
    public static func content(_ requested: String, source: HtmlSource, links: MarkdownLinkGrant? = nil) -> ContentResource? {
        guard requested.hasPrefix("/") else { return nil }
        switch source {
        case .image(let path):
            return real(requested) == real(path) ? ContentResource(path: real(path), maxBytes: ImagePage.maxBytes, picture: true) : nil
        case .text(let path, _):
            return real(requested) == real(path) ? ContentResource(path: real(path), maxBytes: TextPage.maxBytes, picture: false) : nil
        case .document(let path):
            return real(requested) == real(path) ? ContentResource(path: real(path), maxBytes: DocumentPage.maxBytes, picture: false) : nil
        case .markdown where links != nil:
            return links.flatMap { linkContent(requested, grant: $0) }
        case .markdown(let path):
            if real(requested) == real(path) { return ContentResource(path: real(path), maxBytes: MarkdownPage.maxBytes, picture: false) }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            return MarkdownPage.localPath(requested, folder: folder)
                .map { ContentResource(path: $0, maxBytes: MarkdownPage.maxImageBytes, picture: true) }
        case .file, .url, .replica, .unreadable:
            return nil
        }
    }

    private static func linkContent(_ requested: String, grant: MarkdownLinkGrant) -> ContentResource? {
        guard !LinkPolicy.markdownExtensions.contains(URL(fileURLWithPath: requested).pathExtension.lowercased()) else {
            return MarkdownPage.linkedDocument(requested, grant: grant).map { ContentResource(path: $0, maxBytes: MarkdownPage.maxBytes, picture: false) }
        }
        return MarkdownPage.localPath(requested, folder: grant.root).map { ContentResource(path: $0, maxBytes: MarkdownPage.maxImageBytes, picture: true) }
    }

    private static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
