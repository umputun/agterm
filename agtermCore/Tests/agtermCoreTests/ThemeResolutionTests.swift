import Foundation
import Testing
@testable import agtermCore

struct ThemeResolutionTests {
    @Test func plainThemeReturnedUnchanged() {
        #expect(ThemeResolution.activeThemeName("TokyoNight", isDark: false) == "TokyoNight")
        #expect(ThemeResolution.activeThemeName("TokyoNight", isDark: true) == "TokyoNight")
    }

    @Test func dualThemePicksBySide() {
        let raw = "light:TokyoNight Day,dark:TokyoNight Night"
        #expect(ThemeResolution.activeThemeName(raw, isDark: false) == "TokyoNight Day")
        #expect(ThemeResolution.activeThemeName(raw, isDark: true) == "TokyoNight Night")
    }

    @Test func dualThemeIsOrderIndependent() {
        let raw = "dark:TokyoNight Night,light:TokyoNight Day"
        #expect(ThemeResolution.activeThemeName(raw, isDark: false) == "TokyoNight Day")
        #expect(ThemeResolution.activeThemeName(raw, isDark: true) == "TokyoNight Night")
    }

    @Test func toleratesWhitespaceAroundTokens() {
        let raw = "light: Catppuccin Latte , dark: Catppuccin Mocha "
        #expect(ThemeResolution.activeThemeName(raw, isDark: false) == "Catppuccin Latte")
        #expect(ThemeResolution.activeThemeName(raw, isDark: true) == "Catppuccin Mocha")
    }

    @Test func fallsBackToWhicheverSideIsPresent() {
        // only one side given: use it regardless of appearance.
        #expect(ThemeResolution.activeThemeName("light:Alabaster", isDark: true) == "Alabaster")
        #expect(ThemeResolution.activeThemeName("dark:Alabaster", isDark: false) == "Alabaster")
    }

    @Test func emptyStaysEmpty() {
        #expect(ThemeResolution.activeThemeName("", isDark: false) == "")
        #expect(ThemeResolution.activeThemeName("", isDark: true) == "")
    }

    @Test func componentsParsesSidesOrderIndependentWithWhitespace() {
        let ordered = ThemeResolution.components("light:TokyoNight Day,dark:TokyoNight Night")
        #expect(ordered.light == "TokyoNight Day")
        #expect(ordered.dark == "TokyoNight Night")
        let reversed = ThemeResolution.components(" dark: Catppuccin Mocha , light: Catppuccin Latte ")
        #expect(reversed.light == "Catppuccin Latte")
        #expect(reversed.dark == "Catppuccin Mocha")
    }

    @Test func componentsHalfSetPlainAndEmpty() {
        let half = ThemeResolution.components("light:Alabaster")
        #expect(half.light == "Alabaster")
        #expect(half.dark == nil)
        // a plain name has no sides; an empty side ("light:") reads as absent.
        let plain = ThemeResolution.components("Nord")
        #expect(plain.light == nil && plain.dark == nil)
        let empty = ThemeResolution.components("")
        #expect(empty.light == nil && empty.dark == nil)
        let blankSide = ThemeResolution.components("light:,dark:Nord")
        #expect(blankSide.light == nil)
        #expect(blankSide.dark == "Nord")
    }

    @Test func dualValueComposesCanonicalFormAndRoundTrips() {
        let value = ThemeResolution.dualValue(light: "Builtin Light", dark: "Nord")
        #expect(value == "light:Builtin Light,dark:Nord")
        let comps = ThemeResolution.components(value)
        #expect(comps.light == "Builtin Light")
        #expect(comps.dark == "Nord")
        #expect(ThemeResolution.activeThemeName(value, isDark: true) == "Nord")
        #expect(ThemeResolution.activeThemeName(value, isDark: false) == "Builtin Light")
    }

    @Test func isDualDetectsAnySidedFormOnly() {
        #expect(ThemeResolution.isDual("light:Alabaster,dark:Nord"))
        #expect(ThemeResolution.isDual("dark:Nord"))
        #expect(!ThemeResolution.isDual("Nord"))
        #expect(!ThemeResolution.isDual(""))
        // a comma without side prefixes is a plain (if odd) value, not the dual form.
        #expect(!ThemeResolution.isDual("Foo,Bar"))
    }
}
