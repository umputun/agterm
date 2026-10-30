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

    enum Failure: Error, Sendable, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(String)
        case notAnImage(String)
        case tooManyPixels(String)

        var description: String {
            switch self {
            case .unreadable(let path): "unreadable image: \(path)"
            case .tooLarge(let path): "image too large (over \(ImagePage.maxBytes >> 20) MB): \(path)"
            case .notAnImage(let path): "not a png, jpg, gif or webp image: \(path)"
            case .tooManyPixels(let path): "image too large (over \(ImagePage.maxPixels / 1_000_000) megapixels): \(path)"
            }
        }
    }

    /// load reads the file and probes the bytes it read, so the sniffed type describes the data it returns.
    static func load(path: String) -> Result<(ImageProbe, Data), Failure> {
        read(path: path).flatMap { data in probe(data, path: path).map { ($0, data) } }
    }

    /// read returns the whole regular file at `path`, through the one descriptor it checked.
    private static func read(path: String) -> Result<Data, Failure> {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.unreadable(path)) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0 else {
            return .failure(.unreadable(path))
        }
        guard info.st_size <= ImagePage.maxBytes else { return .failure(.tooLarge(path)) }
        var data = Data(count: Int(info.st_size))
        var filled = 0
        while filled < data.count {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress! + filled, buffer.count - filled)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            filled += count
        }
        return filled == data.count ? .success(data) : .failure(.unreadable(path))
    }

    private static func probe(_ data: Data, path: String) -> Result<ImageProbe, Failure> {
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
    static func loadDetached(path: String) async -> Result<(ImageProbe, Data), Failure> {
        await Task.detached(priority: .userInitiated) { load(path: path) }.value
    }
}
