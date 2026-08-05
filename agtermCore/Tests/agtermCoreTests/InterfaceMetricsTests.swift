import Testing
@testable import agtermCore

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
}
