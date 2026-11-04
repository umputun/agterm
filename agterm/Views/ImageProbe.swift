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

    /// load reads the file and probes the bytes it read, so the sniffed type describes the data it returns. A
    /// file over `maxBytes`, `ImagePage.maxBytes` unless a caller has less room, is refused before a read.
    static func load(path: String, maxBytes: Int = ImagePage.maxBytes) -> Result<(ImageProbe, Data), Failure> {
        BoundedFile.read(path: path, maxBytes: maxBytes)
            .mapError { $0 == .tooLarge ? .tooLarge(path) : .unreadable(path) }
            .flatMap { data in probe(data, path: path).map { ($0, data) } }
    }

    /// probe judges bytes already in hand, a picture fetched from another Mac included; `path` only names it.
    static func probe(_ data: Data, path: String) -> Result<ImageProbe, Failure> {
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

/// BoundedFile reads a file named by untrusted output through one descriptor and judges what that descriptor
/// names: a symlink is measured at its target, and a FIFO, device, offloaded iCloud placeholder or file over
/// the caller's cap is refused before a byte is read.
enum BoundedFile {
    enum Failure: Error, Sendable, Equatable {
        case unreadable
        case tooLarge
    }

    /// check opens `path` and judges it without reading, for a caller deciding only whether a page can open.
    static func check(path: String, maxBytes: Int) -> Result<Void, Failure> {
        withDescriptor(path: path, maxBytes: maxBytes) { _, _ in .success(()) }
    }

    /// read returns the whole regular file at `path`, through the one descriptor it checked.
    static func read(path: String, maxBytes: Int) -> Result<Data, Failure> {
        withDescriptor(path: path, maxBytes: maxBytes) { fd, size in
            var data = Data(count: size)
            var filled = 0
            while filled < data.count {
                let count = data.withUnsafeMutableBytes { buffer in
                    Darwin.read(fd, buffer.baseAddress! + filled, buffer.count - filled)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                filled += count
            }
            return filled == data.count ? .success(data) : .failure(.unreadable)
        }
    }

    private static func withDescriptor<T>(path: String, maxBytes: Int,
                                          _ body: (Int32, Int) -> Result<T, Failure>) -> Result<T, Failure> {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.unreadable) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0 else {
            return .failure(.unreadable)
        }
        guard info.st_size <= maxBytes else { return .failure(.tooLarge) }
        return body(fd, Int(info.st_size))
    }
}
