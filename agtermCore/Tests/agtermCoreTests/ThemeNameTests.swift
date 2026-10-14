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

    @Test func absoluteThemeIsTheOnlyCandidate() {
        let paths = ThemeName.candidatePaths(for: "/Users/me/themes/my-light", userThemesDirectory: "/u", bundledThemesDirectory: "/b")
        #expect(paths == ["/Users/me/themes/my-light"])
    }

    @Test func plainNameTriesUserThemesBeforeBundled() {
        let paths = ThemeName.candidatePaths(for: "My Light", userThemesDirectory: "/u/themes", bundledThemesDirectory: "/b/themes")
        #expect(paths == ["/u/themes/My Light", "/b/themes/My Light"])
    }

    @Test func plainNameSkipsAMissingBundledDirectory() {
        let paths = ThemeName.candidatePaths(for: "My Light", userThemesDirectory: "/u/themes", bundledThemesDirectory: nil)
        #expect(paths == ["/u/themes/My Light"])
    }

    @Test(arguments: ["themes/my-light", "./my-light", ""])
    func relativePathOrEmptyHasNoCandidates(value: String) {
        #expect(ThemeName.candidatePaths(for: value, userThemesDirectory: "/u", bundledThemesDirectory: "/b").isEmpty)
    }

    @Test func homeRelativeThemeIsExpanded() {
        #expect(ThemeName.expandingHome("~/themes/my-light", home: "/Users/me") == "/Users/me/themes/my-light")
    }

    @Test(arguments: ["~", "~me/themes/x", "/abs/~/x", "My Light", "themes/~/x"])
    func onlyALeadingTildeSlashIsExpanded(value: String) {
        #expect(ThemeName.expandingHome(value, home: "/Users/me") == value)
    }

    @Test func eachAppearanceSideOfAHomeRelativeThemeResolvesToItsFile() {
        let value = "light:~/themes/day,dark:~/themes/night"
        func candidates(isDark: Bool) -> [String] {
            let side = ThemeName.expandingHome(ThemeName.resolved(from: value, isDark: isDark), home: "/Users/me")
            return ThemeName.candidatePaths(for: side, userThemesDirectory: "/u", bundledThemesDirectory: "/b")
        }
        #expect(candidates(isDark: false) == ["/Users/me/themes/day"])
        #expect(candidates(isDark: true) == ["/Users/me/themes/night"])
    }

    @Test func quotedAppearanceSidesAreUnquoted() {
        let value = "light:\"~/themes/my day\",dark:\"Gruvbox Dark Hard\""
        #expect(ThemeName.resolved(from: value, isDark: false) == "~/themes/my day")
        #expect(ThemeName.resolved(from: value, isDark: true) == "Gruvbox Dark Hard")
    }

    @Test func userThemesDirectoryFollowsXDGConfigHome() {
        let dir = ThemeName.userThemesDirectory(environment: ["XDG_CONFIG_HOME": "/xdg"], home: "/Users/me")
        #expect(dir == "/xdg/ghostty/themes")
    }

    @Test(arguments: [[:], ["XDG_CONFIG_HOME": ""]])
    func userThemesDirectoryDefaultsToHomeConfig(environment: [String: String]) {
        #expect(ThemeName.userThemesDirectory(environment: environment, home: "/Users/me") == "/Users/me/.config/ghostty/themes")
    }
}
