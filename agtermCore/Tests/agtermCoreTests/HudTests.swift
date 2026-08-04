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
        #expect(HudLayout.renderedBody(for: HudSpec(message: ""), grid: box, ownerPid: 4242) == "5 3 0 4242\n")
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

        let box = HudLayout.box(for: spec)
        let body = HudLayout.renderedBody(for: spec, grid: box, ownerPid: 4242)

        #expect(body == "27 5 0 4242\ngathering options\n\nscanning 4 repositories\n")
        #expect(box.columns == 23 + HudLayout.horizontalPadding * 2)
        #expect(box.rows == 3 + HudLayout.verticalPadding * 2)
    }

    @Test func emptyDetailAddsNoSeparator() {
        let spec = HudSpec(message: "working", detail: "   ")
        let body = HudLayout.renderedBody(for: spec, grid: HudLayout.box(for: spec), ownerPid: 4242)

        #expect(body == "11 3 0 4242\nworking\n")
    }

    // the header is the whole reason `session.hud.update` can grow the panel or start the spinner without
    // re-spawning the helper, which reads its environment once and would keep the grid it started with. The
    // pid is the helper's second stop, for the teardown a hard-killed app never runs.
    @Test func theHeaderCarriesTheGridTheSpinnerFlagAndTheOwningPid() {
        let spec = HudSpec(message: "working", spinner: true)

        let body = HudLayout.renderedBody(for: spec, grid: (columns: 30, rows: 9), ownerPid: 4242)

        #expect(body == "30 9 1 4242\nworking\n")
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

        // width-dominant: 22 cells = 176pt of 1200 = 15%, against 3 rows = 54pt of 800 = 7%
        #expect(HudLayout.sizePercent(box: (columns: 22, rows: 3), pane: pane) == 15)
        // height-dominant in a wide, short pane: 20 rows = 360pt of 800 = 45%, against 22 cells = 15%
        #expect(HudLayout.sizePercent(box: (columns: 22, rows: 20), pane: pane) == 45)
    }

    @Test func aCallerOverrideIsBoundedByTheSameClampTheMeasurementTakes() {
        #expect(HudLayout.clampSizePercent(100) == HudLayout.maxSizePercent)
        #expect(HudLayout.clampSizePercent(1) == HudLayout.minSizePercent)
        #expect(HudLayout.clampSizePercent(40) == 40)
        #expect(HudLayout.clampSizePercent(HudLayout.maxSizePercent) == HudLayout.maxSizePercent)
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

    // ONE percent sizes both pane dimensions, so the panel matches the content box only in the dimension
    // that drove it: centering on the box strands the message toward the panel's top-left corner.
    @Test func theHeaderCarriesThePanelsOwnGridNotTheContentBox() {
        let pane = PaneMetrics(cellWidth: 7.8, cellHeight: 15, paneWidth: 1000, paneHeight: 700,
                               paddingWidth: 8, paddingHeight: 6)
        let spec = HudSpec(message: "gathering options…")
        let box = HudLayout.box(for: spec)
        let size = HudLayout.sizePercent(box: box, pane: pane)

        let grid = HudLayout.paintGrid(for: spec, sizePercent: size, pane: pane)

        // the frame the panel is actually given: the same percent of each pane dimension, less the padding
        #expect(size == 18)
        #expect(grid.columns == Int((pane.paneWidth * 0.18 - 16) / 7.8))
        #expect(grid.rows == Int((pane.paneHeight * 0.18 - 12) / 15))
        #expect(grid.columns == 21)
        #expect(grid.rows == 7)
        #expect(box.columns == 22)
        #expect(box.rows == 3, "the box is width-dominant here, so its rows are not the panel's")
        #expect(HudLayout.renderedBody(for: spec, grid: grid, ownerPid: 4242).hasPrefix("21 7 0 4242\n"))

        // what the helper does with each: the panel grid leaves 3 rows above one line and 3 below, while the
        // box left 1 above and 5 below — the message sat three rows high in a panel it filled a third of
        let lines = HudLayout.bodyLines(for: spec).count
        #expect((grid.rows - lines) / 2 == 3)
        #expect((box.rows - lines) / 2 == 1)
    }

    // a caller's percent skips the message measurement entirely, so the box says nothing at all about the
    // panel it opens: 80% of this pane is 100 columns by 36 rows around a two-word message.
    @Test func aCallerOverrideGridComesFromThePanelNotTheMessage() {
        let pane = PaneMetrics(cellWidth: 7.8, cellHeight: 15, paneWidth: 1000, paneHeight: 700,
                               paddingWidth: 8, paddingHeight: 6)
        let spec = HudSpec(message: "ok", sizePercent: HudLayout.maxSizePercent)

        let grid = HudLayout.paintGrid(for: spec, sizePercent: HudLayout.maxSizePercent, pane: pane)

        #expect(grid.columns == 100)
        #expect(grid.rows == 36)
        #expect(HudLayout.box(for: spec).columns == 6)
        #expect(HudLayout.box(for: spec).rows == 3)
    }

    // a HUD opened over a session with nothing laid out has no panel grid to compute, and the box is the
    // only grid there is.
    @Test func paintGridFallsBackToTheBoxWithoutAMeasuredPane() {
        let spec = HudSpec(message: "working")
        let unmeasured = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 0, paneHeight: 0)
        let noCell = PaneMetrics(cellWidth: 0, cellHeight: 0, paneWidth: 1000, paneHeight: 700)

        #expect(HudLayout.panelGrid(sizePercent: 40, pane: unmeasured) == nil)
        #expect(HudLayout.panelGrid(sizePercent: 40, pane: noCell) == nil)
        #expect(HudLayout.paintGrid(for: spec, sizePercent: 80, pane: unmeasured).columns
            == HudLayout.box(for: spec).columns)
        #expect(HudLayout.paintGrid(for: spec, sizePercent: 80, pane: unmeasured).rows
            == HudLayout.box(for: spec).rows)
        // a pane smaller than its own padding leaves no cells either, rather than a zero or negative grid
        let tiny = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 30, paneHeight: 30,
                               paddingWidth: 8, paddingHeight: 6)
        #expect(HudLayout.panelGrid(sizePercent: 40, pane: tiny) == nil)
    }

    // the helper counts `${#line}` in code points under the UTF-8 locale it forces; `String.count` counts
    // grapheme clusters, which disagree on every combining mark. macOS hands paths back decomposed, so the
    // text is precomposed first and what is left measures the same on both sides.
    @Test func widthIsCountedInTheUnitTheHelperCounts() {
        let decomposed = "cafe\u{0301} au lait"

        let lines = HudLayout.bodyLines(for: HudSpec(message: decomposed))

        #expect(lines.count == 1)
        #expect(lines[0].unicodeScalars.count == 12, "the bytes written must be precomposed, not NFD")
        #expect(HudLayout.cellCount(lines[0]) == 12)
        #expect(HudLayout.box(for: HudSpec(message: decomposed)).columns
            == 12 + HudLayout.horizontalPadding * 2)
    }

    // a ZWJ sequence is ONE Character and FIVE code points; the box has to hold what the helper will count,
    // even though neither side knows it renders as two display columns.
    @Test func aZwjSequenceIsMeasuredInCodePointsNotClusters() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}"

        #expect(family.count == 1)
        #expect(HudLayout.cellCount(family) == 5)
        #expect(HudLayout.box(for: HudSpec(message: family)).columns == 5 + HudLayout.horizontalPadding * 2)
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
