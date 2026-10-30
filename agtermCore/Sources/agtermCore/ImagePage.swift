import Foundation

/// ImagePage is the page an image overlay shows and the size it opens at. The natural size is one image
/// pixel per pixel of the display the window is on, times the page zoom; that is a display convention, not
/// the density the picture was made at. `points` turns it into the panel size the picture fills.
public enum ImagePage {
    /// basePercent is the percent an auto-sized page carries beside its points, which an open requires.
    public static let basePercent = 95
    /// minimumPoints is the narrowest auto-sized panel, wide enough for the strip's name and close button.
    public static let minimumPoints = 240.0
    /// maxBytes bounds the file a page embeds; a larger one is refused before it is read.
    public static let maxBytes = 64 << 20
    /// maxPixels refuses a picture whose header promises more pixels than this, a decompression bomb's tell.
    /// It bounds one decoded frame, about 400 MB at four bytes a pixel, not the page's total memory.
    public static let maxPixels = 100_000_000

    /// allowsPixels says whether a picture of this size stays within `maxPixels`.
    public static func allowsPixels(width: Int, height: Int) -> Bool {
        let pixels = width.multipliedReportingOverflow(by: height)
        return !pixels.overflow && pixels.partialValue <= maxPixels
    }

    /// mimeType sniffs the PNG, JPEG, GIF or WebP signature at the start of `data`, nil for anything else,
    /// so only those four formats ever reach the image parsers, whatever the file is named.
    public static func mimeType(sniffing data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        let starts = { (prefix: [UInt8]) in bytes.starts(with: prefix) }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "image/gif" }
        if starts(Array("RIFF".utf8)), bytes.count == 12, Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }

    /// natural is the picture's drawn size in points. EXIF orientations 5 to 8 rotate it a quarter turn,
    /// which WebKit applies, so the axes swap.
    public static func natural(pixelWidth: Int, pixelHeight: Int, orientation: Int,
                               scale: Double) -> (width: Double, height: Double) {
        let scale = scale > 0 ? scale : 1
        let rotated = (5...8).contains(orientation)
        let (width, height) = rotated ? (pixelHeight, pixelWidth) : (pixelWidth, pixelHeight)
        return (Double(width) / scale, Double(height) / scale)
    }

    /// points is the overlay content size for a picture of `natural` size at page `zoom`, always the picture's
    /// own aspect so it fills the panel: a narrow picture is scaled up to `minimumPoints` wide, and inside
    /// `bounds`, the session's laid-out detail area, one past the point cap is scaled down until both axes fit.
    /// The cap wins over the minimum. Sized once at open, so a later window resize can still leave bands.
    public static func points(natural: (width: Double, height: Double), zoom: Double,
                              bounds: HudPaneFrame? = nil) -> OverlayPointSize {
        var width = natural.width * zoom, height = natural.height * zoom
        guard width > 0, height > 0 else { return OverlayPointSize(width: Int(minimumPoints), height: Int(minimumPoints)) }
        if width < minimumPoints { (width, height) = (minimumPoints, height * minimumPoints / width) }
        if let bounds {
            let room = (width: bounds.width * OverlayPointSize.maxShare,
                        height: bounds.height * OverlayPointSize.maxShare - HtmlOverlay.chromeHeight)
            let fit = min(1, room.width / width, room.height / height)
            if fit > 0 { (width, height) = (width * fit, height * fit) }
        }
        return OverlayPointSize(width: max(1, Int(width.rounded())), height: max(1, Int(height.rounded())))
    }

    /// html shows `data` filling the page with its aspect kept, centered on a transparent canvas.
    public static func html(data: Data, mimeType: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:transparent;overflow:hidden}
        img{display:block;width:100%;height:100%;object-fit:contain}
        </style></head><body><img alt="" src="data:\(mimeType);base64,\(data.base64EncodedString())"></body></html>
        """
    }
}
