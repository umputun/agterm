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

    @Test func aTableIsFramedWithAPaddedGridAndABoldHeader() {
        let source = "| task | state |\n|---|---|\n| build | ok |\n| lint **x** | running |"
        let lines = HudMarkdown.lines(source)

        #expect(plain(source) == [
            "┌────────┬─────────┐",
            "│ task   │ state   │",
            "├────────┼─────────┤",
            "│ build  │ ok      │",
            "│ lint x │ running │",
            "└────────┴─────────┘"
        ])
        #expect(lines[1].runs.filter { $0.text.contains(where: \.isLetter) }.allSatisfy { $0.style.contains(.bold) })
        #expect(lines[1].runs.filter { $0.text.contains("│") }.allSatisfy { $0.style.isEmpty })
        #expect(lines[4].runs.contains(HudMarkdown.Run(text: "x", style: .bold)))
        #expect(Set(lines.map { HudMarkdown.width($0.runs) }).count == 1)
    }

    @Test func anAllEmptyHeaderLeavesNoHeaderRule() {
        #expect(plain("|  |  |\n|---|---|\n| 1 | 2 |") == ["┌───┬───┐", "│ 1 │ 2 │", "└───┴───┘"])
    }

    @Test func aTableOpeningAListItemCarriesTheMarkerOnItsTopBorder() {
        #expect(plain("- | a | b |\n  |---|---|\n  | 1 | 2 |")
            == ["• ┌───┬───┐", "  │ a │ b │", "  ├───┼───┤", "  │ 1 │ 2 │", "  └───┴───┘"])
    }

    @Test func aTableAfterTextInAListItemHangsUnderIt() {
        #expect(plain("- intro\n\n  | a |\n  |---|\n  | 1 |")
            == ["• intro", "  ┌───┐", "  │ a │", "  ├───┤", "  │ 1 │", "  └───┘"])
    }

    @Test func aQuotedTableCarriesTheBarOnEveryFrameRow() {
        #expect(plain("> | a |\n> |---|\n> | 1 |") == ["│ ┌───┐", "│ │ a │", "│ ├───┤", "│ │ 1 │", "│ └───┘"])
    }

    @Test func aFrameWiderThanThePanelEndsInTheEllipsis() {
        let rows = HudMarkdown.rows(HudMarkdown.lines("| alpha | beta |\n|---|---|\n| 1 | 2 |"), width: 60)

        let clipped = HudMarkdown.fitted(rows, columns: 6, rows: 10).map { $0.map(\.text).joined() }

        #expect(clipped.first == "┌────…")
        #expect(clipped.allSatisfy { HudLayout.cellCount($0) == 6 })
    }

    // foundation emits no run for an empty cell or an all-empty row, which shifted later cells left.
    @Test func emptyCellsAndRowsKeepTheirPlace() {
        let source = "| a | b | c |\n|---|---|---|\n|  | x | y |\n| p |  | r |\n| s | t |  |\n|  |  |  |\n| u | v | w |"

        #expect(plain(source) == [
            "┌───┬───┬───┐", "│ a │ b │ c │", "├───┼───┼───┤", "│   │ x │ y │", "│ p │   │ r │", "│ s │ t │   │",
            "│   │   │   │", "│ u │ v │ w │", "└───┴───┴───┘"
        ])
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

    private func laidOut(_ source: String, width: Int) -> [String] {
        HudMarkdown.rows(HudMarkdown.lines(source), width: width).map { $0.map(\.text).joined() }
    }

    private let esc = "\u{1B}["

    @Test func wrappingBreaksAtSpacesAcrossStyleRuns() {
        let rows = HudMarkdown.rows(HudMarkdown.lines("aa **bb** cc"), width: 5)

        #expect(rows.map { $0.map(\.text).joined() } == ["aa bb", "cc"])
        #expect(rows[0] == [HudMarkdown.Run(text: "aa ", style: []), HudMarkdown.Run(text: "bb", style: .bold)])
    }

    @Test func aWordSpanningStyleRunsStaysOneWord() {
        let rows = HudMarkdown.rows(HudMarkdown.lines("pre**fix**suffix tail"), width: 12)

        #expect(rows.map { $0.map(\.text).joined() } == ["prefixsuffix", "tail"])
        #expect(rows[0][1] == HudMarkdown.Run(text: "fix", style: .bold))
    }

    // wrapping collapsed every run of spaces, rewriting code spans and raw HTML even on a row wide enough.
    @Test func literalSpacingSurvivesAWideRow() {
        #expect(laidOut("run `echo \"a  b\"` now", width: 60) == ["run echo \"a  b\" now"])
        #expect(laidOut("<div title=\"a  b\">\n    indented\n</div>", width: 60)
            == ["<div title=\"a  b\">", "    indented", "</div>"])
    }

    @Test func literalSpacingSurvivesWrappingAndIsDroppedOnlyAtTheBreak() {
        #expect(laidOut("`a  b  c`", width: 4) == ["a  b", "c"])
    }

    @Test func aWordLongerThanTheRowIsSplit() {
        #expect(laidOut("abcdefghij", width: 4) == ["abcd", "efgh", "ij"])
    }

    @Test func listContinuationsHangUnderTheItemText() {
        #expect(laidOut("- one two three", width: 9) == ["• one two", "  three"])
        #expect(laidOut("10. alpha beta", width: 12) == ["10. alpha", "    beta"])
    }

    @Test func codeWrapsAtTheWidthKeepingItsSpaces() {
        #expect(laidOut("```\n    a b\n```", width: 6) == ["      ", "  a b"])
    }

    @Test func aRuleSpansTheWidestOtherRowAndATableNeverWraps() {
        #expect(laidOut("---", width: 60) == ["───"])
        #expect(laidOut("> ---", width: 60) == ["│ ───"])
        #expect(laidOut("a heading of sorts\n\n---", width: 60) == ["a heading of sorts", "", String(repeating: "─", count: 18)])
        #expect(laidOut("a heading of sorts\n\n---", width: 6).last == "──────")
        #expect(laidOut("| long header | other |\n|---|---|\n| x | y |", width: 6) == [
            "┌─────────────┬───────┐", "│ long header │ other │", "├─────────────┼───────┤", "│ x           │ y     │",
            "└─────────────┴───────┘"
        ])
    }

    @Test func aHeadingWithAnInnerStrongSpanEncodesAsOneBoldRun() {
        let rows = HudMarkdown.rows(HudMarkdown.lines("# **x** y"), width: 20)

        #expect(HudMarkdown.sgr(rows[0]) == "\(esc)1mx y\(esc)22m")
    }

    @Test func sgrEmitsOnlyTheCodesAChangeNeeds() {
        let bold = HudMarkdown.Run(text: "a", style: .bold)
        let italic = HudMarkdown.Run(text: "b", style: .italic)
        let both = HudMarkdown.Run(text: "c", style: [.italic, .strikethrough])

        #expect(HudMarkdown.sgr([bold, italic, both]) == "\(esc)1ma\(esc)22;3mb\(esc)9mc\(esc)23;29m")
        #expect(HudMarkdown.sgr([HudMarkdown.Run(text: "plain", style: [])]) == "plain")
    }

    @Test func droppingBoldReopensDimBecause22ClosesBoth() {
        let row = [HudMarkdown.Run(text: "a", style: [.bold, .dim]), HudMarkdown.Run(text: "b", style: .dim)]

        #expect(HudMarkdown.sgr(row) == "\(esc)1;2ma\(esc)22;2mb\(esc)22m")
    }

    @Test func sgrNeverResetsTheTextColor() {
        let rows = HudMarkdown.rows(HudMarkdown.lines("# t\n\n**b** *i* ~~s~~\n\n| h |\n|---|\n| c |"), width: 30)

        #expect(!rows.map(HudMarkdown.sgr).joined().contains("\(esc)0m"))
        #expect(!rows.map(HudMarkdown.sgr).joined().contains("\(esc)m"))
    }

    @Test func aTooWideRowEndsInAnEllipsisAndClosesItsStyleFirst() {
        let row = [HudMarkdown.Run(text: "ab", style: .bold), HudMarkdown.Run(text: "cdef", style: [])]

        let clipped = HudMarkdown.clipped(row, columns: 3)

        #expect(clipped == [HudMarkdown.Run(text: "ab", style: .bold), HudMarkdown.Run(text: "…", style: [])])
        #expect(HudMarkdown.sgr(clipped) == "\(esc)1mab\(esc)22m…")
        #expect(HudMarkdown.clipped(row, columns: 6) == row)
    }

    @Test func overflowingRowsEndInACountOfEveryHiddenRow() {
        let rows = (1...10).map { [HudMarkdown.Run(text: "row \($0)", style: [])] }

        let fitted = HudMarkdown.fitted(rows, columns: 20, rows: 5)

        #expect(fitted.count == 5)
        #expect(fitted.last == [HudMarkdown.Run(text: "… 6 more", style: .dim)])
        #expect(fitted.prefix(4).map { $0[0].text } == ["row 1", "row 2", "row 3", "row 4"])
    }

    @Test func theOverflowMarkerIsClippedLikeAnyRow() {
        let rows = (1...10).map { [HudMarkdown.Run(text: "row \($0)", style: [])] }

        let fitted = HudMarkdown.fitted(rows, columns: 4, rows: 2)

        #expect(fitted.map { $0.map(\.text).joined() } == ["row…", "… 9…"])
    }

    @Test func tinyBudgetsNeverPaintOutsideThem() {
        let rows = [[HudMarkdown.Run(text: "abc", style: [])], [HudMarkdown.Run(text: "def", style: [])]]

        #expect(HudMarkdown.fitted(rows, columns: 0, rows: 5).isEmpty)
        #expect(HudMarkdown.fitted(rows, columns: 5, rows: 0).isEmpty)
        #expect(HudMarkdown.fitted(rows, columns: 5, rows: 1) == [[HudMarkdown.Run(text: "… 2 more", style: .dim)]]
            .map { HudMarkdown.clipped($0, columns: 5) })
        #expect(HudMarkdown.fitted(rows, columns: 1, rows: 5).map { $0.map(\.text).joined() } == ["…", "…"])
    }
}
