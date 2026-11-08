import Foundation
import agtermCore

/// MarkdownPageSource builds the documents a markdown page shows, off the main actor: from a file on this Mac, from
/// one a page shown here for another Mac fetches there, and each linked file a link page's scheme handler asks for.
enum MarkdownPageSource {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func local(path: String, links: Bool) async -> Result<String, Failure> {
        let style = MarkdownAssets.shared.style
        return await Task.detached(priority: .userInitiated) {
            MarkdownProbe.load(path: path)
                .map { MarkdownPage.html(markdown: $0.markdown, images: $0.images, style: style, links: links) }
                .mapError { Failure(description: $0.description) }
        }.value
    }

    /// linkSource serves a link page's requests, its own file included, each judged again by `linkedDocument`
    /// when it is read. Any other path fails without being read.
    static func linkSource(_ grant: MarkdownLinkGrant) -> HtmlPageSchemeHandler.Source {
        { path in
            guard let file = MarkdownPage.linkedDocument(path, grant: grant) else {
                throw URLError(.noPermissionsToReadFile)
            }
            guard case .success(let html) = await local(path: file, links: true) else { throw URLError(.cannotOpenFile) }
            return HtmlPageResource(mimeType: "text/html; charset=utf-8", chunks: AsyncThrowingStream {
                $0.yield(Data(html.utf8))
                $0.finish()
            })
        }
    }

    /// replica builds the page for `markdown`, the file at `path` on another Mac; `fetch` reads one of its pictures
    /// there under a byte limit, nil when it cannot.
    static func replica(markdown data: Data, path: String,
                        fetch: @escaping @Sendable (String, Int) async -> Data?) async -> Result<String, Failure> {
        let style = MarkdownAssets.shared.style
        // parsing, probing, embedding and escaping run detached as the local page's do; only fetches hop back
        return await Task.detached(priority: .userInitiated) {
            guard let markdown = String(data: data, encoding: .utf8) else {
                return .failure(Failure(description: MarkdownProbe.Failure.notText(path).description))
            }
            var embedding = MarkdownEmbedding()
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            for image in MarkdownPage.remoteImageReferences(in: markdown, folder: folder) {
                guard let room = embedding.room(for: image) else { continue }
                let bytes = await fetch(image.path, room)
                embedding.add(image, bytes.flatMap { bytes in (try? ImageProbe.probe(bytes, path: image.path).get()).map { ($0, bytes) } })
            }
            return .success(MarkdownPage.html(markdown: markdown, images: embedding.embedded, style: style))
        }.value
    }
}
