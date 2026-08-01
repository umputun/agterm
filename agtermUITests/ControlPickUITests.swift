import XCTest

/// End-to-end coverage for the native control picker. The control socket opens, polls, and cancels
/// real per-window `PickController` state, while XCUITest verifies the SwiftUI `pick-palette` and its
/// supplied rows. The background-window case keeps its target minimized so an implementation that
/// silently ignores `--window` is guaranteed to mutate the visible front window instead. The `.attention`
/// palette is covered here too: it shares the empty-query order bypass these pickers rely on.
@MainActor
final class ControlPickUITests: ControlAPITestCase {
    func testPickRendersRowsSelectsItemAndReportsTreeState() throws {
        let opened = try openPick([
            ["id": "alpha", "label": "Alpha", "subtitle": "first choice"],
            ["id": "beta", "label": "Beta", "subtitle": "second choice"],
        ], prompt: "Choose a target")
        let pickID = try resultID(opened)

        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "pick.open should present the native picker")
        XCTAssertTrue(app.paletteRow("alpha").waitForExistence(timeout: 5), "the supplied Alpha row should appear")
        XCTAssertTrue(app.paletteRow("beta").waitForExistence(timeout: 5), "the supplied Beta row should appear")
        XCTAssertTrue(app.staticTexts["Alpha"].exists, "the first supplied label should be visible")
        XCTAssertTrue(app.staticTexts["Beta"].exists, "the second supplied label should be visible")
        XCTAssertEqual(try treePickPending(), pickID, "tree should expose the live picker id")

        clickPaletteRow("beta")

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "picked")
        XCTAssertEqual(result["id"] as? String, "beta")
        XCTAssertEqual(result["label"] as? String, "Beta")
        XCTAssertEqual(result["index"] as? Int, 1, "clicking the second unfiltered row should report its input index")
        XCTAssertTrue(pickPalette.waitForNonExistence(timeout: 10), "selection should dismiss the picker")
        XCTAssertNil(try treePickPending(), "tree should omit pickPending after resolution")
    }

    /// With an empty query the palette skips ranking entirely, so filtered order equals input order and a
    /// click there cannot tell the two apart. Typing a query that drops the earlier rows is what separates
    /// them: the match is the only row on screen, at row position 0, while its caller index is 2.
    func testFilteredSelectionReportsCallerIndexNotRowPosition() throws {
        let pickID = try resultID(openPick([
            ["id": "alpha", "label": "Alpha"],
            ["id": "beta", "label": "Beta"],
            ["id": "gamma", "label": "Gamma"],
        ]))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "pick.open should present the picker")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the picker query field should exist")
        field.click()
        field.typeText("gam")
        XCTAssertTrue(app.paletteRow("gamma").waitForExistence(timeout: 5), "the query should keep the matching row")
        XCTAssertTrue(app.paletteRow("alpha").waitForNonExistence(timeout: 5),
                      "the query should drop the non-matching rows, leaving the match alone on screen")

        clickPaletteRow("gamma")

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "picked")
        XCTAssertEqual(result["id"] as? String, "gamma")
        XCTAssertEqual(result["index"] as? Int, 2,
                       "the index must be the caller's array position, not the filtered row position 0")
    }

    // pins the empty-query A→Z tie-break that ran the alphabetical row instead of the caller's first.
    func testEmptyQueryEnterPicksTheCallerSuppliedFirstItem() throws {
        let pickID = try resultID(openPick([
            ["id": "zebra", "label": "Zebra"],
            ["id": "alpha", "label": "Alpha"],
        ]))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "pick.open should present the picker")
        XCTAssertTrue(app.paletteRow("zebra").waitForExistence(timeout: 5), "the caller's first row should be listed")
        XCTAssertTrue(app.paletteRow("alpha").waitForExistence(timeout: 5), "the caller's second row should be listed")

        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "picked")
        XCTAssertEqual(result["id"] as? String, "zebra", "Enter without typing must run the caller's first row")
        XCTAssertEqual(result["index"] as? Int, 0, "the caller's first row is index 0, not the A→Z winner")
    }

    /// Pins the trim: `query` is unvalidated, and a newline survived the old whitespace-only trim while
    /// `fuzzyScore` still consumed it, so every row scored 0 and the A→Z tie-break replaced the caller's
    /// first row with the one Return runs.
    func testBlankQueryWithANewlineKeepsCallerSuppliedOrder() throws {
        let pickID = try resultID(openPick([
            ["id": "zebra", "label": "Zebra"],
            ["id": "alpha", "label": "Alpha"],
        ], query: " \n "))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "pick.open should present the picker")
        XCTAssertTrue(app.paletteRow("zebra").waitForExistence(timeout: 5), "the caller's first row should be listed")
        XCTAssertTrue(app.paletteRow("alpha").waitForExistence(timeout: 5), "the caller's second row should be listed")

        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "picked")
        XCTAssertEqual(result["id"] as? String, "zebra", "a blank query must count as empty and keep caller order")
        XCTAssertEqual(result["index"] as? Int, 0, "the caller's first row is index 0, not the A→Z winner")
    }

    func testNonEmptyQueryStillRanksCallerSuppliedRows() throws {
        let pickID = try resultID(openPick([
            ["id": "zebra", "label": "Zebra"],
            ["id": "alpha", "label": "Alpha"],
        ]))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "pick.open should present the picker")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the picker query field should exist")
        field.click()
        field.typeText("a")
        XCTAssertTrue(app.paletteRow("alpha").waitForExistence(timeout: 5), "the better match should stay listed")
        XCTAssertTrue(app.paletteRow("zebra").waitForExistence(timeout: 5), "the weaker match should stay listed too")

        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "picked")
        XCTAssertEqual(result["id"] as? String, "alpha", "a typed query must rank by score, not by caller order")
        XCTAssertEqual(result["index"] as? Int, 1, "the reported index stays the caller's array position")
    }

    // pins the same tie-break in the .attention palette: Return on open ran the active row, not the blocked one.
    func testAttentionPaletteEnterKeepsStatusOrderOnEmptyQuery() throws {
        let blocked = try namedSession("zebra")
        let active = try namedSession("alpha")
        try setStatus("blocked", target: blocked)
        try setStatus("active", target: active)
        XCTAssertTrue(poll(until: isActiveSession(active), timeout: 8),
                      "the last created session should start selected")

        app.menuBars.menuBarItems["Navigate"].click()
        let item = app.menuItems["Go to Attention…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Navigate should offer Go to Attention…")
        item.click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "command-palette")
            .firstMatch.waitForExistence(timeout: 5), "the attention palette should open")
        XCTAssertTrue(app.paletteRow(blocked).waitForExistence(timeout: 5), "the blocked session should be listed")
        XCTAssertTrue(app.paletteRow(active).waitForExistence(timeout: 5), "the active session should be listed")

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(poll(until: isActiveSession(blocked), timeout: 8),
                      "Return on open must select the blocked session, not the alphabetically-first one")
    }

    func testPrefilledQueryOpensPopulatedAndFiltered() throws {
        let pickID = try resultID(openPick([
            ["id": "alpha", "label": "Alpha"],
            ["id": "beta", "label": "Beta"],
            ["id": "gamma", "label": "Gamma"],
        ], query: "gam"))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "pick.open should present the picker")
        XCTAssertTrue(app.paletteRow("gamma").waitForExistence(timeout: 5), "the prefilled query should keep its match")
        XCTAssertTrue(app.paletteRow("alpha").waitForNonExistence(timeout: 5),
                      "the prefilled query must filter on open, with nothing typed")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the picker query field should exist")
        XCTAssertEqual(field.value as? String, "gam", "the field should open carrying the caller's query")

        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "picked")
        XCTAssertEqual(result["id"] as? String, "gamma", "Return should run the prefiltered list's only row")
        XCTAssertEqual(result["index"] as? Int, 2, "the reported index stays the caller's array position")
    }

    func testEmptyItemsWithAllowCustomActAsAPrefilledPrompt() throws {
        let pickID = try resultID(openPick([], query: "old name", allowCustom: true))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10),
                      "an empty item list with --allow-custom should still present the picker")
        XCTAssertTrue(app.paletteRow("pick-custom").waitForExistence(timeout: 5),
                      "with no items to match, the prefilled query should offer the custom row")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the picker query field should exist")
        XCTAssertEqual(field.value as? String, "old name", "the prompt should open carrying the caller's value")

        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "custom", "an itemless picker can only resolve as custom")
        XCTAssertEqual(result["query"] as? String, "old name")
    }

    func testTypingIntoAPrefilledQueryReplacesTheSeededText() throws {
        let pickID = try resultID(openPick([], query: "old name", allowCustom: true))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10))
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the picker query field should exist")
        XCTAssertEqual(field.value as? String, "old name")

        app.typeText("x")
        XCTAssertEqual(field.value as? String, "x",
                       "the seeded text opens selected, so the first keystroke replaces it rather than appending")

        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "custom")
        XCTAssertEqual(result["query"] as? String, "x", "the committed answer is the replacement, not old name + x")
    }

    // `query` is deliberately unvalidated, so `--query $'name\n'` reaches the field; the committed answer
    // used to keep the newline the row label had already dropped.
    func testPrefilledQueryCommitsExactlyWhatTheCustomRowShows() throws {
        let pickID = try resultID(openPick([], query: "old name\n", allowCustom: true))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10))
        XCTAssertTrue(app.paletteRow("pick-custom").waitForExistence(timeout: 5),
                      "the seeded query should offer the custom row")
        XCTAssertTrue(app.staticTexts["Use \"old name\""].waitForExistence(timeout: 5),
                      "the custom row should display the trimmed value")

        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "custom")
        XCTAssertEqual(result["query"] as? String, "old name",
                       "the committed answer must be the value the row displayed")
    }

    func testEmptyItemsWithoutQueryListsNothingUntilTyped() throws {
        let pickID = try resultID(openPick([], allowCustom: true))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10),
                      "an itemless picker without a query should still present the panel")
        XCTAssertFalse(app.paletteRow("pick-custom").waitForExistence(timeout: 2),
                       "an empty query offers no custom row, so the panel opens with nothing selectable")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(pickPalette.waitForNonExistence(timeout: 2),
                       "Return on an empty panel must leave the picker open for the whole settle window")
        XCTAssertEqual(try pickResult(id: pickID)["result"] as? String, "pending",
                       "Return on an empty panel must not resolve the picker")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the picker query field should exist")
        field.click()
        field.typeText("typed name")
        XCTAssertTrue(app.paletteRow("pick-custom").waitForExistence(timeout: 5),
                      "the first keystrokes should offer the custom row")

        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "custom")
        XCTAssertEqual(result["query"] as? String, "typed name")
    }

    /// Pins the confirm-row trap: the subtitle `cannot be undone` matched the refusal query `no`, leaving
    /// the destructive row alone and preselected for Return.
    func testRefusalQueryLeavesNoRowInACallerSuppliedConfirm() throws {
        let pickID = try resultID(openPick([
            ["id": "confirm", "label": "Confirm", "subtitle": "cannot be undone"],
            ["id": "cancel", "label": "Cancel"],
        ]))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "pick.open should present the picker")
        XCTAssertTrue(app.paletteRow("confirm").waitForExistence(timeout: 5), "the confirm row should start listed")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the picker query field should exist")
        field.click()
        field.typeText("no")

        XCTAssertTrue(app.paletteRow("confirm").waitForNonExistence(timeout: 5),
                      "a subtitle must not match a refusal query and leave the destructive row alone")
        XCTAssertTrue(app.paletteRow("cancel").waitForNonExistence(timeout: 5),
                      "Cancel does not match the query either, so the whole list should be empty")

        app.typeKey(.return, modifierFlags: [])

        XCTAssertFalse(pickPalette.waitForNonExistence(timeout: 2),
                       "Return on an empty list must leave the picker open for the whole settle window")
        XCTAssertEqual(try pickResult(id: pickID)["result"] as? String, "pending",
                       "Return on an empty list must not resolve the picker")

        XCTAssertEqual(try sendCommand(request(command: "pick.cancel", target: pickID))["ok"] as? Bool, true)
        XCTAssertEqual(try awaitTerminalResult(id: pickID)["result"] as? String, "cancelled")
    }

    func testPickCancelReportsCancelled() throws {
        let pickID = try resultID(openPick([["id": "one", "label": "One"]]))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "pick.open should present the picker")

        let cancelled = try sendCommand(request(command: "pick.cancel", target: pickID))
        XCTAssertEqual(cancelled["ok"] as? Bool, true, "pick.cancel should succeed: \(cancelled)")

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "cancelled")
        XCTAssertTrue(pickPalette.waitForNonExistence(timeout: 10), "cancellation should dismiss the picker")
    }

    func testEscapeCancelsAndDismissesPicker() throws {
        let pickID = try resultID(openPick([["id": "one", "label": "One"]]))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10))

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertEqual(try awaitTerminalResult(id: pickID)["result"] as? String, "cancelled")
        XCTAssertTrue(pickPalette.waitForNonExistence(timeout: 10))
    }

    func testScrimClickCancelsAndDismissesPicker() throws {
        let pickID = try resultID(openPick([["id": "one", "label": "One"]]))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10))
        let scrim = app.descendants(matching: .any).matching(identifier: "pick-scrim").firstMatch
        XCTAssertTrue(scrim.waitForExistence(timeout: 5))

        scrim.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).click()

        XCTAssertEqual(try awaitTerminalResult(id: pickID)["result"] as? String, "cancelled")
        XCTAssertTrue(pickPalette.waitForNonExistence(timeout: 10))
    }

    func testPickKeepsKeyboardAfterClosingBuiltInPalette() throws {
        app.menuBars.menuBarItems["Navigate"].click()
        let commandPalette = app.menuItems["Command Palette"]
        XCTAssertTrue(commandPalette.waitForExistence(timeout: 5))
        commandPalette.click()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "command-palette").firstMatch.waitForExistence(timeout: 5))

        let query = "picker owns this text"
        let pickID = try resultID(openPick(
            [["id": "existing", "label": "Existing"]],
            allowCustom: true
        ))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10))
        app.typeText(query)

        XCTAssertTrue(app.paletteRow("pick-custom").waitForExistence(timeout: 5),
                      "palette-close focus retries must not send picker input to the terminal")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitTerminalResult(id: pickID)["query"] as? String, query)
    }

    func testPendingPickDisablesAndClosesRecentSessionsPopover() throws {
        XCTAssertEqual(try sendCommand(#"{"cmd":"session.new"}"#)["ok"] as? Bool, true)
        let recent = app.buttons["recent-sessions-button"]
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(until: recent.isEnabled, timeout: 8))

        recent.click()
        let row = app.buttons["recent-session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the recent-sessions popover should start open")

        let pickID = try resultID(openPick([["id": "one", "label": "One"]]))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10))

        XCTAssertTrue(poll(until: !recent.isEnabled, timeout: 5),
                      "a pending picker must disable the recent-sessions popover button")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5),
                      "a socket-driven picker must close an already-open title-bar popover")
        XCTAssertEqual(try sendCommand(request(command: "pick.cancel", target: pickID))["ok"] as? Bool, true)
        XCTAssertEqual(try awaitTerminalResult(id: pickID)["result"] as? String, "cancelled")
    }

    func testBackgroundZoomedPickerClosesPaletteWhenItsWindowBecomesFrontmost() throws {
        let pickerWindow = try XCTUnwrap(try windowIDs().first)
        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"palette-owner"}}"#)
        let paletteWindow = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        XCTAssertTrue(poll(until: (try? windowNode(id: paletteWindow)?["active"] as? Bool) == true, timeout: 10))

        app.menuBars.menuBarItems["Navigate"].click()
        let commandPaletteItem = app.menuItems["Command Palette"]
        XCTAssertTrue(commandPaletteItem.waitForExistence(timeout: 5))
        commandPaletteItem.click()
        let commandPalette = app.descendants(matching: .any).matching(identifier: "command-palette").firstMatch
        XCTAssertTrue(commandPalette.waitForExistence(timeout: 5))

        let zoom = try sendCommand(request(
            command: "surface.zoom",
            args: ["mode": "show", "window": pickerWindow]
        ))
        XCTAssertEqual(zoom["ok"] as? Bool, true, "the background picker window should start zoomed: \(zoom)")

        let query = "background picker owns focus"
        let pickID = try resultID(openPick(
            [["id": "existing", "label": "Existing"]],
            allowCustom: true,
            window: pickerWindow
        ))
        XCTAssertEqual(
            try sendCommand(#"{"cmd":"window.select","target":"\#(pickerWindow)"}"#)["ok"] as? Bool,
            true
        )
        XCTAssertTrue(poll(until: (try? windowNode(id: pickerWindow)?["active"] as? Bool) == true, timeout: 10))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10))
        XCTAssertTrue(commandPalette.waitForNonExistence(timeout: 5),
                      "the old window's built-in palette must not remount under the picker")

        app.typeText(query)
        XCTAssertTrue(app.paletteRow("pick-custom").waitForExistence(timeout: 5),
                      "the visible picker must retain keyboard focus after the window handoff")
        XCTAssertEqual(try sendCommand(request(command: "pick.cancel", target: pickID))["ok"] as? Bool, true)
        XCTAssertEqual(try awaitTerminalResult(id: pickID)["result"] as? String, "cancelled")
        XCTAssertEqual(try sendCommand(request(
            command: "surface.zoom",
            args: ["mode": "hide", "window": pickerWindow]
        ))["ok"] as? Bool, true)
        XCTAssertTrue(commandPalette.waitForNonExistence(timeout: 3),
                      "the stale built-in palette must stay closed after the picker resolves and zoom exits")
    }

    func testSecondPickOnSameWindowIsRejected() throws {
        let pickID = try resultID(openPick([["id": "first", "label": "First"]]))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "the first picker should be visible")

        let second = try openPick([["id": "second", "label": "Second"]])
        XCTAssertEqual(second["ok"] as? Bool, false, "a window may host only one pending picker: \(second)")
        XCTAssertEqual(second["error"] as? String, "pick already pending")

        XCTAssertEqual(try sendCommand(request(command: "pick.cancel", target: pickID))["ok"] as? Bool, true)
        XCTAssertEqual(try awaitTerminalResult(id: pickID)["result"] as? String, "cancelled")
    }

    func testAllowCustomReturnsNonMatchingQuery() throws {
        let query = "brand new value"
        let pickID = try resultID(openPick(
            [["id": "existing", "label": "Existing choice"]],
            prompt: "Choose or enter a value",
            allowCustom: true
        ))
        XCTAssertTrue(pickPalette.waitForExistence(timeout: 10), "pick.open --allow-custom should present the picker")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the picker query field should exist")
        field.click()
        field.typeText(query)
        XCTAssertTrue(app.paletteRow("pick-custom").waitForExistence(timeout: 5),
                      "a non-matching query should offer the custom row")
        app.typeKey(.return, modifierFlags: [])

        let result = try awaitTerminalResult(id: pickID)
        XCTAssertEqual(result["result"] as? String, "custom")
        XCTAssertEqual(result["query"] as? String, query)
    }

    func testWindowOptionTargetsMinimizedBackgroundWindow() throws {
        let frontID = try XCTUnwrap(try windowIDs().first, "the seeded front window should have an id")
        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"pick-background","minimized":true}}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "window.new --minimized should succeed: \(created)")
        let backID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                                   "window.new should return the background window id")
        XCTAssertTrue(poll(until: (try? windowNode(id: backID)?["minimized"] as? Bool) == true, timeout: 10),
                      "the target window must remain minimized")

        let pickID = try resultID(openPick(
            [["id": "background", "label": "Background choice"]],
            window: backID
        ))

        XCTAssertEqual(try treePickPending(window: backID), pickID,
                       "--window should put the picker in the minimized background window")
        XCTAssertNil(try treePickPending(window: frontID),
                     "the visible front window must not receive the targeted picker")
        // XCUITest continues to enumerate the accessibility tree of a minimized macOS window, so
        // palette visibility is not a foreground-window oracle. The two independently targeted
        // tree reads above are: ignoring `window` would set frontID and leave backID nil.

        let cancelled = try sendCommand(request(
            command: "pick.cancel",
            target: pickID,
            args: ["window": backID]
        ))
        XCTAssertEqual(cancelled["ok"] as? Bool, true, "targeted pick.cancel should succeed: \(cancelled)")
        XCTAssertEqual(try awaitTerminalResult(id: pickID, window: backID)["result"] as? String, "cancelled")
        XCTAssertNil(try treePickPending(window: backID), "the background tree should clear after cancellation")
    }

    func testConcurrentPicksResolveIndependentlyAcrossWindows() throws {
        let frontID = try XCTUnwrap(try windowIDs().first)
        let created = try sendCommand(#"{"cmd":"window.new","args":{"name":"pick-peer","minimized":true}}"#)
        let backID = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)

        let frontPick = try resultID(openPick(
            [["id": "front", "label": "Front"]],
            window: frontID
        ))
        let backPick = try resultID(openPick(
            [["id": "back", "label": "Back"]],
            window: backID
        ))
        XCTAssertEqual(try treePickPending(window: frontID), frontPick)
        XCTAssertEqual(try treePickPending(window: backID), backPick)

        XCTAssertEqual(try sendCommand(request(
            command: "pick.cancel", target: frontPick, args: ["window": frontID]
        ))["ok"] as? Bool, true)
        XCTAssertEqual(try awaitTerminalResult(id: frontPick, window: frontID)["result"] as? String, "cancelled")
        XCTAssertEqual(try treePickPending(window: backID), backPick,
                       "resolving one window must leave the other picker pending")

        XCTAssertEqual(try sendCommand(request(
            command: "pick.cancel", target: backPick, args: ["window": backID]
        ))["ok"] as? Bool, true)
        XCTAssertEqual(try awaitTerminalResult(id: backPick, window: backID)["result"] as? String, "cancelled")
    }

    // MARK: - Picker helpers

    private var pickPalette: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pick-palette").firstMatch
    }

    /// The title child of a row WITH a subtitle answers to the row's identifier but is not hittable,
    /// because the row itself owns the tap target. Click the first HITTABLE match rather than whichever the
    /// query returns first. This stays separate from `XCUIApplication.paletteRow` because resolving the
    /// matches is eager: doing it inside the existence waits, which run before the row exists, breaks them.
    private func clickPaletteRow(_ id: String) {
        let matches = app.descendants(matching: .any).matching(identifier: "palette-item-\(id)")
        (matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch).click()
    }

    private func openPick(
        _ items: [[String: Any]],
        prompt: String? = nil,
        query: String? = nil,
        allowCustom: Bool = false,
        window: String? = nil
    ) throws -> [String: Any] {
        var args: [String: Any] = ["items": items]
        if let prompt { args["prompt"] = prompt }
        if let query { args["query"] = query }
        if allowCustom { args["allowCustom"] = true }
        if let window { args["window"] = window }
        return try sendCommand(request(command: "pick.open", args: args))
    }

    private func resultID(_ response: [String: Any]) throws -> String {
        XCTAssertEqual(response["ok"] as? Bool, true, "pick.open should succeed: \(response)")
        return try XCTUnwrap((response["result"] as? [String: Any])?["id"] as? String,
                             "pick.open should return its id")
    }

    private func pickResult(id: String) throws -> [String: Any] {
        let response = try sendCommand(request(command: "pick.result", target: id))
        XCTAssertEqual(response["ok"] as? Bool, true, "pick.result should succeed: \(response)")
        return try XCTUnwrap((response["result"] as? [String: Any])?["pick"] as? [String: Any],
                             "pick.result should carry a pick result")
    }

    private func awaitTerminalResult(
        id: String,
        window: String? = nil,
        timeout: TimeInterval = 10
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [String: Any]?
        repeat {
            var args: [String: Any] = [:]
            if let window { args["window"] = window }
            let response = try sendCommand(request(
                command: "pick.result",
                target: id,
                args: args.isEmpty ? nil : args
            ))
            XCTAssertEqual(response["ok"] as? Bool, true, "pick.result should succeed: \(response)")
            latest = (response["result"] as? [String: Any])?["pick"] as? [String: Any]
            if latest?["result"] as? String != "pending" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        let result = try XCTUnwrap(latest, "pick.result should carry a pick result")
        XCTAssertNotEqual(result["result"] as? String, "pending", "picker should resolve before timeout")
        return result
    }

    // MARK: - Attention helpers

    /// Creates a session and renames it, so the `.attention` palette rows carry distinct, orderable titles.
    private func namedSession(_ name: String) throws -> String {
        let created = try sendCommand(#"{"cmd":"session.new"}"#)
        XCTAssertEqual(created["ok"] as? Bool, true, "session.new should succeed: \(created)")
        let id = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String,
                               "session.new should return the new id")
        let renamed = try sendCommand(#"{"cmd":"session.rename","target":"\#(id)","args":{"name":"\#(name)"}}"#)
        XCTAssertEqual(renamed["ok"] as? Bool, true, "session.rename should succeed: \(renamed)")
        return id
    }

    private func setStatus(_ status: String, target: String) throws {
        let response = try sendCommand(#"{"cmd":"session.status","target":"\#(target)","args":{"status":"\#(status)"}}"#)
        XCTAssertEqual(response["ok"] as? Bool, true, "session.status \(status) should succeed: \(response)")
    }

    private func isActiveSession(_ id: String) -> Bool {
        (try? sessionNodeIfPresent(id: id))??["active"] as? Bool == true
    }

    // MARK: - Tree and window helpers

    private func treePickPending(window: String? = nil) throws -> String? {
        var args: [String: Any]?
        if let window { args = ["window": window] }
        let response = try sendCommand(request(command: "tree", args: args))
        XCTAssertEqual(response["ok"] as? Bool, true, "tree should succeed: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "tree should carry a result")
        let tree = try XCTUnwrap(result["tree"] as? [String: Any], "tree result should carry a tree")
        return tree["pickPending"] as? String
    }

    private func windowIDs() throws -> [String] {
        let response = try sendCommand(#"{"cmd":"window.list"}"#)
        let windows = try XCTUnwrap((response["result"] as? [String: Any])?["windows"] as? [[String: Any]],
                                    "window.list should carry windows")
        return windows.compactMap { $0["id"] as? String }
    }

    private func windowNode(id: String) throws -> [String: Any]? {
        let response = try sendCommand(#"{"cmd":"window.list"}"#)
        let windows = (response["result"] as? [String: Any])?["windows"] as? [[String: Any]]
        return windows?.first { ($0["id"] as? String)?.lowercased() == id.lowercased() }
    }

    private func request(command: String, target: String? = nil,
                         args: [String: Any]? = nil) -> String {
        var object: [String: Any] = ["cmd": command]
        if let target { object["target"] = target }
        if let args { object["args"] = args }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
