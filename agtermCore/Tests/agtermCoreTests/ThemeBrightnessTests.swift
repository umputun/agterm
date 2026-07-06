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
        // pure green is the brightest primary under Rec. 601 (0.587) → light
        #expect(!ThemeBrightness.isDark(red: 0, green: 1, blue: 0))
        // pure blue is the dimmest (0.114) → dark
        #expect(ThemeBrightness.isDark(red: 0, green: 0, blue: 1))
        // pure red sits below the 0.5 midpoint (0.299) → dark
        #expect(ThemeBrightness.isDark(red: 1, green: 0, blue: 0))
    }

    @Test func grayScaleAroundTheMidpoint() {
        // a mid gray's luminance equals its component, so it pins the 0.5 threshold: brighter than the
        // midpoint reads light, dimmer reads dark. (exactly 0.5 is a float-rounding knife edge no real
        // theme lands on, so it isn't asserted.)
        #expect(!ThemeBrightness.isDark(red: 0.55, green: 0.55, blue: 0.55))
        #expect(ThemeBrightness.isDark(red: 0.45, green: 0.45, blue: 0.45))
    }

    @Test func neutralShiftMatchesTheRawClassifier() {
        // shiftAmount 0 (the neutral tint) applies no wash, so it agrees with the un-shifted classifier.
        #expect(ThemeBrightness.isDark(red: 0.114, green: 0.125, blue: 0.129, shiftAmount: 0))
        #expect(!ThemeBrightness.isDark(red: 0.992, green: 0.965, blue: 0.890, shiftAmount: 0))
    }

    @Test func strongTintCrossesTheMidpoint() {
        // hot dog stand #ea3323 has raw luma ~0.41 → dark, but a full lightening wash (shiftAmount -0.30,
        // the sidebar-tint slider at its lightest) raises the effective sidebar to ~0.59 → light.
        let (r, g, b) = (0.918, 0.200, 0.137)
        #expect(ThemeBrightness.isDark(red: r, green: g, blue: b))                       // raw background: dark
        #expect(!ThemeBrightness.isDark(red: r, green: g, blue: b, shiftAmount: -0.30))  // washed sidebar: light
        // mirror direction: a light gray (raw ~0.55 → light) with a full darkening wash (+0.30) → ~0.385 → dark.
        #expect(!ThemeBrightness.isDark(red: 0.55, green: 0.55, blue: 0.55))
        #expect(ThemeBrightness.isDark(red: 0.55, green: 0.55, blue: 0.55, shiftAmount: 0.30))
    }
}
