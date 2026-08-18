import Foundation
import Testing
@testable import agtermCore

struct QuickTerminalMetricsTests {
    /// Compared with a tolerance: a share of a screen is a floating-point product, so 70% of 1440 lands on
    /// 1007.9999999999999. The panel is framed in fractional points either way, as it was before the setting.
    private func expectSize(_ size: WindowGeometry.Size, _ width: Double, _ height: Double) {
        #expect(abs(size.width - width) < 0.001)
        #expect(abs(size.height - height) < 0.001)
    }

    /// A 32" 4K display in points, the case from the report that motivated the setting.
    private let large = WindowGeometry.Size(width: 2560, height: 1440)
    /// A built-in Retina panel in points, small enough that the default share still binds.
    private let small = WindowGeometry.Size(width: 1470, height: 860)

    @Test func defaultCapsALargeScreenAtTheBuiltInMaximum() {
        expectSize(QuickTerminalMetrics.panelSize(visible: large, sizePercent: nil), 1100, 700)
    }

    @Test func defaultTakesTheShareWhenItFallsUnderTheMaximum() {
        let visible = WindowGeometry.Size(width: 1000, height: 600)
        expectSize(QuickTerminalMetrics.panelSize(visible: visible, sizePercent: nil), 900, 540)
    }

    @Test func defaultMixesShareAndMaximumPerAxis() {
        let visible = WindowGeometry.Size(width: 2000, height: 600)
        expectSize(QuickTerminalMetrics.panelSize(visible: visible, sizePercent: nil), 1100, 540)
    }

    @Test func setPercentageReplacesTheMaximumInsteadOfRaisingIt() {
        expectSize(QuickTerminalMetrics.panelSize(visible: large, sizePercent: 70), 1792, 1008)
    }

    @Test func setPercentageAppliesToASmallScreenToo() {
        expectSize(QuickTerminalMetrics.panelSize(visible: small, sizePercent: 50), 735, 430)
    }

    /// No single percentage reproduces the default on both screen sizes, which is why nil keeps its own path.
    @Test func noPercentageReproducesTheDefaultOnBothScreens() {
        let matchingLarge = QuickTerminalMetrics.sizePercentChoices.filter {
            QuickTerminalMetrics.panelSize(visible: large, sizePercent: $0).width
                == QuickTerminalMetrics.panelSize(visible: large, sizePercent: nil).width
        }
        let matchingSmall = QuickTerminalMetrics.sizePercentChoices.filter {
            QuickTerminalMetrics.panelSize(visible: small, sizePercent: $0).width
                == QuickTerminalMetrics.panelSize(visible: small, sizePercent: nil).width
        }
        #expect(Set(matchingLarge).isDisjoint(with: Set(matchingSmall)))
    }

    @Test func percentageAboveTheRangeClampsToTheCeiling() {
        expectSize(QuickTerminalMetrics.panelSize(visible: large, sizePercent: 400),
                   QuickTerminalMetrics.panelSize(visible: large, sizePercent: 90).width,
                   QuickTerminalMetrics.panelSize(visible: large, sizePercent: 90).height)
    }

    @Test func percentageBelowTheRangeClampsToTheFloor() {
        expectSize(QuickTerminalMetrics.panelSize(visible: large, sizePercent: 0),
                   QuickTerminalMetrics.panelSize(visible: large, sizePercent: 40).width,
                   QuickTerminalMetrics.panelSize(visible: large, sizePercent: 40).height)
    }

    @Test func clampSizePercentBoundsBothEnds() {
        #expect(QuickTerminalMetrics.clampSizePercent(-5) == QuickTerminalMetrics.sizePercentRange.lowerBound)
        #expect(QuickTerminalMetrics.clampSizePercent(1000) == QuickTerminalMetrics.sizePercentRange.upperBound)
        #expect(QuickTerminalMetrics.clampSizePercent(70) == 70)
    }

    @Test func everyOfferedChoiceIsInRange() {
        for percent in QuickTerminalMetrics.sizePercentChoices {
            #expect(QuickTerminalMetrics.clampSizePercent(percent) == percent)
        }
    }

    @Test func percentageIsMonotonicAcrossTheOfferedChoices() {
        let widths = QuickTerminalMetrics.sizePercentChoices.map {
            QuickTerminalMetrics.panelSize(visible: large, sizePercent: $0).width
        }
        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count)
    }
}
