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
        #expect(HudLayout.renderedBody(for: HudSpec(message: ""), grid: box, ownerPid: 4242) == "5 3 0 4242 0.5\n")
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

        #expect(body == "27 5 0 4242 0.5\ngathering options\n\nscanning 4 repositories\n")
        #expect(box.columns == 23 + HudLayout.horizontalPadding * 2)
        #expect(box.rows == 3 + HudLayout.verticalPadding * 2)
    }

    @Test func emptyDetailAddsNoSeparator() {
        let spec = HudSpec(message: "working", detail: "   ")
        let body = HudLayout.renderedBody(for: spec, grid: HudLayout.box(for: spec), ownerPid: 4242)

        #expect(body == "11 3 0 4242 0.5\nworking\n")
    }

    // the header is the whole reason `session.hud.update` can grow the panel or start the spinner without
    // re-spawning the helper, which reads its environment once and would keep the grid it started with. The
    // pid is the helper's second stop, for the teardown a hard-killed app never runs.
    @Test func theHeaderCarriesTheGridTheSpinnerFlagAndTheOwningPid() {
        let spec = HudSpec(message: "working", spinner: .braille)

        let body = HudLayout.renderedBody(for: spec, grid: (columns: 30, rows: 9), ownerPid: 4242)

        #expect(body == "30 9 1 4242 0.08 ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏\nworking\n")
    }

    // the frames ride the header so the helper holds no table; a static panel sends none and only carries
    // the slower tick it re-reads the file at.
    @Test func aStaticPanelCarriesTheSlowIntervalAndNoFrames() {
        let body = HudLayout.renderedBody(for: HudSpec(message: "working"), grid: (columns: 30, rows: 9),
                                          ownerPid: 4242)

        #expect(body == "30 9 0 4242 0.5\nworking\n")
    }

    // the header is word-split by the helper and `HudLayout.spinnerWidth` reserves exactly two cells, so a
    // frame carrying a space would break the parse and a double-width glyph would overflow the panel.
    @Test(arguments: HudSpinner.allCases) func everyFrameIsOneSpacelessScalar(style: HudSpinner) {
        #expect(!style.frames.isEmpty)
        for frame in style.frames {
            #expect(HudLayout.cellCount(frame) == 1, "\(style.rawValue) frame \(frame.debugDescription)")
            #expect(!frame.contains(" "), "\(style.rawValue) frame \(frame.debugDescription) would split")
        }
        #expect(!style.interval.isEmpty)
        #expect(style.interval.allSatisfy { $0.isNumber || $0 == "." })
    }

    @Test func embeddedNewlinesBecomeHardBreaksWithNoBlankLines() {
        let spec = HudSpec(message: "one\n\ntwo three", detail: "four\nfive")

        #expect(HudLayout.bodyLines(for: spec) == ["one", "two three", "", "four", "five"])
        #expect(HudLayout.box(for: spec).rows == 5 + HudLayout.verticalPadding * 2)
    }

    @Test func spinnerWidensTheBoxWithoutRewrapping() {
        let plain = HudLayout.box(for: HudSpec(message: "hi"))
        let spinning = HudLayout.box(for: HudSpec(message: "hi", spinner: .braille))

        #expect(spinning.columns == plain.columns + HudLayout.spinnerWidth)
        #expect(spinning.rows == plain.rows)
    }

    @Test func eachAxisMeasuresItsOwnNeed() {
        let pane = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 1200, paneHeight: 800)

        // 22 cells = 176pt of 1200 = 15%, 3 rows = 54pt of 800 = 7%
        #expect(HudLayout.widthPercent(box: (columns: 22, rows: 3), pane: pane) == 15)
        #expect(HudLayout.heightPercent(box: (columns: 22, rows: 3), pane: pane) == 7)
        // 20 rows = 360pt of 800 = 45%, and the width is unmoved by it
        #expect(HudLayout.widthPercent(box: (columns: 22, rows: 20), pane: pane) == 15)
        #expect(HudLayout.heightPercent(box: (columns: 22, rows: 20), pane: pane) == 45)
    }

    // pins the square panel: one percent used to be the larger of the two needs, so a message wide enough
    // to want 71% of the pane took 71% of its HEIGHT too and left three lines of text in a vast empty box.
    @Test func aWideMessageDoesNotMakeATallPanel() {
        let pane = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 700, paneHeight: 800)
        let spec = HudSpec(message: "waiting on the package index — this can take a minute on a cold cache",
                           detail: "registry.example.org")
        let box = HudLayout.box(for: spec)

        #expect(HudLayout.widthPercent(box: box, pane: pane) == 71)
        #expect(HudLayout.heightPercent(box: box, pane: pane) == 14)
    }

    @Test func aCallerOverrideIsBoundedByTheSameClampTheMeasurementTakes() {
        #expect(HudLayout.clampSizePercent(100) == HudLayout.maxSizePercent)
        #expect(HudLayout.clampSizePercent(1) == HudLayout.minSizePercent)
        #expect(HudLayout.clampSizePercent(40) == 40)
        #expect(HudLayout.clampSizePercent(HudLayout.maxSizePercent) == HudLayout.maxSizePercent)
    }

    // the floor is a WIDTH rule — a panel narrower than this reads as a sliver — and applying it to the
    // height is what made a one-line message occupy a tenth of the pane.
    @Test func onlyTheWidthTakesTheMinimumFloor() {
        let pane = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 2000, paneHeight: 1000)

        #expect(HudLayout.widthPercent(box: (columns: 6, rows: 3), pane: pane) == HudLayout.minSizePercent)
        #expect(HudLayout.heightPercent(box: (columns: 6, rows: 3), pane: pane) == 6)
    }

    @Test func aHugeMessageGrowsTallAndIsCappedThere() {
        let pane = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 1200, paneHeight: 800)
        let spec = HudSpec(message: Array(repeating: "word", count: 600).joined(separator: " "))
        let box = HudLayout.box(for: spec)

        // it wraps at maxColumns, so the width settles well inside the cap while the rows run past it
        #expect(HudLayout.widthPercent(box: box, pane: pane) == 42)
        #expect(HudLayout.heightPercent(box: box, pane: pane) == HudLayout.maxSizePercent)
    }

    @Test func unmeasuredPaneWidensButDoesNotHeighten() {
        let pane = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 0, paneHeight: 0)

        #expect(HudLayout.widthPercent(box: (columns: 10, rows: 3), pane: pane) == HudLayout.maxSizePercent)
        #expect(HudLayout.heightPercent(box: (columns: 10, rows: 3), pane: pane) == HudLayout.minSizePercent)
    }

    // with both axes measured the panel comes out the size of its content, so the grid the helper centers
    // in and the content box agree and the message sits in the middle of a frame that fits it.
    @Test func theHeaderCarriesThePanelsOwnGrid() {
        let pane = PaneMetrics(cellWidth: 7.8, cellHeight: 15, paneWidth: 1000, paneHeight: 700,
                               paddingWidth: 8, paddingHeight: 6)
        let spec = HudSpec(message: "gathering options…")
        let box = HudLayout.box(for: spec)
        let width = HudLayout.widthPercent(box: box, pane: pane)
        let height = HudLayout.heightPercent(box: box, pane: pane)

        let grid = HudLayout.paintGrid(for: spec, size: HudPanelSize(widthPercent: width, heightPercent: height), pane: pane)

        #expect(width == 19)
        #expect(height == 9)
        #expect(grid.columns == Int((pane.paneWidth * 0.19 - 16) / 7.8))
        #expect(grid.rows == Int((pane.paneHeight * 0.09 - 12) / 15))
        #expect(grid.columns == 22)
        #expect(grid.rows == 3)
        #expect(box.columns == 22)
        #expect(box.rows == 3)
        #expect(HudLayout.renderedBody(for: spec, grid: grid, ownerPid: 4242).hasPrefix("22 3 0 4242 0.5\n"))

        // one line centered in three rows: one above, one below, and no empty half-panel under it
        #expect((grid.rows - HudLayout.bodyLines(for: spec).count) / 2 == 1)
    }

    // a caller's percent skips the message measurement on the WIDTH only, so the panel gets wide and stays
    // as tall as the two words in it.
    @Test func aCallerOverrideWidensThePanelWithoutHeighteningIt() {
        let pane = PaneMetrics(cellWidth: 7.8, cellHeight: 15, paneWidth: 1000, paneHeight: 700,
                               paddingWidth: 8, paddingHeight: 6)
        let spec = HudSpec(message: "ok", sizePercent: HudLayout.maxSizePercent)
        let size = HudLayout.panelSize(for: spec, pane: pane)

        let grid = HudLayout.paintGrid(for: spec, size: size, pane: pane)

        #expect(size.widthPercent == HudLayout.maxSizePercent, "the override reaches the width")
        #expect(size.heightPercent == 9, "and not the height, which is still the message's three rows")
        #expect(grid.columns == 100)
        #expect(grid.rows == 3)
        #expect(HudLayout.box(for: spec).columns == 6)
        #expect(HudLayout.box(for: spec).rows == 3)
    }

    // a HUD opened over a session with nothing laid out has no panel grid to compute, and the box is the
    // only grid there is.
    @Test func paintGridFallsBackToTheBoxWithoutAMeasuredPane() {
        let spec = HudSpec(message: "working")
        let unmeasured = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 0, paneHeight: 0)
        let noCell = PaneMetrics(cellWidth: 0, cellHeight: 0, paneWidth: 1000, paneHeight: 700)

        #expect(HudLayout.panelGrid(size: HudPanelSize(widthPercent: 40, heightPercent: 10), pane: unmeasured) == nil)
        #expect(HudLayout.panelGrid(size: HudPanelSize(widthPercent: 40, heightPercent: 10), pane: noCell) == nil)
        #expect(HudLayout.paintGrid(for: spec, size: HudPanelSize(widthPercent: 80, heightPercent: 10), pane: unmeasured).columns
            == HudLayout.box(for: spec).columns)
        #expect(HudLayout.paintGrid(for: spec, size: HudPanelSize(widthPercent: 80, heightPercent: 10), pane: unmeasured).rows
            == HudLayout.box(for: spec).rows)
        // a pane smaller than its own padding leaves no cells either, rather than a zero or negative grid
        let tiny = PaneMetrics(cellWidth: 8, cellHeight: 18, paneWidth: 30, paneHeight: 30,
                               paddingWidth: 8, paddingHeight: 6)
        #expect(HudLayout.panelGrid(size: HudPanelSize(widthPercent: 40, heightPercent: 40), pane: tiny) == nil)
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
        #expect(spec.spinner == nil)
        #expect(spec.detail == nil)
        #expect(spec.backgroundColor == nil)
        #expect(spec.sizePercent == nil)
    }

    @Test(arguments: HudPosition.allCases) func everyPositionRoundTrips(position: HudPosition) throws {
        let spec = HudSpec(message: "working", detail: "soon", spinner: .braille,
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
