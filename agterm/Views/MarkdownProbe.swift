import Foundation
import agtermCore

/// MarkdownProbe reads a markdown file named by untrusted output, with the local pictures it references
/// embedded until the page's byte or pixel budget runs out; a picture left out renders as its alt text.
struct MarkdownProbe: Sendable {
    let markdown: String
    let images: MarkdownPage.Embedded

    static func load(path: String) -> Result<MarkdownProbe, MarkdownFile.Failure> {
        let read = BoundedFile.read(path: path, maxBytes: MarkdownPage.maxBytes).mapError { MarkdownFile.Failure($0, path: path) }
        return read.flatMap { data in
            guard let markdown = String(data: data, encoding: .utf8) else { return .failure(.notText(path)) }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            return .success(MarkdownProbe(markdown: markdown, images: embed(MarkdownPage.imageReferences(in: markdown, folder: folder))))
        }
    }

    private static func embed(_ references: [MarkdownPage.Image]) -> MarkdownPage.Embedded {
        var embedding = MarkdownEmbedding()
        for image in references {
            guard let room = embedding.room(for: image) else { continue }
            embedding.add(image, try? ImageProbe.load(path: image.path, maxBytes: room).get())
        }
        return embedding.embedded
    }
}

/// MarkdownEmbedding collects the pictures one markdown page embeds under its file, byte and pixel budgets, whichever
/// Mac the bytes were read on: each file once, and every reference naming it pointed at that one copy.
struct MarkdownEmbedding {
    private(set) var embedded = MarkdownPage.Embedded()
    private var read: [String: Int?] = [:]
    private var bytes = 0
    private var pixels = 0

    /// room is how many bytes reading `image` may take, nil when it needs no read: a file already read, whose
    /// reference is recorded here, or a spent budget.
    mutating func room(for image: MarkdownPage.Image) -> Int? {
        if let known = read[image.path] {
            if let known { embedded.references[image.reference] = known }
            return nil
        }
        guard read.count < MarkdownPage.maxImages, bytes < MarkdownPage.maxImageBytes,
              pixels < MarkdownPage.maxImagePixels else { return nil }
        return MarkdownPage.maxImageBytes - bytes
    }

    /// add records what reading `image` gave: a probed picture still inside the pixel budget is embedded, and
    /// anything else, a failed read included, leaves the reference to its alt text.
    mutating func add(_ image: MarkdownPage.Image, _ picture: (ImageProbe, Data)?) {
        guard let (probe, data) = picture, pixels + probe.pixelWidth * probe.pixelHeight <= MarkdownPage.maxImagePixels else {
            read[image.path] = .some(nil)
            return
        }
        bytes += data.count
        pixels += probe.pixelWidth * probe.pixelHeight
        embedded.uris.append("data:\(probe.mimeType);base64,\(data.base64EncodedString())")
        read[image.path] = embedded.uris.count - 1
        embedded.references[image.reference] = embedded.uris.count - 1
    }
}
