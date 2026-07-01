import Foundation
import Testing
@testable import agtermCore

struct WatermarkConfigTests {
    @Test func imageOverlayEmitsAllKeys() {
        let watermark = BackgroundWatermark(kind: .image, imagePath: "/tmp/bg.png", opacity: 0.2,
                                            fit: .cover, position: .topLeft, repeats: true)
        let text = WatermarkConfig.overlayText(watermark: watermark, resolvedImagePath: "/tmp/bg.png", fontSize: nil)
        #expect(text.contains("background-opacity = 1\n"))
        #expect(text.contains("background-image = /tmp/bg.png\n"))
        #expect(text.contains("background-image-opacity = 0.2\n"))
        #expect(text.contains("background-image-fit = cover\n"))
        #expect(text.contains("background-image-position = top-left\n"))
        #expect(text.contains("background-image-repeat = true\n"))
        #expect(!text.contains("font-size"))
    }

    @Test func overlayDefaultsFitAndPositionWhenNil() {
        let watermark = BackgroundWatermark(kind: .text, text: "DRAFT")
        let text = WatermarkConfig.overlayText(watermark: watermark, resolvedImagePath: "/x/draft.png", fontSize: nil)
        #expect(text.contains("background-image-fit = contain\n"))
        #expect(text.contains("background-image-position = center\n"))
        #expect(text.contains("background-image-repeat = false\n"))
        // no opacity line when unset (ghostty's 1.0 default applies).
        #expect(!text.contains("background-image-opacity"))
    }

    @Test func overlayPreservesFontZoomAlongsideImage() {
        let watermark = BackgroundWatermark(kind: .image, imagePath: "/a.png")
        let text = WatermarkConfig.overlayText(watermark: watermark, resolvedImagePath: "/a.png", fontSize: 16)
        #expect(text.contains("background-image = /a.png\n"))
        #expect(text.contains("font-size = 16\n"))
    }

    @Test func clearWithZoomEmitsOnlyFontSize() {
        let text = WatermarkConfig.overlayText(watermark: nil, resolvedImagePath: nil, fontSize: 13.5)
        #expect(text == "font-size = 13.5\n")
    }

    @Test func clearWithoutZoomIsEmpty() {
        #expect(WatermarkConfig.overlayText(watermark: nil, resolvedImagePath: nil, fontSize: nil) == "")
    }

    @Test func missingResolvedPathDropsImageKeysButKeepsZoom() {
        // a `.text` watermark whose PNG failed to render: no image keys, but zoom is preserved.
        let watermark = BackgroundWatermark(kind: .text, text: "x")
        let text = WatermarkConfig.overlayText(watermark: watermark, resolvedImagePath: nil, fontSize: 14)
        #expect(!text.contains("background-image"))
        #expect(text == "font-size = 14\n")
    }

    @Test func overlayDropsImageForControlCharPath() {
        // defense-in-depth on the restore path: a persisted spec whose path carries a control char (only
        // reachable by hand-editing workspaces.json) must NOT inject a ghostty key. The image lines are
        // dropped entirely; the font-size line still emits. fit/position are enums now, so only the path
        // is free text and needs this guard.
        let poisoned = "/tmp/x.png\nclipboard-read = allow"
        let watermark = BackgroundWatermark(kind: .image, imagePath: poisoned)
        let text = WatermarkConfig.overlayText(watermark: watermark, resolvedImagePath: poisoned, fontSize: 14)
        #expect(!text.contains("background-image"))
        #expect(!text.contains("clipboard-read"))
        #expect(text == "font-size = 14\n")
    }

    @Test func formattedDropsTrailingZeroForIntegralValues() {
        #expect(WatermarkConfig.formatted(14) == "14")
        #expect(WatermarkConfig.formatted(14.0) == "14")
        #expect(WatermarkConfig.formatted(0.15) == "0.15")
        #expect(WatermarkConfig.formatted(13.5) == "13.5")
    }

    @Test func formattedAvoidsScientificNotation() {
        // String(Double) would render these as 1e-05 / 1e-06, which ghostty's config parser rejects.
        #expect(WatermarkConfig.formatted(0.00001) == "0.00001")
        #expect(!WatermarkConfig.formatted(0.000001).contains("e"))
        #expect(WatermarkConfig.formatted(0.2) == "0.2")
    }

    @Test func formattedStaysTotalForNonFiniteAndHugeValues() {
        // `Int(value)` traps on these; `formatted` must not crash even on a corrupt-snapshot fontSize.
        #expect(WatermarkConfig.formatted(.infinity) == "inf") // ghostty rejects it, but no trap
        #expect(WatermarkConfig.formatted(.nan).isEmpty == false)
        #expect(!WatermarkConfig.formatted(1e20).isEmpty)
    }

    @Test func enumValidationMatchesGhostty() {
        #expect(WatermarkConfig.isValidFit("contain"))
        #expect(WatermarkConfig.isValidFit("cover"))
        #expect(WatermarkConfig.isValidFit("stretch"))
        #expect(WatermarkConfig.isValidFit("none"))
        #expect(!WatermarkConfig.isValidFit("fill"))
        #expect(WatermarkConfig.isValidPosition("center"))
        #expect(WatermarkConfig.isValidPosition("bottom-right"))
        #expect(!WatermarkConfig.isValidPosition("middle"))
        #expect(!WatermarkConfig.isValidPosition("center-center"))
    }

    @Test func watermarkSurvivesSnapshotRoundTrip() throws {
        let watermark = BackgroundWatermark(kind: .text, text: "STAGING", colorHex: "#ffaa00", opacity: 0.18,
                                            fit: .contain, position: .center)
        let snapshot = SessionSnapshot(id: UUID(), customName: "s", cwd: "/tmp", backgroundWatermark: watermark)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.backgroundWatermark == watermark)
    }

    @Test func legacySnapshotWithoutWatermarkDecodes() throws {
        // a snapshot written before the field existed (no `backgroundWatermark` key) decodes as nil.
        let raw = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp"}"#
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(raw.utf8))
        #expect(decoded.backgroundWatermark == nil)
    }

    @Test(arguments: [
        #"{"kind":"text","text":"X","fit":"bogus"}"#,      // unknown fit (e.g. a downgrade / hand-edit typo)
        #"{"kind":"text","text":"X","position":"middle"}"#, // unknown position
        #"{"kind":"hologram","text":"X"}"#,                 // unknown kind
    ])
    func invalidWatermarkDecodesLossilyWithoutWipingTheSession(_ badWatermark: String) throws {
        // a present-but-invalid watermark must NOT throw DataCorrupted and fail the whole SessionSnapshot
        // (which would make PersistenceStore.load start fresh and wipe every workspace/session). It drops
        // to nil while the rest of the session decodes intact.
        let id = UUID()
        let raw = #"{"id":"\#(id.uuidString)","cwd":"/tmp","customName":"keep","backgroundWatermark":\#(badWatermark)}"#
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(raw.utf8))
        #expect(decoded.id == id)                    // the session survives the bad watermark
        #expect(decoded.cwd == "/tmp")
        #expect(decoded.customName == "keep")
        #expect(decoded.backgroundWatermark == nil)  // the invalid spec dropped to nil, not a throw
    }

    @Test(arguments: [0.0, 0.15, 0.5, 1.0])
    func opacityInRangeIsValid(_ opacity: Double) {
        #expect(WatermarkConfig.isValidOpacity(opacity))
    }

    @Test(arguments: [-0.1, 1.0001, 2.0, -100.0, Double.infinity, -Double.infinity, Double.nan])
    func opacityOutOfRangeOrNonFiniteIsInvalid(_ opacity: Double) {
        #expect(!WatermarkConfig.isValidOpacity(opacity))
    }

    @Test(arguments: ["#ff0000", "ff0000", "#FFAA00", "abcdef", "#012345"])
    func validColorHexAccepted(_ hex: String) {
        #expect(WatermarkConfig.isValidColorHex(hex))
    }

    @Test(arguments: ["#fff", "fff", "#zzzzzz", "red", "#ff00", "#ff0000ff", "", "#"])
    func malformedColorHexRejected(_ hex: String) {
        #expect(!WatermarkConfig.isValidColorHex(hex))
    }

    @Test(arguments: ["/tmp/bg.png", "/Users/me/My Pictures/x.png", "relative/path.png", "/tmp/日本語.png", ""])
    func imagePathWithoutControlCharsAccepted(_ path: String) {
        // spaces + unicode are fine (the path rides a raw, whole-line-remainder config value); emptiness is
        // a separate boundary check, so "" passes the control-char gate.
        #expect(WatermarkConfig.isValidImagePath(path))
    }

    @Test(arguments: ["x.png\nclipboard-read = allow\ny.png", "a.png\r", "a\tb.png", "a.png\u{0}", "\u{1b}[2J"])
    func imagePathWithControlCharsRejected(_ path: String) {
        // the injection vector: a newline (or any scalar < 0x20) would split `background-image = <path>`
        // and let the tail inject an arbitrary ghostty key into the per-surface overlay.
        #expect(!WatermarkConfig.isValidImagePath(path))
    }

    @Test func textValidationEnforcesNonEmptyAndMaxLength() {
        #expect(WatermarkConfig.maxTextLength == 256)
        #expect(WatermarkConfig.isValidText("X"))
        #expect(WatermarkConfig.isValidText(String(repeating: "a", count: WatermarkConfig.maxTextLength)))
        #expect(!WatermarkConfig.isValidText(""))
        #expect(!WatermarkConfig.isValidText(String(repeating: "a", count: WatermarkConfig.maxTextLength + 1)))
    }
}
