import Foundation

/// ImageHeader reads a picture's pixel size from its PNG, JPEG, GIF or WebP header without decoding it,
/// for hosts without ImageIO.
public enum ImageHeader {
    private typealias Header = (width: Int, height: Int, orientation: Int)

    /// pixels is the size with JPEG EXIF orientation applied (WebP's is not read), nil for anything not read
    /// with certainty: an unknown format, a truncated or malformed header, or a zero axis.
    /// The `ImagePage.maxPixels` check is the caller's.
    public static func pixels(_ data: Data) -> ImagePixels? {
        let bytes = Bytes(data: data, limit: data.count)
        let size: Header?
        switch ImagePage.mimeType(sniffing: data) {
        case "image/png": size = png(bytes)
        case "image/gif": size = gif(bytes)
        case "image/jpeg": size = jpeg(bytes)
        case "image/webp": size = webp(bytes)
        default: size = nil
        }
        guard let size, size.width > 0, size.height > 0 else { return nil }
        let rotated = (5...8).contains(size.orientation)
        return rotated ? ImagePixels(width: size.height, height: size.width) : ImagePixels(width: size.width, height: size.height)
    }

    private static func png(_ bytes: Bytes) -> Header? {
        guard bytes.matches(12, "IHDR"), let width = bytes.int(16, 4), let height = bytes.int(20, 4) else { return nil }
        return (width, height, 1)
    }

    private static func gif(_ bytes: Bytes) -> Header? {
        guard let width = bytes.int(6, 2, little: true), let height = bytes.int(8, 2, little: true) else { return nil }
        return (width, height, 1)
    }

    private static func jpeg(_ bytes: Bytes) -> Header? {
        var size: (width: Int, height: Int)?
        var orientation: Int?
        var at = 2
        while true {
            guard bytes.byte(at) == 0xFF else { return nil }
            while bytes.byte(at) == 0xFF { at += 1 }
            guard let marker = bytes.byte(at) else { return nil }
            if marker == 0xDA || marker == 0xD9 { break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                at += 1
                continue
            }
            guard let length = bytes.int(at + 1, 2), length >= 2, length <= bytes.limit - at - 1 else { return nil }
            let segment = bytes.narrowed(to: at + 1 + length)
            if size == nil, sofMarkers.contains(marker) {
                guard let height = segment.int(at + 4, 2), let width = segment.int(at + 6, 2) else { return nil }
                size = (width, height)
            }
            if orientation == nil, marker == 0xE1 { orientation = exifOrientation(segment, tiff: at + 9) }
            at += 1 + length
        }
        guard let size else { return nil }
        return (size.width, size.height, orientation ?? 1)
    }

    private static let sofMarkers: Set<UInt8> = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]

    /// exifOrientation reads IFD0's orientation tag from the TIFF block at `tiff`, preceded by the `Exif\0\0`
    /// identifier; nil for an XMP APP1 or any Exif it cannot read, which leaves the picture unrotated.
    private static func exifOrientation(_ bytes: Bytes, tiff: Int) -> Int? {
        guard bytes.matches(tiff - 6, "Exif\0\0") else { return nil }
        let order = bytes.int(tiff, 2)
        guard order == 0x4949 || order == 0x4D4D else { return nil }
        let little = order == 0x4949
        guard bytes.int(tiff + 2, 2, little: little) == 42, let ifd = bytes.int(tiff + 4, 4, little: little),
              let count = bytes.int(tiff + ifd, 2, little: little) else { return nil }
        for index in 0..<count {
            let entry = tiff + ifd + 2 + index * 12
            guard bytes.byte(entry + 11) != nil, let tag = bytes.int(entry, 2, little: little) else { return nil }
            guard tag == 0x0112 else { continue }
            guard bytes.int(entry + 2, 2, little: little) == 3, let value = bytes.int(entry + 8, 2, little: little),
                  (1...8).contains(value) else { return nil }
            return value
        }
        return nil
    }

    private static func webp(_ bytes: Bytes) -> Header? {
        guard let chunkSize = bytes.int(16, 4, little: true), chunkSize <= bytes.limit - 20 else { return nil }
        let chunk = bytes.narrowed(to: 20 + chunkSize)
        if chunk.matches(12, "VP8 ") {
            guard chunk.byte(23) == 0x9D, chunk.byte(24) == 0x01, chunk.byte(25) == 0x2A,
                  let width = chunk.int(26, 2, little: true), let height = chunk.int(28, 2, little: true) else { return nil }
            return (width & 0x3FFF, height & 0x3FFF, 1)
        }
        if chunk.matches(12, "VP8L") {
            guard chunk.byte(20) == 0x2F, let bits = chunk.int(21, 4, little: true) else { return nil }
            return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1, 1)
        }
        if chunk.matches(12, "VP8X") {
            guard let width = chunk.int(24, 3, little: true), let height = chunk.int(27, 3, little: true) else { return nil }
            return (width + 1, height + 1, 1)
        }
        return nil
    }
}

/// Bytes reads `data` by offset from its start, never at or past `limit`. A `Data` slice keeps its parent's
/// indices, so a raw subscript would trap or read the wrong byte.
private struct Bytes {
    let data: Data
    let limit: Int

    func narrowed(to end: Int) -> Bytes { Bytes(data: data, limit: min(limit, end)) }

    func byte(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < limit else { return nil }
        return data[data.startIndex + offset]
    }

    func int(_ offset: Int, _ width: Int, little: Bool = false) -> Int? {
        guard offset >= 0, width <= limit - offset else { return nil }
        let start = data.startIndex + offset
        let field = data[start..<start + width]
        return little ? field.reversed().reduce(0) { $0 << 8 | Int($1) } : field.reduce(0) { $0 << 8 | Int($1) }
    }

    func matches(_ offset: Int, _ text: String) -> Bool {
        let expected = Array(text.utf8)
        guard offset >= 0, expected.count <= limit - offset else { return false }
        let start = data.startIndex + offset
        return data[start..<start + expected.count].elementsEqual(expected)
    }
}
