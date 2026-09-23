import Foundation
import Testing
@testable import agtermCore

struct HudMarkdownTests {
    private func plain(_ source: String) -> [String] {
        HudMarkdown.lines(source).map { line in
            line.kind == .rule ? line.lead + "<rule>" : line.lead + line.runs.map(\.text).joined()
        }
    }

    private func styled(_ source: String) -> [[HudMarkdown.Run]] {
        HudMarkdown.lines(source).map(\.runs)
    }

    @Test func aSoftBreakJoinsWithASpaceAndAHardBreakStartsARow() {
        #expect(plain("one\ntwo") == ["one two"])
        #expect(plain("one  \ntwo") == ["one", "two"])
        #expect(plain("one\\\ntwo") == ["one", "two"])
    }

    @Test func paragraphsAreSeparatedByOneBlankRowWhateverTheSourceHad() {
        #expect(plain("a\n\nb\n\n\n\nc") == ["a", "", "b", "", "c"])
    }

    @Test(arguments: 1...6) func everyHeadingLevelIsBold(level: Int) {
        let lines = HudMarkdown.lines(String(repeating: "#", count: level) + " Tasks")

        #expect(lines.count == 1)
        #expect(lines[0].runs == [HudMarkdown.Run(text: "Tasks", style: .bold)])
    }

    @Test func aHeadingKeepsItsBoldAfterAnInnerStrongSpan() {
        #expect(styled("# **x** y") == [[HudMarkdown.Run(text: "x", style: .bold),
                                         HudMarkdown.Run(text: " y", style: .bold)]])
    }

    @Test func unorderedItemsGetABulletAndHangTheirContinuation() {
        let lines = HudMarkdown.lines("- build\n- test")

        #expect(lines.map(\.lead) == ["• ", "• "])
        #expect(lines.map(\.hang) == ["  ", "  "])
        #expect(plain("- build\n- test") == ["• build", "• test"])
    }

    @Test func orderedItemsKeepTheirOrdinalAndHangByItsWidth() {
        let lines = HudMarkdown.lines("9. nine\n10. ten")

        #expect(lines.map(\.lead) == ["9. ", "10. "])
        #expect(lines.map(\.hang) == ["   ", "    "])
    }

    @Test func aNestedListIndentsUnderItsParentsText() {
        #expect(plain("- parent\n  - child\n    - grandchild") == ["• parent", "  • child", "    • grandchild"])
    }

    @Test func tightAndLooseListsRenderAlike() {
        #expect(plain("- a\n- b") == ["• a", "• b"])
        #expect(plain("- a\n\n- b") == ["• a", "• b"])
    }

    @Test func aListIsSeparatedFromTheParagraphAroundIt() {
        #expect(plain("status\n\n- a\n- b\n\ndone") == ["status", "", "• a", "• b", "", "done"])
    }

    @Test func aTaskCheckboxStaysLiteralText() {
        #expect(plain("- [ ] queued\n- [x] done") == ["• [ ] queued", "• [x] done"])
    }

    @Test func aCodeBlockKeepsItsLinesVerbatimAndIndented() {
        let lines = HudMarkdown.lines("```\n# not a heading\n- not a bullet\n**not bold**\n\n\tx\n```")

        #expect(lines.map { $0.lead + $0.runs.map(\.text).joined() }
            == ["  # not a heading", "  - not a bullet", "  **not bold**", "  ", "      x"])
        #expect(lines.allSatisfy { $0.runs.allSatisfy { $0.style.isEmpty } })
    }

    @Test func tabsExpandToTheNextStop() {
        #expect(HudMarkdown.expandTabs("a\tb") == "a   b")
        #expect(HudMarkdown.expandTabs("abcd\te") == "abcd    e")
    }

    @Test func aBlockQuotePrefixesEveryRow() {
        #expect(plain("> first  \n> second") == ["│ first", "│ second"])
    }

    @Test func aThematicBreakIsARuleRow() {
        let lines = HudMarkdown.lines("above\n\n---\n\nbelow")

        #expect(lines.map(\.kind) == [.text, .text, .rule, .text, .text])
    }

    @Test func aTablePadsItsColumnsAndBoldsTheHeader() {
        let lines = HudMarkdown.lines("| task | state |\n|---|---|\n| build | ok |\n| lint **x** | running |")

        #expect(plain("| task | state |\n|---|---|\n| build | ok |\n| lint **x** | running |")
            == ["task   │ state", "build  │ ok", "lint x │ running"])
        #expect(lines[0].runs.filter { !$0.text.allSatisfy { $0 == " " } && $0.text != " │ " }
            .allSatisfy { $0.style.contains(.bold) })
        #expect(lines[2].runs.contains(HudMarkdown.Run(text: "x", style: .bold)))
    }

    // foundation emits no run for an empty cell or an all-empty row, which shifted later cells left.
    @Test func emptyCellsAndRowsKeepTheirPlace() {
        let source = "| a | b | c |\n|---|---|---|\n|  | x | y |\n| p |  | r |\n| s | t |  |\n|  |  |  |\n| u | v | w |"

        #expect(plain(source) == ["a │ b │ c", "  │ x │ y", "p │   │ r", "s │ t │ ", "  │   │ ", "u │ v │ w"])
    }

    @Test func anImageShowsItsAltTextAndHtmlStaysLiteral() {
        #expect(plain("![diagram](d.png) <b>hi</b>") == ["diagram <b>hi</b>"])
        #expect(plain("<!-- note -->") == ["<!-- note -->"])
    }

    @Test func inlineStylesMapOntoRunStyles() {
        #expect(styled("**b** *i* ~~s~~ `c` [label](http://x)") == [[
            HudMarkdown.Run(text: "b", style: .bold), HudMarkdown.Run(text: " ", style: []),
            HudMarkdown.Run(text: "i", style: .italic), HudMarkdown.Run(text: " ", style: []),
            HudMarkdown.Run(text: "s", style: .strikethrough), HudMarkdown.Run(text: " ", style: []),
            HudMarkdown.Run(text: "c", style: []), HudMarkdown.Run(text: " ", style: []),
            HudMarkdown.Run(text: "label", style: [])
        ]])
    }

    @Test func strongInsideEmphasisCarriesBoth() {
        #expect(styled("*a **b***").first?.last == HudMarkdown.Run(text: "b", style: [.bold, .italic]))
    }

    @Test func decodedControlCharactersAreNeutralized() {
        #expect(plain("x &#27;[31m y") == ["x \u{FFFD}[31m y"])
        #expect(plain("a&#10;b") == ["a\u{FFFD}b"])
        #expect(plain("a&#9;b") == ["a b"])
    }

    @Test func hardBreaksAndCodeNewlinesSurviveNeutralization() {
        #expect(plain("a  \nb\n\n```\nc\nd\n```") == ["a", "b", "", "  c", "  d"])
    }
}
