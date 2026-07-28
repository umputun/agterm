import Foundation
import Testing
@testable import agtermCore

struct OSCBackgroundPolicyTests {
    @Test func firstColorApplies() {
        let decision = OSCBackgroundPolicy.decide(incoming: "#123456", themeBackground: "#1d1f21", current: nil)
        #expect(decision == .apply("#123456"))
    }

    @Test func differentColorReplacesTheLiveOne() {
        let decision = OSCBackgroundPolicy.decide(incoming: "#abcdef", themeBackground: "#1d1f21", current: "#123456")
        #expect(decision == .apply("#abcdef"))
    }

    @Test func repeatedSameColorIsDeduped() {
        // a shell re-asserting OSC 11 on every prompt must not drive a surface config rebuild each time.
        let decision = OSCBackgroundPolicy.decide(incoming: "#123456", themeBackground: "#1d1f21", current: "#123456")
        #expect(decision == .ignore)
    }

    @Test func resetToThemeBackgroundReleasesTheOverlay() {
        // issue #309: OSC 111 arrives as a color change back to the theme background. It must release the
        // overlay rather than be deduped or re-applied, or the pane stays recolored after a TUI exits.
        let decision = OSCBackgroundPolicy.decide(incoming: "#1d1f21", themeBackground: "#1d1f21", current: "#123456")
        #expect(decision == .reset)
    }

    @Test func resetWithNoOverlayLiveIsIgnored() {
        let decision = OSCBackgroundPolicy.decide(incoming: "#1d1f21", themeBackground: "#1d1f21", current: nil)
        #expect(decision == .ignore)
    }

    @Test func hexComparisonIgnoresCaseAndLeadingHash() {
        // the callback formats `#rrggbb` lowercase; the theme color arrives from `NSColor.agtermHexString`
        // as `#RRGGBB`. A case-sensitive compare would miss every reset.
        #expect(OSCBackgroundPolicy.decide(incoming: "#1d1f21", themeBackground: "#1D1F21", current: "#123456") == .reset)
        #expect(OSCBackgroundPolicy.decide(incoming: "#1d1f21", themeBackground: "1D1F21", current: "#123456") == .reset)
        #expect(OSCBackgroundPolicy.decide(incoming: "#ABCDEF", themeBackground: "#1d1f21", current: "#abcdef") == .ignore)
    }

    @Test func unknownThemeBackgroundStillDedupesAndApplies() {
        // before the first config resolve the theme color is nil: no reset can be recognized, but the
        // set/dedupe path must keep working.
        #expect(OSCBackgroundPolicy.decide(incoming: "#123456", themeBackground: nil, current: nil) == .apply("#123456"))
        #expect(OSCBackgroundPolicy.decide(incoming: "#123456", themeBackground: nil, current: "#123456") == .ignore)
    }

    @Test(arguments: ["", "#12345", "#12345g", "nonsense", "＃ＦＦ００００"])
    func malformedIncomingColorIsIgnored(_ hex: String) {
        #expect(OSCBackgroundPolicy.decide(incoming: hex, themeBackground: "#1d1f21", current: nil) == .ignore)
    }
}
