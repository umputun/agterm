import Foundation
import Testing
@testable import agtermCore

struct ThemeNameTests {
    @Test func plainNameIsReturnedForBothAppearances() {
        #expect(ThemeName.resolved(from: "Gruvbox Dark Hard", isDark: true) == "Gruvbox Dark Hard")
        #expect(ThemeName.resolved(from: "Gruvbox Dark Hard", isDark: false) == "Gruvbox Dark Hard")
        #expect(ThemeName.resolved(from: "GitHub Light Default", isDark: false) == "GitHub Light Default")
    }

    @Test func plainNameIsTrimmed() {
        #expect(ThemeName.resolved(from: "  Alabaster  ", isDark: false) == "Alabaster")
    }

    @Test func lightDarkFormPicksTheMatchingVariant() {
        let value = "light:Alabaster,dark:Gruvbox Dark Hard"
        #expect(ThemeName.resolved(from: value, isDark: false) == "Alabaster")
        #expect(ThemeName.resolved(from: value, isDark: true) == "Gruvbox Dark Hard")
    }

    @Test func orderOfLightDarkDoesNotMatter() {
        let value = "dark:Gruvbox Dark Hard,light:Alabaster"
        #expect(ThemeName.resolved(from: value, isDark: false) == "Alabaster")
        #expect(ThemeName.resolved(from: value, isDark: true) == "Gruvbox Dark Hard")
    }

    @Test func whitespaceAroundVariantsIsTrimmed() {
        let value = "light: GitHub Light Default , dark: Gruvbox Dark Hard "
        #expect(ThemeName.resolved(from: value, isDark: false) == "GitHub Light Default")
        #expect(ThemeName.resolved(from: value, isDark: true) == "Gruvbox Dark Hard")
    }

    @Test func prefixMatchIsCaseInsensitive() {
        let value = "LIGHT:Alabaster,DARK:Gruvbox Dark Hard"
        #expect(ThemeName.resolved(from: value, isDark: false) == "Alabaster")
        #expect(ThemeName.resolved(from: value, isDark: true) == "Gruvbox Dark Hard")
    }

    @Test func oneSidedFormIsNotTreatedAsSplit() {
        // ghostty requires both sides; a one-sided value is malformed and returned as-is.
        #expect(ThemeName.resolved(from: "light:Alabaster", isDark: true) == "light:Alabaster")
        #expect(ThemeName.resolved(from: "dark:Gruvbox Dark Hard", isDark: false) == "dark:Gruvbox Dark Hard")
    }

    @Test func emptyVariantIsNotTreatedAsSplit() {
        #expect(ThemeName.resolved(from: "light:,dark:Gruvbox Dark Hard", isDark: false) == "light:,dark:Gruvbox Dark Hard")
        #expect(ThemeName.resolved(from: "light:Alabaster,dark:", isDark: true) == "light:Alabaster,dark:")
    }
}
