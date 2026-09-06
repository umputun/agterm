import XCTest

@MainActor
final class ControlAskUITests: ControlAPITestCase {
    func testButtonBlockAlignmentInBothStylesAndLayouts() throws {
        for style in ["terminal", "gui"] {
            for vertical in [false, true] {
                let label = vertical ? "A longer choice that forces the button row to wrap" : "First"
                for align in ["left", "center", "right"] {
                    let id = try openAsk([["id": "first", "label": label], ["id": "last", "label": label]],
                                         options: ["style": style, "align": align])
                    XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
                    let first = askButton("first").frame
                    let last = askButton("last").frame
                    let block = first.union(last)
                    let panel = askDialog.frame
                    if vertical {
                        XCTAssertGreaterThan(last.midY, first.midY)
                    } else {
                        XCTAssertEqual(first.midY, last.midY, accuracy: 1)
                        XCTAssertGreaterThan(last.midX, first.midX)
                    }
                    switch align {
                    case "left": XCTAssertLessThan(block.midX, panel.midX - 5)
                    case "right": XCTAssertGreaterThan(block.midX, panel.midX + 5)
                    default: XCTAssertEqual(block.midX, panel.midX, accuracy: 2)
                    }
                    clickAskButton("last")
                    XCTAssertEqual(try awaitAskResult(id)["index"] as? Int, 1)
                    XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
                }
            }
        }
    }

    func testCLIDefaultThenReturnAnswersDefault() throws {
        let id = try openAskCLI(["--button", "yes=Yes", "--button", "no=No", "--default", "no"])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "no")
    }

    func testUnanchoredDialogExcludesVisibleSidebar() throws {
        let response = try sendControlCommand("tree")
        let tree = try XCTUnwrap((response["result"] as? [String: Any])?["tree"] as? [String: Any])
        XCTAssertEqual(tree["sidebarVisible"] as? Bool, true)
        let width = try XCTUnwrap(tree["sidebarWidth"] as? Double)
        let id = try openAsk([["id": "ok", "label": "OK"]])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(askDialog.frame.minX, app.windows.firstMatch.frame.minX + width)
        clickAskButton("ok")
        XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "ok")
    }

    func testCLIArrowMovesFromDefaultToSecondButton() throws {
        let id = try openAskCLI(["--button", "yes=Yes", "--button", "no=No", "--default", "yes"])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let result = try awaitAskResult(id)
        XCTAssertEqual(result["id"] as? String, "no")
        XCTAssertEqual(result["index"] as? Int, 1)
    }

    func testCLIGUIStyleAnswersByNativeButtonClick() throws {
        let id = try openAskCLI(["--style", "gui", "--button", "yes=Yes", "--button", "no=No", "--default", "yes"])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ask-button-no"].waitForExistence(timeout: 5))
        clickAskButton("no")
        let result = try awaitAskResult(id)
        XCTAssertEqual(result["result"] as? String, "answered")
        XCTAssertEqual(result["id"] as? String, "no")
    }

    func testRenderClickReturnsCallerButtonAndClearsPending() throws {
        let id = try openAsk([
            ["id": "save", "label": "Save"],
            ["id": "later", "label": "Not now"],
        ], title: "Keep these changes?", options: ["message": "Choose what happens next."])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "ask-title").firstMatch.value as? String, "Keep these changes?")
        XCTAssertEqual(app.staticTexts.matching(identifier: "ask-message").firstMatch.value as? String, "Choose what happens next.")
        XCTAssertEqual(try treeAskPending(), id)
        XCTAssertTrue(askButton("later").waitForExistence(timeout: 5))

        clickAskButton("later")

        let result = try awaitAskResult(id)
        XCTAssertEqual(result["result"] as? String, "answered")
        XCTAssertEqual(result["id"] as? String, "later")
        XCTAssertEqual(result["label"] as? String, "Not now")
        XCTAssertEqual(result["index"] as? Int, 1)
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
        XCTAssertNil(try treeAskPending())
    }

    func testReturnWithoutDefaultAnswersFirstNonDestructiveButton() throws {
        for style in ["terminal", "gui"] {
            let id = try openAsk([["id": "delete", "label": "Delete"], ["id": "keep", "label": "Keep"]],
                                 options: ["style": style, "destructiveButton": "delete"])
            XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
            XCTAssertEqual(askButton("keep").value as? String, "selected")
            XCTAssertEqual(askButton("delete").value as? String, "")
            app.typeKey(.return, modifierFlags: [])
            let result = try awaitAskResult(id)
            XCTAssertEqual(result["result"] as? String, "answered")
            XCTAssertEqual(result["id"] as? String, "keep")
            XCTAssertEqual(result["index"] as? Int, 1)
            XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
        }
    }

    func testGUIHighlightMovesWithArrowsAndTab() throws {
        let id = try openAsk([["id": "keep", "label": "Keep"], ["id": "delete", "label": "Delete", "hotkey": "d"]],
                             options: ["style": "gui", "destructiveButton": "delete"])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertEqual(askButton("keep").value as? String, "selected")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertEqual(askButton("delete").value as? String, "selected")
        XCTAssertEqual(askButton("keep").value as? String, "")
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(askButton("keep").value as? String, "selected")
        app.typeKey(.tab, modifierFlags: .shift)
        XCTAssertEqual(askButton("delete").value as? String, "selected")
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertEqual(askButton("keep").value as? String, "selected")
        app.typeKey("d", modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "delete")
    }

    func testGUICLIRightThenReturnAndEscape() throws {
        let arguments = ["--style", "gui", "--button", "first=First", "--button", "second=Second"]
        let id = try openAskCLI(arguments)
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "second")
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
        let escaped = try openAskCLI(arguments)
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(escaped)["result"] as? String, "escaped")
    }

    func testHotkeyAnswersIndependentlyOfHighlight() throws {
        let id = try openAsk([
            ["id": "yes", "label": "Yes", "hotkey": "y"],
            ["id": "no", "label": "No", "hotkey": "n"],
        ])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: .shift)

        let result = try awaitAskResult(id)
        XCTAssertEqual(result["result"] as? String, "answered")
        XCTAssertEqual(result["id"] as? String, "no")
        XCTAssertEqual(result["index"] as? Int, 1)
    }

    func testEscapeReturnsEscapedWithoutAButtonAnswer() throws {
        let id = try openAsk([["id": "cancel", "label": "Cancel"]])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        let result = try awaitAskResult(id)
        XCTAssertEqual(result["result"] as? String, "escaped")
        XCTAssertNil(result["id"])
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
    }

    func testCommandWEscapesWithoutClosingTheWindow() throws {
        let session = try activeSessionID()
        let id = try openAsk([["id": "later", "label": "Later"]])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))

        app.typeKey("w", modifierFlags: .command)

        let result = try awaitAskResult(id)
        XCTAssertEqual(result["result"] as? String, "escaped")
        XCTAssertNil(result["id"])
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(try sessionNode(id: session)["active"] as? Bool, true)
    }

    func testOutsideClickKeepsTheQuestionPending() throws {
        let id = try openAsk([["id": "ok", "label": "OK"]])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.98))
        corner.click()

        XCTAssertFalse(askDialog.waitForNonExistence(timeout: 1))
        XCTAssertEqual(try askResult(id)["result"] as? String, "pending")
        XCTAssertEqual(try treeAskPending(), id)
        XCTAssertEqual(try sendControlCommand("ask.cancel", target: id)["ok"] as? Bool, true)
    }

    func testAskAndPickRejectCompetingOpenRequests() throws {
        let picked = try sendControlCommand("pick.open", args: ["items": [["id": "one", "label": "One"]]])
        XCTAssertEqual(picked["ok"] as? Bool, true)
        let pickID = try XCTUnwrap((picked["result"] as? [String: Any])?["id"] as? String)
        let picker = app.descendants(matching: .any).matching(identifier: "pick-palette").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let rejectedAsk = try sendControlCommand("ask.open", args: [
            "title": "Competing question", "buttons": [["id": "ok", "label": "OK"]],
        ])
        XCTAssertEqual(rejectedAsk["ok"] as? Bool, false)
        XCTAssertNil(try treeAskPending())
        XCTAssertEqual(try sendControlCommand("pick.cancel", target: pickID)["ok"] as? Bool, true)
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10))

        let askID = try openAsk([["id": "ok", "label": "OK"]])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        let rejectedPick = try sendControlCommand("pick.open", args: ["items": [["id": "one", "label": "One"]]])
        XCTAssertEqual(rejectedPick["ok"] as? Bool, false)
        XCTAssertEqual(try treeAskPending(), askID)
        XCTAssertEqual(try askResult(askID)["result"] as? String, "pending")
    }

    func testPendingAskRefusesControlDrivenCovers() throws {
        let session = try activeSessionID()
        let id = try openAsk([["id": "ok", "label": "OK"]])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        let requests: [(String, String?, [String: Any])] = [
            ("dashboard", nil, ["mru": true]),
            ("quick", nil, ["mode": "show"]),
            ("session.search", session, ["text": "needle"]),
            ("surface.zoom", nil, ["mode": "show"]),
        ]
        for (command, target, args) in requests {
            let response = try sendControlCommand(command, target: target, args: args)
            XCTAssertEqual(response["ok"] as? Bool, false, command)
            XCTAssertEqual(response["error"] as? String, "ask pending", command)
        }
        XCTAssertEqual(try treeAskPending(), id)
        XCTAssertTrue(askDialog.exists)
    }

    func testAdministrativeCancelReturnsCancelled() throws {
        let id = try openAsk([["id": "later", "label": "Later"]])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))

        XCTAssertEqual(try sendControlCommand("ask.cancel", target: id)["ok"] as? Bool, true)

        let result = try awaitAskResult(id)
        XCTAssertEqual(result["result"] as? String, "cancelled")
        XCTAssertNil(result["id"])
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
    }

    func testWindowCloseRetainsTheCancelledResult() throws {
        let listed = try sendControlCommand("window.list")
        let windows = try XCTUnwrap((listed["result"] as? [String: Any])?["windows"] as? [[String: Any]])
        let owner = try XCTUnwrap(windows.first?["id"] as? String)
        XCTAssertEqual(try sendControlCommand("window.new", args: ["name": "keeper", "minimized": true])["ok"] as? Bool, true)
        let id = try openAsk([["id": "later", "label": "Later"]], options: ["window": owner])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))

        XCTAssertEqual(try sendControlCommand("window.close", target: owner)["ok"] as? Bool, true)

        let result = try awaitAskResult(id, window: owner)
        XCTAssertEqual(result["result"] as? String, "cancelled")
        XCTAssertNil(result["id"])
        XCTAssertEqual(try askResult(id)["result"] as? String, "cancelled")
    }

    func testRightPaneAnchorFollowsResizeAndCancelsWhenHidden() throws {
        let session = try activeSessionID()
        XCTAssertEqual(try sendControlCommand("session.split", target: session, args: ["mode": "on"])["ok"] as? Bool, true)
        XCTAssertTrue(try pollSplit(session, timeout: 10))
        XCTAssertTrue(poll(until: terminalPanes.count == 2, timeout: 10))
        let right = try XCTUnwrap(terminalPanes.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX })
        let id = try openAsk([["id": "ok", "label": "OK"]], target: session, options: ["pane": "right"])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(askDialog.frame.width, 0)
        XCTAssertTrue(poll(until: right.frame.insetBy(dx: -1, dy: -1).contains(askDialog.frame), timeout: 5))
        let before = askDialog.frame
        let width = Int(app.windows.firstMatch.frame.width) + 100

        XCTAssertEqual(try sendControlCommand("window.resize", target: "active",
                                              args: ["width": width, "height": 650])["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: askDialog.frame.width > before.width, timeout: 5))
        XCTAssertTrue(right.frame.insetBy(dx: -1, dy: -1).contains(askDialog.frame))
        XCTAssertEqual(try sendControlCommand("session.focus", target: session, args: ["pane": "left"])["ok"] as? Bool, true)
        XCTAssertEqual(try sendControlCommand("session.split", target: session, args: ["mode": "off"])["ok"] as? Bool, true)
        XCTAssertEqual(try awaitAskResult(id)["result"] as? String, "cancelled")
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
    }

    func testHiddenSessionRejectsAndSelectionChangeCancelsAnchor() throws {
        let original = try activeSessionID()
        let created = try sendControlCommand("session.new", args: ["name": "other"])
        XCTAssertEqual(created["ok"] as? Bool, true)
        let other = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let rejected = try sendControlCommand("ask.open", target: original, args: [
            "title": "Hidden question", "buttons": [["id": "ok", "label": "OK"]],
        ])
        XCTAssertEqual(rejected["ok"] as? Bool, false)
        XCTAssertEqual(rejected["error"] as? String, "session not visible")
        XCTAssertNil(try treeAskPending())
        XCTAssertEqual(try sendControlCommand("session.select", target: original)["ok"] as? Bool, true)
        let id = try openAsk([["id": "ok", "label": "OK"]], target: original)
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))

        XCTAssertEqual(try sendControlCommand("session.select", target: other)["ok"] as? Bool, true)

        XCTAssertEqual(try awaitAskResult(id)["result"] as? String, "cancelled")
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
    }

    func testSessionWideAnchorSpansBothPanesAndSurvivesCollapse() throws {
        let session = try activeSessionID()
        XCTAssertEqual(try sendControlCommand("session.split", target: session, args: ["mode": "on"])["ok"] as? Bool, true)
        XCTAssertTrue(try pollSplit(session, timeout: 10))
        XCTAssertTrue(poll(until: terminalPanes.count == 2, timeout: 10))
        let panes = terminalPanes.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        let area = panes[0].frame.union(panes[1].frame)
        let id = try openAsk([["id": "ok", "label": "OK"]], target: session)
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertEqual(askDialog.frame.midX, area.midX, accuracy: 2)
        XCTAssertGreaterThan(askDialog.frame.width, panes[1].frame.width)

        XCTAssertEqual(try sendControlCommand("session.split", target: session, args: ["mode": "off"])["ok"] as? Bool, true)

        XCTAssertFalse(askDialog.waitForNonExistence(timeout: 1))
        XCTAssertEqual(try askResult(id)["result"] as? String, "pending")
        clickAskButton("ok")
        XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "ok")
    }

    func testUnanchoredAskRendersAboveZoomAndAnchoredAskRejects() throws {
        let session = try activeSessionID()
        XCTAssertEqual(try sendControlCommand("surface.zoom", args: ["mode": "show"])["ok"] as? Bool, true)
        XCTAssertTrue(app.buttons["terminal-zoom-exit"].waitForExistence(timeout: 10))
        let rejected = try sendControlCommand("ask.open", target: session, args: [
            "title": "Covered session", "buttons": [["id": "ok", "label": "OK"]],
        ])
        XCTAssertEqual(rejected["ok"] as? Bool, false)
        XCTAssertEqual(rejected["error"] as? String, "session not visible")
        let id = try openAsk([["id": "ok", "label": "OK"]])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertTrue(askButton("ok").isHittable)

        clickAskButton("ok")

        XCTAssertEqual(try awaitAskResult(id)["result"] as? String, "answered")
        XCTAssertTrue(app.buttons["terminal-zoom-exit"].exists)
    }

    private var terminalPanes: XCUIElementQuery {
        app.textViews.matching(NSPredicate(format: "label == %@", "Terminal"))
    }
}
