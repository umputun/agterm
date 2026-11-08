import Foundation
import agtermCore

/// MarkdownPageSource builds the documents a markdown page shows, off the main actor: from a file on this Mac, from
/// one a page shown here for another Mac fetches there, and each linked file a link page's scheme handler asks for.
enum MarkdownPageSource {
    /// Failure is why a document could not be built, worded as the local probe words it; a failed first load shows it.
    struct Failure: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
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
            return try document(await local(path: file, links: true).get())
        }
    }

    /// replicaLinkSource serves a link page shown for another Mac: each requested path is fetched there, where the
    /// origin judges it against the grant it froze, and built here with its pictures.
    static func replicaLinkSource(_ link: HtmlReplicaLink, revision: HtmlReplicaRevision) -> HtmlPageSchemeHandler.Source {
        { path in
            let local = (MarkdownProbe.Failure.tooLarge(path).description, MarkdownProbe.Failure.unreadable(path).description)
            let data = try await link.read(path, revision: revision, limit: MarkdownPage.maxBytes, local: local)
                .mapError { Failure(description: $0.message) }.get()
            let fetch: @Sendable (String, Int) async -> Data? = { picture, limit in
                try? await link.read(picture, revision: revision, limit: limit, local: ("", "")).get()
            }
            return try document(await replica(markdown: data, path: path, fetch: fetch, links: true).get())
        }
    }

    /// replica builds the page for `markdown`, the file at `path` on another Mac; `fetch` reads one of its pictures
    /// there under a byte limit, nil when it cannot.
    static func replica(markdown data: Data, path: String, fetch: @escaping @Sendable (String, Int) async -> Data?,
                        links: Bool = false) async -> Result<String, Failure> {
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
            return .success(MarkdownPage.html(markdown: markdown, images: embedding.embedded, style: style, links: links))
        }.value
    }

    private static func document(_ html: String) -> HtmlPageResource {
        HtmlPageResource(mimeType: "text/html; charset=utf-8", chunks: AsyncThrowingStream {
            $0.yield(Data(html.utf8))
            $0.finish()
        })
    }
}
