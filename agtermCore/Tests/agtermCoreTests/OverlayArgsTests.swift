import Foundation
import Testing
@testable import agtermCore

struct OverlayArgsTests {
    // MARK: - parseSize

    @Test func sizeUnspecifiedWhenNothingSet() {
        let result = OverlayArgs.parseSize(sizePercent: nil, cols: nil, rows: nil, full: false, command: .open)
        #expect(result == .unspecified)
    }

    @Test func sizeResolvesPercent() {
        let result = OverlayArgs.parseSize(sizePercent: 50, cols: nil, rows: nil, full: false, command: .open)
        #expect(result == .size(.percent(50)))
    }

    @Test func sizeResolvesCells() {
        let result = OverlayArgs.parseSize(sizePercent: nil, cols: 40, rows: 12, full: false, command: .open)
        #expect(result == .size(.cells(cols: 40, rows: 12)))
    }

    @Test func sizeResolvesFullWhenAllowed() {
        let result = OverlayArgs.parseSize(sizePercent: nil, cols: nil, rows: nil, full: true, command: .resize)
        #expect(result == .size(.full))
    }

    @Test func sizeIgnoresFullWhenNotAllowed() {
        // open has no --full, so a stray full flag is treated as no size = unspecified (open → full-pane).
        let result = OverlayArgs.parseSize(sizePercent: nil, cols: nil, rows: nil, full: true, command: .open)
        #expect(result == .unspecified)
    }

    @Test func sizeRejectsMultipleModesOpen() {
        let result = OverlayArgs.parseSize(sizePercent: 50, cols: 40, rows: 12, full: false, command: .open)
        #expect(result == .invalid("session.overlay.open: use only one of --size-percent or --cols/--rows"))
    }

    @Test func sizeRejectsMultipleModesResize() {
        let result = OverlayArgs.parseSize(sizePercent: 50, cols: nil, rows: nil, full: true, command: .resize)
        #expect(result == .invalid("session.overlay.resize: use only one of --full, --size-percent, or --cols/--rows"))
    }

    @Test func sizeRejectsPercentOutOfRange() {
        let high = OverlayArgs.parseSize(sizePercent: 150, cols: nil, rows: nil, full: false, command: .open)
        #expect(high == .invalid("session.overlay.open: --size-percent must be 1...100"))
        let low = OverlayArgs.parseSize(sizePercent: 0, cols: nil, rows: nil, full: false, command: .resize)
        #expect(low == .invalid("session.overlay.resize: --size-percent must be 1...100"))
    }

    @Test func sizeRejectsColsWithoutRows() {
        let colsOnly = OverlayArgs.parseSize(sizePercent: nil, cols: 40, rows: nil, full: false, command: .open)
        #expect(colsOnly == .invalid("provide both --cols and --rows"))
        let rowsOnly = OverlayArgs.parseSize(sizePercent: nil, cols: nil, rows: 12, full: false, command: .open)
        #expect(rowsOnly == .invalid("provide both --cols and --rows"))
    }

    @Test func sizeRejectsNonPositiveCells() {
        let result = OverlayArgs.parseSize(sizePercent: nil, cols: 0, rows: 12, full: false, command: .open)
        #expect(result == .invalid("--cols and --rows must be >= 1"))
    }

    // MARK: - parseAnchor

    @Test func anchorAbsentWhenNil() {
        #expect(OverlayArgs.parseAnchor(nil) == .absent)
    }

    @Test func anchorResolvesEachValidValue() {
        for anchor in OverlayAnchor.allCases {
            #expect(OverlayArgs.parseAnchor(anchor.rawValue) == .anchor(anchor))
        }
    }

    @Test func anchorRejectsUnknownWithNinePositions() {
        let result = OverlayArgs.parseAnchor("middle")
        #expect(result == .invalid("unknown anchor: middle (top-left|top|top-right|left|center|right|bottom-left|bottom|bottom-right)"))
    }
}
