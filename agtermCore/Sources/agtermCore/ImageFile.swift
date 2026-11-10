import Foundation

/// ImageFile reads a picture file for an image page where ImageIO is unavailable: the bytes through
/// `BoundedFile`, the format by signature and the pixel size from the header alone.
public enum ImageFile {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(String)
        case notAnImage(String)
        case tooManyPixels(String)

        public init(_ failure: BoundedFile.Failure, path: String) {
            self = failure == .tooLarge ? .tooLarge(path) : .unreadable(path)
        }

        public var description: String {
            switch self {
            case .unreadable(let path): "unreadable image: \(path)"
            case .tooLarge(let path): "image too large (over \(ImagePage.maxBytes >> 20) MB): \(path)"
            case .notAnImage(let path): "not a png, jpg, gif or webp image: \(path)"
            case .tooManyPixels(let path): "image too large (over \(ImagePage.maxPixels / 1_000_000) megapixels): \(path)"
            }
        }
    }

    /// pixels reads `path` and returns its orientation-applied size.
    public static func pixels(path: String) -> Result<ImagePixels, Failure> {
        BoundedFile.read(path: path, maxBytes: ImagePage.maxBytes)
            .mapError { Failure($0, path: path) }
            .flatMap { data in
                guard ImagePage.mimeType(sniffing: data) != nil, let pixels = ImageHeader.pixels(data) else {
                    return .failure(.notAnImage(path))
                }
                guard ImagePage.allowsPixels(width: pixels.width, height: pixels.height) else { return .failure(.tooManyPixels(path)) }
                return .success(pixels)
            }
    }
}
