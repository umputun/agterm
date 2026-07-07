import XCTest

/// End-to-end tests for the light/dark theme control API (`theme.set` per-slot + `theme.list`), spoken
/// directly over the control socket. A `ControlAPITestCase` subclass in its own file, sharing the launch
/// + socket harness with the other `Control*UITests` suites.
@MainActor
final class ControlAPIThemeUITests: ControlAPITestCase {
    func testThemeSyncWithSystemAppearance() throws {
        // a positional name plus --light targets the same slot twice.
        let both = try sendCommand(#"{"cmd":"theme.set","args":{"name":"Dracula","light":"Builtin Light"}}"#)
        XCTAssertEqual(both["ok"] as? Bool, false, "name + --light should fail: \(both)")

        // an unknown slot name is rejected, like the single form.
        let bad = try sendCommand(#"{"cmd":"theme.set","args":{"light":"NotARealTheme","dark":"agterm"}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false, "an unknown theme should fail: \(bad)")

        // setting the dark slot alone starts syncing; the light side seeds from the current theme
        // (the fresh-install agterm default).
        let darkOnly = try sendCommand(#"{"cmd":"theme.set","args":{"dark":"Dracula"}}"#)
        XCTAssertEqual(darkOnly["ok"] as? Bool, true, "theme.set --dark should succeed: \(darkOnly)")
        let darkResult = try XCTUnwrap(darkOnly["result"] as? [String: Any])
        XCTAssertEqual(darkResult["sync"] as? Bool, true, "a dark slot means syncing is on")
        XCTAssertEqual(darkResult["light"] as? String, "agterm", "the light side seeds from the current theme")
        XCTAssertEqual(darkResult["dark"] as? String, "Dracula")
        XCTAssertNil(darkResult["theme"], "no plain theme while syncing")

        // a plain name replaces the light slot and KEEPS the pair.
        let light = try sendCommand(#"{"cmd":"theme.set","args":{"name":"Builtin Light"}}"#)
        let lightResult = try XCTUnwrap(light["result"] as? [String: Any])
        XCTAssertEqual(lightResult["sync"] as? Bool, true, "a plain set keeps the pair")
        XCTAssertEqual(lightResult["light"] as? String, "Builtin Light")
        XCTAssertEqual(lightResult["dark"] as? String, "Dracula", "the dark side is untouched")

        // theme.list reflects the same derived sync state.
        let listed = try sendCommand(#"{"cmd":"theme.list"}"#)
        XCTAssertEqual((listed["result"] as? [String: Any])?["sync"] as? Bool, true, "theme.list reports sync on")

        // --dark none clears the dark slot: syncing off, the light side survives as the plain theme.
        let cleared = try sendCommand(#"{"cmd":"theme.set","args":{"dark":"none"}}"#)
        let clearedResult = try XCTUnwrap(cleared["result"] as? [String: Any])
        XCTAssertEqual(clearedResult["sync"] as? Bool, false, "--dark none turns syncing off")
        XCTAssertEqual(clearedResult["theme"] as? String, "Builtin Light", "the light side survives as the theme")

        // the reserved `none` is case-insensitive: re-establish syncing, then clear with `--dark None`.
        let resynced = try sendCommand(#"{"cmd":"theme.set","args":{"dark":"Dracula"}}"#)
        XCTAssertEqual(resynced["ok"] as? Bool, true, "re-establishing the dark slot should succeed: \(resynced)")
        let clearedCaps = try sendCommand(#"{"cmd":"theme.set","args":{"dark":"None"}}"#)
        let clearedCapsResult = try XCTUnwrap(clearedCaps["result"] as? [String: Any])
        XCTAssertEqual(clearedCapsResult["sync"] as? Bool, false, "--dark None (any case) also turns syncing off")
    }
}
