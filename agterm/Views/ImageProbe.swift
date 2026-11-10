import Darwin
import Foundation
import ImageIO
import agtermCore

/// ImageProbe reads a picture file for an image page: its bytes, its format by signature, and its pixel size
/// and EXIF orientation from the header alone. A clicked path comes from untrusted terminal output, so the
/// file is opened once and judged by what that descriptor names: a symlink is measured at its target, and a
/// FIFO, device, offloaded iCloud placeholder or file over `ImagePage.maxBytes` is refused before a read.
struct ImageProbe: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: Int
    let mimeType: String

    /// load reads the file and probes the bytes it read, so the sniffed type describes the data it returns. A
    /// file over `maxBytes`, `ImagePage.maxBytes` unless a caller has less room, is refused before a read.
    static func load(path: String, maxBytes: Int = ImagePage.maxBytes) -> Result<(ImageProbe, Data), ImageFile.Failure> {
        BoundedFile.read(path: path, maxBytes: maxBytes)
            .mapError { ImageFile.Failure($0, path: path) }
            .flatMap { data in probe(data, path: path).map { ($0, data) } }
    }

    /// probe judges bytes already in hand, a picture fetched from another Mac included; `path` only names it.
    static func probe(_ data: Data, path: String) -> Result<ImageProbe, ImageFile.Failure> {
        guard let mime = ImagePage.mimeType(sniffing: data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return .failure(.notAnImage(path)) }
        guard ImagePage.allowsPixels(width: width, height: height) else { return .failure(.tooManyPixels(path)) }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return .success(ImageProbe(pixelWidth: width, pixelHeight: height, orientation: orientation, mimeType: mime))
    }

    /// natural is the picture's drawn size in points on a display of `scale`.
    func natural(scale: Double) -> (width: Double, height: Double) {
        ImagePage.natural(pixelWidth: pixelWidth, pixelHeight: pixelHeight, orientation: orientation, scale: scale)
    }

    /// loadDetached runs `load` off the main actor, for the routes untrusted terminal output reaches: a file
    /// on slow or network storage must not stall every window while it is read.
    static func loadDetached(path: String) async -> Result<(ImageProbe, Data), ImageFile.Failure> {
        await Task.detached(priority: .userInitiated) { load(path: path) }.value
    }
}
