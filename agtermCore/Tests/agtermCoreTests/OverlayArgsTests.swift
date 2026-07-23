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
        #expect(colsOnly == .invalid("session.overlay.open: provide both --cols and --rows"))
        let rowsOnly = OverlayArgs.parseSize(sizePercent: nil, cols: nil, rows: 12, full: false, command: .resize)
        #expect(rowsOnly == .invalid("session.overlay.resize: provide both --cols and --rows"))
    }

    @Test func sizeRejectsNonPositiveCells() {
        let result = OverlayArgs.parseSize(sizePercent: nil, cols: 0, rows: 12, full: false, command: .open)
        #expect(result == .invalid("session.overlay.open: --cols and --rows must be >= 1"))
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

    // MARK: - resolveOpen

    @Test func openResolvesFullCenterWhenNothingSet() {
        #expect(OverlayArgs.resolveOpen(sizePercent: nil, cols: nil, rows: nil, anchor: nil)
            == .resolved(size: .full, anchor: .center))
    }

    @Test func openResolvesPercentWithAnchor() {
        #expect(OverlayArgs.resolveOpen(sizePercent: 50, cols: nil, rows: nil, anchor: "bottom-right")
            == .resolved(size: .percent(50), anchor: .bottomRight))
    }

    @Test func openResolvesCellsWithAnchor() {
        #expect(OverlayArgs.resolveOpen(sizePercent: nil, cols: 40, rows: 12, anchor: "top-left")
            == .resolved(size: .cells(cols: 40, rows: 12), anchor: .topLeft))
    }

    @Test func openRejectsAnchorWithoutFloating() {
        #expect(OverlayArgs.resolveOpen(sizePercent: nil, cols: nil, rows: nil, anchor: "top-left")
            == .invalid("--anchor requires a floating overlay: use --size-percent or --cols/--rows"))
    }

    @Test func openPropagatesSizeAndAnchorRejections() {
        #expect(OverlayArgs.resolveOpen(sizePercent: 0, cols: nil, rows: nil, anchor: nil)
            == .invalid("session.overlay.open: --size-percent must be 1...100"))
        #expect(OverlayArgs.resolveOpen(sizePercent: nil, cols: 40, rows: nil, anchor: nil)
            == .invalid("session.overlay.open: provide both --cols and --rows"))
        #expect(OverlayArgs.resolveOpen(sizePercent: 50, cols: nil, rows: nil, anchor: "middle")
            == .invalid("unknown anchor: middle (top-left|top|top-right|left|center|right|bottom-left|bottom|bottom-right)"))
    }

    // MARK: - resolveResize

    @Test func resizeResolvesAnchorOnlyKeepingSize() {
        #expect(OverlayArgs.resolveResize(sizePercent: nil, cols: nil, rows: nil, full: false, anchor: "top")
            == .resolved(size: nil, anchor: .top))
    }

    @Test func resizeResolvesPercentFullAndCells() {
        #expect(OverlayArgs.resolveResize(sizePercent: 60, cols: nil, rows: nil, full: false, anchor: nil)
            == .resolved(size: .percent(60), anchor: nil))
        #expect(OverlayArgs.resolveResize(sizePercent: nil, cols: nil, rows: nil, full: true, anchor: nil)
            == .resolved(size: .full, anchor: nil))
        #expect(OverlayArgs.resolveResize(sizePercent: nil, cols: 40, rows: 12, full: false, anchor: "left")
            == .resolved(size: .cells(cols: 40, rows: 12), anchor: .left))
    }

    @Test func resizeRejectsFullWithAnchor() {
        #expect(OverlayArgs.resolveResize(sizePercent: nil, cols: nil, rows: nil, full: true, anchor: "top-left")
            == .invalid("--full cannot be combined with --anchor"))
    }

    @Test func resizeRejectsNothingSet() {
        #expect(OverlayArgs.resolveResize(sizePercent: nil, cols: nil, rows: nil, full: false, anchor: nil)
            == .invalid("session.overlay.resize requires a size (--full, --size-percent, --cols/--rows) or --anchor"))
    }

    @Test func resizePropagatesSizeAndAnchorRejections() {
        #expect(OverlayArgs.resolveResize(sizePercent: nil, cols: 5, rows: nil, full: false, anchor: nil)
            == .invalid("session.overlay.resize: provide both --cols and --rows"))
        #expect(OverlayArgs.resolveResize(sizePercent: nil, cols: nil, rows: nil, full: false, anchor: "bogus")
            == .invalid("unknown anchor: bogus (top-left|top|top-right|left|center|right|bottom-left|bottom|bottom-right)"))
    }
}
