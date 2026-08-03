import Foundation
import Testing
@testable import agtermCore

struct HudTests {
    @Test func shortMessageBoxIsContentPlusPadding() {
        let box = HudLayout.box(for: HudSpec(message: "gathering options"))

        #expect(box.columns == 17 + HudLayout.horizontalPadding * 2)
        #expect(box.rows == 1 + HudLayout.verticalPadding * 2)
    }

    @Test func emptyMessageStillProducesAOneRowBox() {
        let box = HudLayout.box(for: HudSpec(message: ""))

        #expect(box.columns == 1 + HudLayout.horizontalPadding * 2)
        #expect(box.rows == 1 + HudLayout.verticalPadding * 2)
        #expect(HudLayout.renderedBody(for: HudSpec(message: "")).isEmpty)
    }

    @Test func longSingleWordIsBrokenAtMaxColumns() {
        let word = String(repeating: "x", count: 130)

        let lines = HudLayout.wrap(word, columns: HudLayout.maxColumns)
        let box = HudLayout.box(for: HudSpec(message: word))

        #expect(lines == [String(repeating: "x", count: 60), String(repeating: "x", count: 60),
                          String(repeating: "x", count: 10)])
        #expect(box.columns == HudLayout.maxColumns + HudLayout.horizontalPadding * 2)
        #expect(box.rows == 3 + HudLayout.verticalPadding * 2)
    }

    @Test func wordWrapKeepsWordsWholeUpToMaxColumns() {
        let message = Array(repeating: "word", count: 20).joined(separator: " ")

        let lines = HudLayout.wrap(message, columns: HudLayout.maxColumns)

        #expect(lines.count == 2)
        #expect(lines[0] == Array(repeating: "word", count: 12).joined(separator: " "))
        #expect(lines[1] == Array(repeating: "word", count: 8).joined(separator: " "))
        #expect(lines.allSatisfy { $0.count <= HudLayout.maxColumns })
    }

    @Test func detailFollowsMessageAfterASingleEmptyLine() {
        let spec = HudSpec(message: "gathering options", detail: "scanning 4 repositories")

        let body = HudLayout.renderedBody(for: spec)
        let box = HudLayout.box(for: spec)

        #expect(body == "gathering options\n\nscanning 4 repositories\n")
        #expect(box.columns == 23 + HudLayout.horizontalPadding * 2)
        #expect(box.rows == 3 + HudLayout.verticalPadding * 2)
    }

    @Test func emptyDetailAddsNoSeparator() {
        let body = HudLayout.renderedBody(for: HudSpec(message: "working", detail: "   "))

        #expect(body == "working\n")
    }

    @Test func embeddedNewlinesBecomeHardBreaksWithNoBlankLines() {
        let spec = HudSpec(message: "one\n\ntwo three", detail: "four\nfive")

        #expect(HudLayout.bodyLines(for: spec) == ["one", "two three", "", "four", "five"])
        #expect(HudLayout.box(for: spec).rows == 5 + HudLayout.verticalPadding * 2)
    }

    @Test func spinnerWidensTheBoxWithoutRewrapping() {
        let plain = HudLayout.box(for: HudSpec(message: "hi"))
        let spinning = HudLayout.box(for: HudSpec(message: "hi", spinner: true))

        #expect(spinning.columns == plain.columns + HudLayout.spinnerWidth)
        #expect(spinning.rows == plain.rows)
    }

    @Test func sizePercentTakesTheLargerOfWidthAndHeightNeed() {
        let pane = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 1200, paneHeight: 800)

        #expect(HudLayout.sizePercent(box: (columns: 22, rows: 3), pane: pane) == 15)
    }

    @Test func sizePercentClampsASmallBoxToTheMinimum() {
        let pane = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 2000, paneHeight: 1000)

        #expect(HudLayout.sizePercent(box: (columns: 6, rows: 3), pane: pane) == HudLayout.minSizePercent)
    }

    @Test func sizePercentClampsAHugeMessageToTheMaximum() {
        let pane = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 1200, paneHeight: 800)
        let spec = HudSpec(message: Array(repeating: "word", count: 600).joined(separator: " "))

        #expect(HudLayout.sizePercent(box: HudLayout.box(for: spec), pane: pane) == HudLayout.maxSizePercent)
    }

    @Test func unmeasuredPaneResolvesToTheMaximum() {
        let pane = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 0, paneHeight: 0)

        #expect(HudLayout.sizePercent(box: (columns: 10, rows: 3), pane: pane) == HudLayout.maxSizePercent)
    }

    @Test func omittedPositionAndSpinnerDecodeToTheirDefaults() throws {
        let json = Data(#"{"message":"working"}"#.utf8)

        let spec = try JSONDecoder().decode(HudSpec.self, from: json)

        #expect(spec.message == "working")
        #expect(spec.position == .center)
        #expect(!spec.spinner)
        #expect(spec.detail == nil)
        #expect(spec.backgroundColor == nil)
        #expect(spec.sizePercent == nil)
    }

    @Test(arguments: HudPosition.allCases) func everyPositionRoundTrips(position: HudPosition) throws {
        let spec = HudSpec(message: "working", detail: "soon", spinner: true,
                           backgroundColor: "#112233", sizePercent: 40, position: position)

        let decoded = try JSONDecoder().decode(HudSpec.self, from: JSONEncoder().encode(spec))

        #expect(decoded == spec)
        #expect(decoded.position == position)
    }

    @Test func positionNamesDeriveFromTheCases() {
        #expect(HudPosition.validNamesList == "top|center|bottom")
        #expect(HudPosition.validNamesPhrase == "top, center, bottom")
    }

    @Test func edgeMarginLeavesRoomForTheLargestPanel() {
        #expect(HudPosition.edgeMarginPercent * 2 + HudLayout.maxSizePercent <= 100)
    }
}
