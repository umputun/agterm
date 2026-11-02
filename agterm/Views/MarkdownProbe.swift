import Foundation
import agtermCore

/// MarkdownProbe reads a markdown file named by untrusted output, with the local pictures it references
/// embedded until the page's byte or pixel budget runs out; a picture left out renders as its alt text.
struct MarkdownProbe: Sendable {
    let markdown: String
    let images: MarkdownPage.Embedded

    enum Failure: Error, Sendable, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(String)
        case notText(String)

        var description: String {
            switch self {
            case .unreadable(let path): "unreadable markdown file: \(path)"
            case .tooLarge(let path): "markdown file too large (over \(MarkdownPage.maxBytes >> 20) MB): \(path)"
            case .notText(let path): "not a UTF-8 text file: \(path)"
            }
        }
    }

    /// check decides whether `path` can open as a page without reading it.
    static func check(path: String) -> Result<Void, Failure> {
        BoundedFile.check(path: path, maxBytes: MarkdownPage.maxBytes).mapError { failure(failure: $0, path: path) }
    }

    static func load(path: String) -> Result<MarkdownProbe, Failure> {
        let read = BoundedFile.read(path: path, maxBytes: MarkdownPage.maxBytes).mapError { failure(failure: $0, path: path) }
        return read.flatMap { data in
            guard let markdown = String(data: data, encoding: .utf8) else { return .failure(.notText(path)) }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            return .success(MarkdownProbe(markdown: markdown, images: embed(MarkdownPage.imageReferences(in: markdown, folder: folder))))
        }
    }

    /// checkDetached runs `check` off the main actor, for a click: opening a file on slow storage can block.
    static func checkDetached(path: String) async -> Result<Void, Failure> {
        await Task.detached(priority: .userInitiated) { check(path: path) }.value
    }

    private static func embed(_ references: [MarkdownPage.Image]) -> MarkdownPage.Embedded {
        var embedded = MarkdownPage.Embedded(), read: [String: Int?] = [:]
        var bytes = 0, pixels = 0
        for image in references {
            if let known = read[image.path] {
                if let known { embedded.references[image.reference] = known }
                continue
            }
            guard read.count < MarkdownPage.maxImages, bytes < MarkdownPage.maxImageBytes,
                  pixels < MarkdownPage.maxImagePixels else { continue }
            guard case .success(let (probe, data)) = ImageProbe.load(path: image.path, maxBytes: MarkdownPage.maxImageBytes - bytes),
                  pixels + probe.pixelWidth * probe.pixelHeight <= MarkdownPage.maxImagePixels else {
                read[image.path] = .some(nil)
                continue
            }
            bytes += data.count
            pixels += probe.pixelWidth * probe.pixelHeight
            embedded.uris.append("data:\(probe.mimeType);base64,\(data.base64EncodedString())")
            read[image.path] = embedded.uris.count - 1
            embedded.references[image.reference] = embedded.uris.count - 1
        }
        return embedded
    }

    private static func failure(failure: BoundedFile.Failure, path: String) -> Failure {
        failure == .tooLarge ? .tooLarge(path) : .unreadable(path)
    }
}
