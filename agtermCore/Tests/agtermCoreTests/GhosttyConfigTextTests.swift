import Foundation
import Testing
@testable import agtermCore

struct GhosttyConfigTextTests {
    private static func pairs(_ text: String) -> [String] {
        GhosttyConfigText.keyValues(in: text).map { "\($0.key)=\($0.value)" }
    }

    private static func hex(_ value: String) -> String? {
        value.hasPrefix("#") && value.count == 7 ? value : nil
    }

    @Test func keyValuesSkipsBlankAndCommentLinesAndTrimsAroundEquals() {
        let text = "# comment\n\n  theme  =  My Light  \nselection-background=#112233\nno equals here\n"
        #expect(Self.pairs(text) == ["theme=My Light", "selection-background=#112233"])
    }

    @Test(arguments: [
        ("theme = \"/Users/me/My Light\"", "/Users/me/My Light"),
        ("theme = \"\"", ""),
        ("theme = \"a\\\"b\"", "a\\\"b"),
        ("theme = \"half", "\"half"),
        ("theme = \"", "\""),
        ("theme = say \"hi\"", "say \"hi\""),
    ])
    func keyValuesStripsOnlyOneSurroundingQuotePair(line: String, value: String) {
        #expect(GhosttyConfigText.keyValues(in: line).map { $0.value } == [value])
    }

    @Test func lastSettingTakesTheLastValidValue() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-background = #111111\nselection-background = #222222")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .value("#222222"))
    }

    @Test func lastSettingKeepsAValidValueAnInvalidOneFollows() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-background = #111111\nselection-background = bogus")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .value("#111111"))
    }

    @Test func lastSettingTreatsAnEmptyValueAsReset() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-background = #111111\nselection-background =")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .reset)
    }

    @Test func lastSettingKeepsAResetAnInvalidValueFollows() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-background =\nselection-background = bogus")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .reset)
    }

    @Test func lastSettingIsUnsetWithoutAValidOrEmptyOccurrence() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-foreground = #111111\nselection-background = bogus")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .unset)
    }

    @Test(arguments: [
        (GhosttyConfigText.Setting<String>.value("#explicit"), GhosttyConfigText.Setting<String>.value("#theme"), String?("#explicit")),
        (.reset, .value("#theme"), nil),
        (.unset, .value("#theme"), "#theme"),
        (.unset, .reset, nil),
        (.unset, .unset, nil),
    ])
    func explicitSettingTakesPrecedenceOverTheTheme(explicit: GhosttyConfigText.Setting<String>,
                                                    theme: GhosttyConfigText.Setting<String>, expected: String?) {
        #expect(explicit.over(theme) == expected)
    }
}
