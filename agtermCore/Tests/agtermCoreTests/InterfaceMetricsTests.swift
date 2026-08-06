import Testing
@testable import agtermCore

/// One window/sidebar/size combination the fitting must survive.
struct PanelCase: Sendable {
    let name: String
    let size: Double
    let window: Double
    let inset: Double
}

struct InterfaceMetricsTests {
    @Test func defaultSizeReproducesTheHardcodedChromeFonts() {
        let metrics = InterfaceMetrics(fontSize: AppSettings.defaultInterfaceFontSize)
        #expect(metrics.base == 13)
        #expect(metrics.secondary == 10) // .caption / .caption2 on macOS
        #expect(metrics.shortcut == 12) // .callout
        #expect(metrics.scale == 1)
        #expect(metrics.scaled(520) == 520)
        #expect(metrics.scaled(320) == 320)
    }

    @Test(arguments: [(base: 9.0, secondary: 8.0, shortcut: 8.0),
                      (base: 16.0, secondary: 12.0, shortcut: 15.0),
                      (base: 20.0, secondary: 15.0, shortcut: 18.0)])
    func derivedSizesStayProportional(_ expected: (base: Double, secondary: Double, shortcut: Double)) {
        let metrics = InterfaceMetrics(fontSize: expected.base)
        #expect(metrics.base == expected.base)
        #expect(metrics.secondary == expected.secondary)
        #expect(metrics.shortcut == expected.shortcut)
    }

    @Test func derivedTextNeverFallsBelowTheFloor() {
        let metrics = InterfaceMetrics(fontSize: AppSettings.interfaceFontSizeRange.lowerBound)
        #expect(metrics.secondary >= InterfaceMetrics.minimumTextSize)
        #expect(metrics.shortcut >= InterfaceMetrics.minimumTextSize)
        #expect(metrics.secondary <= metrics.base)
        #expect(metrics.shortcut <= metrics.base)
    }

    @Test func outOfRangeSizesClampBeforeDerivation() {
        #expect(InterfaceMetrics(fontSize: 99) == InterfaceMetrics(fontSize: AppSettings.interfaceFontSizeRange.upperBound))
        #expect(InterfaceMetrics(fontSize: 2) == InterfaceMetrics(fontSize: AppSettings.interfaceFontSizeRange.lowerBound))
    }

    @Test func panelLengthsScaleWithTheBase() {
        let metrics = InterfaceMetrics(fontSize: 20)
        #expect(metrics.scaled(520) == 800)
        #expect(metrics.scaled(320) == 492)
    }

    /// The regression: width and offset each grew unbounded and compounded, so the panel's right edge ran
    /// past the window. Every case here is one the shipped defaults or the settings ranges allow.
    @Test(arguments: [PanelCase(name: "stock 13pt at the 640pt window minimum", size: 13, window: 640, inset: 221),
                      PanelCase(name: "stock 13pt under the 741pt threshold", size: 13, window: 740, inset: 221),
                      PanelCase(name: "sidebar at 450 in the 900pt default", size: 13, window: 900, inset: 451),
                      PanelCase(name: "20pt interface size, default sidebar", size: 20, window: 900, inset: 221),
                      PanelCase(name: "widest sidebar and largest size", size: 20, window: 900, inset: 561),
                      PanelCase(name: "no sidebar", size: 13, window: 900, inset: 0)])
    func fittedPanelStaysInsideTheWindow(_ testCase: PanelCase) {
        for ideal in [520.0, 460.0] { // palette and switcher
            let metrics = InterfaceMetrics(fontSize: testCase.size)
            let width = metrics.fittedPanelWidth(idealAtDefault: ideal, windowWidth: testCase.window,
                                                 terminalAreaInset: testCase.inset)
            let offset = metrics.panelOffset(width: width, windowWidth: testCase.window,
                                             terminalAreaInset: testCase.inset)
            let left = (testCase.window - width) / 2 + offset
            let right = (testCase.window + width) / 2 + offset
            #expect(left >= 0, "\(testCase.name): panel starts left of the window at \(left)")
            #expect(right <= testCase.window, "\(testCase.name): panel ends \(right - testCase.window)pt past the window")
        }
    }

    @Test func fittedPanelKeepsTheIdealWidthWhenItFits() {
        let metrics = InterfaceMetrics(fontSize: 13)
        // the 900pt default window with the default 220pt sidebar: the ideal fits, so nothing shrinks
        #expect(metrics.fittedPanelWidth(idealAtDefault: 520, windowWidth: 900, terminalAreaInset: 221) == 520)
        #expect(metrics.panelOffset(width: 520, windowWidth: 900, terminalAreaInset: 221) == 110.5)
    }

    @Test func panelOffsetDegradesToWholeWindowCenteringRatherThanClipping() {
        let metrics = InterfaceMetrics(fontSize: 13)
        // a panel as wide as the window has no room to shift, so it centers rather than overflowing
        #expect(metrics.panelOffset(width: 900, windowWidth: 900, terminalAreaInset: 400) == 0)
        #expect(metrics.panelOffset(width: 700, windowWidth: 900, terminalAreaInset: 400) == 100)
        #expect(metrics.panelOffset(width: 700, windowWidth: 900, terminalAreaInset: 0) == 0)
    }

    @Test func fittedPanelWidthNeverGoesBelowTheFloorOrPastTheWindow() {
        let metrics = InterfaceMetrics(fontSize: 13)
        // a sidebar wide enough to leave almost nothing still yields a usable panel, capped by the window
        let cramped = metrics.fittedPanelWidth(idealAtDefault: 520, windowWidth: 640, terminalAreaInset: 561)
        #expect(cramped == InterfaceMetrics.minimumPanelWidth)
        let tiny = metrics.fittedPanelWidth(idealAtDefault: 520, windowWidth: 300, terminalAreaInset: 561)
        #expect(tiny == 300 - 2 * InterfaceMetrics.panelMargin)
    }

    /// Pins the decision behind the switcher panel's height. The rendered result has no harness — hosted
    /// tests do not render SwiftUI and XCUITest cannot hold Ctrl for the switcher — so this covers the
    /// choice, and the trap it exists for is named on `measuredPanelHeight`.
    @Test func measuredPanelHeightHugsItsRowsUntilTheCap() {
        let metrics = InterfaceMetrics(fontSize: 13)
        // no measurement yet: unconstrained, so the panel never renders at a guessed height
        #expect(metrics.measuredPanelHeight(rowsHeight: 0, maxRowsHeight: 764) == nil)
        // four rows in a tall window: the panel is its rows, NOT the 764pt it was offered
        #expect(metrics.measuredPanelHeight(rowsHeight: 160, maxRowsHeight: 764) == 160)
        // ten rows in a short window: capped, and the scroll view takes over inside it
        #expect(metrics.measuredPanelHeight(rowsHeight: 540, maxRowsHeight: 265) == 265)
        #expect(metrics.measuredPanelHeight(rowsHeight: 540, maxRowsHeight: 540) == 540)
        // a cap that goes negative on a degenerate window collapses to 0 rather than inverting
        #expect(metrics.measuredPanelHeight(rowsHeight: 160, maxRowsHeight: -20) == 0)
    }

    @Test func fittedPanelHeightLeavesTheTopInsetAndFloors() {
        let metrics = InterfaceMetrics(fontSize: 20)
        #expect(metrics.fittedPanelHeight(windowHeight: 1000, topFraction: 0.12) == 1000 * 0.88 - 16)
        // the 400pt window minimum leaves 336pt, well clear of the floor
        #expect(metrics.fittedPanelHeight(windowHeight: 400, topFraction: 0.12) == 400 * 0.88 - 16)
        // only a degenerate height reaches the floor, and it never returns a negative
        #expect(metrics.fittedPanelHeight(windowHeight: 100, topFraction: 0.12) == InterfaceMetrics.minimumPanelHeight)
        #expect(metrics.fittedPanelHeight(windowHeight: 0, topFraction: 0.12) == InterfaceMetrics.minimumPanelHeight)
    }
}
