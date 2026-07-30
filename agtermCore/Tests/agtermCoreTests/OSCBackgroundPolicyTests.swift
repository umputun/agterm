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

    @Test func baselineIsTheSurfaceColorWithNoOSCOverlayInstalled() {
        let hex = OSCBackgroundPolicy.baseline(oscOverlayActive: false, surfaceBackground: "#aa0000",
                                               themeBackground: "#1d1f21")
        #expect(hex == "#aa0000")
    }

    @Test func baselineIsTheThemeWhileAnOSCOverlayIsInstalled() {
        // the OSC overlay emits no `background` key, so the config in force is the base one and ghostty
        // seeded the terminal's default layer from the THEME, not from the surface's own color. Reporting
        // the surface color here makes a reset look like a set and strands the latch.
        let hex = OSCBackgroundPolicy.baseline(oscOverlayActive: true, surfaceBackground: "#aa0000",
                                               themeBackground: "#1d1f21")
        #expect(hex == "#1d1f21")
    }

    @Test func baselineFallsBackToTheThemeWithNoSurfaceColor() {
        #expect(OSCBackgroundPolicy.baseline(oscOverlayActive: false, surfaceBackground: nil,
                                             themeBackground: "#1d1f21") == "#1d1f21")
        #expect(OSCBackgroundPolicy.baseline(oscOverlayActive: false, surfaceBackground: nil,
                                             themeBackground: nil) == nil)
    }

    @Test func resetOnAColoredSurfaceRoutesToResetNotApply() {
        // the reset reports the THEME (the OSC overlay dropped the watermark's background key), so a
        // baseline still claiming the watermark color would return .apply and never release the overlay.
        let baseline = OSCBackgroundPolicy.baseline(oscOverlayActive: true, surfaceBackground: "#aa0000",
                                                    themeBackground: "#1d1f21")
        #expect(OSCBackgroundPolicy.decide(incoming: "#1d1f21", themeBackground: baseline,
                                           current: "#123456") == .reset)
    }
}
