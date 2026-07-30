import Foundation
import Testing
@testable import agtermCore

struct ThemeBrightnessTests {
    @Test func pureBlackAndWhite() {
        #expect(ThemeBrightness.isDark(red: 0, green: 0, blue: 0))
        #expect(!ThemeBrightness.isDark(red: 1, green: 1, blue: 1))
    }

    @Test func realThemeBackgrounds() {
        // gruvbox dark hard #1d2021, solarized dark #002b36 → dark
        #expect(ThemeBrightness.isDark(red: 0.114, green: 0.125, blue: 0.129))
        #expect(ThemeBrightness.isDark(red: 0.0, green: 0.169, blue: 0.212))
        // solarized light #fdf6e3 → light
        #expect(!ThemeBrightness.isDark(red: 0.992, green: 0.965, blue: 0.890))
    }

    @Test func greenDominatesTheLumaWeighting() {
        // Rec. 601 weights: green 0.587 clears the 0.5 midpoint, red 0.299 and blue 0.114 do not
        #expect(!ThemeBrightness.isDark(red: 0, green: 1, blue: 0))
        #expect(ThemeBrightness.isDark(red: 0, green: 0, blue: 1))
        #expect(ThemeBrightness.isDark(red: 1, green: 0, blue: 0))
    }

    @Test func grayScaleAroundTheMidpoint() {
        // a mid gray's luminance equals its component, so it pins the 0.5 threshold; exactly 0.5 is a
        // float-rounding knife edge no real theme lands on, so it isn't asserted.
        #expect(!ThemeBrightness.isDark(red: 0.55, green: 0.55, blue: 0.55))
        #expect(ThemeBrightness.isDark(red: 0.45, green: 0.45, blue: 0.45))
    }

    @Test func neutralShiftMatchesTheRawClassifier() {
        #expect(ThemeBrightness.isDark(red: 0.114, green: 0.125, blue: 0.129, shiftAmount: 0))
        #expect(!ThemeBrightness.isDark(red: 0.992, green: 0.965, blue: 0.890, shiftAmount: 0))
    }

    @Test func strongTintCrossesTheMidpoint() {
        // hot dog stand #ea3323, raw luma ~0.41; -0.30 is the sidebar-tint slider at its lightest, which
        // raises the effective sidebar to ~0.59.
        let (r, g, b) = (0.918, 0.200, 0.137)
        #expect(ThemeBrightness.isDark(red: r, green: g, blue: b))
        #expect(!ThemeBrightness.isDark(red: r, green: g, blue: b, shiftAmount: -0.30))
        // mirror direction: +0.30 is the full darkening wash, taking ~0.55 to ~0.385.
        #expect(!ThemeBrightness.isDark(red: 0.55, green: 0.55, blue: 0.55))
        #expect(ThemeBrightness.isDark(red: 0.55, green: 0.55, blue: 0.55, shiftAmount: 0.30))
    }
}
