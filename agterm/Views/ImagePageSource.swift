import Foundation
import agtermCore

/// ImagePageSource serves an image page's checked bytes through its scheme handler, so the picture never
/// travels as base64 text. Each load's bytes answer only that load's address and are handed over once.
@MainActor
final class ImagePageSource {
    private let pageID: UUID
    private var staged: (path: String, mimeType: String, data: Data)?

    init(pageID: UUID) {
        self.pageID = pageID
    }

    /// stage holds `data` for `load` in place of anything staged before and returns the address the page
    /// reads it from.
    func stage(_ data: Data, mimeType: String, load: Int) -> URL? {
        let path = "/image/\(load)"
        staged = (path, mimeType, data)
        return HtmlPageSchemeHandler.url(pageID: pageID, path: path)
    }

    /// clear drops bytes no request took, for a page that closed or failed.
    func clear() {
        staged = nil
    }

    /// source answers the staged address once and refuses any later request for it.
    nonisolated var source: HtmlPageSchemeHandler.Source {
        { @MainActor [weak self] path in
            guard let self, let image = staged, image.path == path else { throw URLError(.fileDoesNotExist) }
            staged = nil
            return HtmlPageResource(mimeType: image.mimeType, chunks: AsyncThrowingStream { continuation in
                continuation.yield(image.data)
                continuation.finish()
            })
        }
    }
}
