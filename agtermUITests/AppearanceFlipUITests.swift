import XCTest

/// End-to-end regression test for the appearance-flip reload: an automatic macOS light/dark flip
/// re-resolves the dual theme but must PRESERVE each session's ⌘+/⌘− font zoom (the explicit reloads
/// keep the zoom-clearing contract; the flip is the deliberate exception). The flip rides the
/// UI-test-only `debug.appearance` seam: setting `NSApp.appearance` fires
/// `viewDidChangeEffectiveAppearance` on every view, so the REAL flip path (scheme sync → notification
/// → debounced zoom-preserving reload) runs end to end; the seam's BARE (read) form then reports the
/// side the last config feed applied, proving the flip drove the reload. A `ControlAPITestCase`
/// subclass in its own file, sharing the launch + socket harness with the other `Control*UITests`.
@MainActor
final class AppearanceFlipUITests: ControlAPITestCase {
    func testAppearanceFlipPreservesFontZoom() throws {
        // seam validation: an unknown side is rejected (asserted inline — not worth its own launch).
        let bad = try sendCommand(#"{"cmd":"debug.appearance","args":{"name":"blue"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown side should be rejected: \(bad)")

        // pin a KNOWN starting side so the test is independent of the machine's appearance.
        let start = try sendCommand(#"{"cmd":"debug.appearance","args":{"name":"light"}}"#)
        XCTAssertEqual(start["ok"] as? Bool, true, "debug.appearance should be accepted under a UI-test launch: \(start)")
        XCTAssertEqual((start["result"] as? [String: Any])?["text"] as? String, "light")

        // follow the system appearance with both slots set — the flip precondition. This settings
        // apply() reloads and records the light side as the last-applied one.
        let synced = try sendCommand(#"{"cmd":"theme.set","args":{"light":"Builtin Light","dark":"Builtin Dark"}}"#)
        XCTAssertEqual(synced["ok"] as? Bool, true, "theme.set --light --dark should succeed: \(synced)")

        // zoom the seeded session AFTER the theme change (a settings-change reload resets the model
        // override), then wait for the persisted per-session fontSize — the test's oracle.
        for _ in 0..<3 {
            let inc = try sendCommand(#"{"cmd":"font.inc"}"#)
            XCTAssertEqual(inc["ok"] as? Bool, true, "font.inc should succeed: \(inc)")
        }
        var zoomed = try XCTUnwrap(pollFirstSessionFontSize(timeout: 8),
                                   "zooming should persist a per-session fontSize override")
        // the per-session save is debounced (~0.3s), so under load the three increments can persist in
        // steps; wait until two reads 0.5s apart agree so `zoomed` is the SETTLED override, not an
        // intermediate one (which would make the steady-state assertion below fail spuriously).
        let settleDeadline = Date().addingTimeInterval(8)
        while Date() < settleDeadline {
            usleep(500_000)
            let current = firstSessionFontSize()
            if current == zoomed { break }
            if let current { zoomed = current }
        }

        // flip to dark: the response echoing the applied side proves the appearance change reached the
        // app — which is what fires viewDidChangeEffectiveAppearance → the debounced flip reload.
        let flipped = try sendCommand(#"{"cmd":"debug.appearance","args":{"name":"dark"}}"#)
        XCTAssertEqual(flipped["ok"] as? Bool, true, "the flip should be accepted: \(flipped)")
        XCTAssertEqual((flipped["result"] as? [String: Any])?["text"] as? String, "dark")

        // the persisted override must hold STEADY through the flip reload (debounced ~0.05s). The old
        // behavior routed the flip through the zoom-CLEARING reload, which nils the persisted override
        // — the surface's own size report then re-persists it ~0.4s later (update_config does not reset
        // the runtime zoom on the current libghostty pin), so a single settled read would miss the
        // wipe. Sampling continuously catches that nil blip: it IS the regression (a quit inside the
        // window loses the zoom, and closed windows' snapshots are stripped for good).
        let sampleDeadline = Date().addingTimeInterval(2.5)
        while Date() < sampleDeadline {
            let sampled = try XCTUnwrap(firstSessionFontSize(),
                                        "the appearance flip must not clear the per-session font zoom")
            XCTAssertEqual(sampled, zoomed, accuracy: 0.5,
                           "the persisted zoom must hold steady across the flip reload")
            usleep(100_000)
        }

        // and the flip must have actually DRIVEN the reload: the seam's bare (read) form reports the
        // side the last config feed applied — a suppressed flip would leave it on "light", making the
        // zoom sampling above vacuous.
        let appliedDeadline = Date().addingTimeInterval(8)
        var applied = ""
        while Date() < appliedDeadline {
            let probe = try sendCommand(#"{"cmd":"debug.appearance"}"#)
            applied = ((probe["result"] as? [String: Any])?["text"] as? String) ?? ""
            if applied == "dark" { break }
            usleep(200_000)
        }
        XCTAssertEqual(applied, "dark", "the flip must drive the config reload (last-applied side)")
    }
}
