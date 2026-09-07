import XCTest

@MainActor
final class ControlAskUITests: ControlAPITestCase {
    func testLeftPaneKeepsTypingWhileRightAskConsumesItsAnswer() throws {
        let received = markerDir.appendingPathComponent("right-input")
        let ready = markerDir.appendingPathComponent("right-ready")
        let command = "sh -c 'touch \"\(received.path)\"; printf ready > \"\(ready.path)\"; exec tee -a \"\(received.path)\"'"
        let session = try splitActiveSession()
        XCTAssertEqual(try typeUntilMarker(command + "\n", target: session, file: ready, select: false,
                                          pane: "right", attempts: 1, perAttempt: 10), "ready")
        let before = markerDir.appendingPathComponent("left-before")
        let leftTTY = try XCTUnwrap(typeUntilMarker("tty > '\(before.path)'\n", target: session, file: before, select: false, pane: "left"))
        XCTAssertEqual(try sendControlCommand("session.focus", target: session, args: ["pane": "left"])["ok"] as? Bool, true)
        let id = try openAskCLI(["--pane", "right", "--button", "stay=Stay"])
        XCTAssertTrue(askButton("stay").waitForExistence(timeout: 10))
        let after = markerDir.appendingPathComponent("left-after")
        XCTAssertEqual(keyboardTypeUntilMarker("tty > '\(after.path)'", file: after), leftTTY)
        XCTAssertEqual(try askResult(id)["result"] as? String, "pending")
        XCTAssertEqual(try Data(contentsOf: received).count, 0)
        askDialog.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).click()
        XCTAssertTrue(try pollSplitFocused(session, expected: true, timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "stay")
        XCTAssertEqual(try Data(contentsOf: received).count, 0)
        XCTAssertEqual(try sendControlCommand("session.focus", target: session, args: ["pane": "left"])["ok"] as? Bool, true)
        let neutral = try openAsk([["id": "neutral", "label": "Answer"]], options: ["pane": "right"])
        clickAskButton("neutral")
        XCTAssertEqual(try awaitAskResult(neutral)["id"] as? String, "neutral")
        XCTAssertEqual(try sessionNode(id: session)["splitFocused"] as? Bool, false)
        let afterClick = markerDir.appendingPathComponent("left-after-answer-click")
        XCTAssertEqual(keyboardTypeUntilMarker("tty > '\(afterClick.path)'", file: afterClick), leftTTY)
    }

    func testTwoSessionsKeepAsksWhileGUIOwnsTheKeyboard() throws {
        let firstSession = try activeSessionID()
        let secondSession = try newSession("second", select: false)
        let first = try openAsk([["id": "first-answer", "label": "First"]], target: firstSession)
        let second = try openAsk([["id": "second-answer", "label": "Second"]], target: secondSession)
        XCTAssertEqual(try sessionAskPending(firstSession), first)
        XCTAssertEqual(try sessionAskPending(secondSession), second)
        XCTAssertFalse(askButton("second-answer").exists)
        let gui = try openAsk([["id": "gui-answer", "label": "GUI"]], options: ["style": "gui"])
        XCTAssertTrue(askButton("gui-answer").waitForExistence(timeout: 10))
        XCTAssertEqual(try treeAskPending(), gui)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(gui)["id"] as? String, "gui-answer")
        XCTAssertEqual(try askResult(first)["result"] as? String, "pending")
        XCTAssertEqual(try askResult(second)["result"] as? String, "pending")
        XCTAssertEqual(try sendControlCommand("session.select", target: secondSession)["ok"] as? Bool, true)
        XCTAssertTrue(askButton("second-answer").waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(second)["id"] as? String, "second-answer")
        XCTAssertEqual(try askResult(first)["result"] as? String, "pending")
        XCTAssertEqual(try sendControlCommand("session.select", target: firstSession)["ok"] as? Bool, true)
        XCTAssertTrue(askButton("first-answer").waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(first)["id"] as? String, "first-answer")
    }

    func testPickTemporarilyTakesKeyboardFromTerminalAsk() throws {
        let ask = try openAsk([["id": "resume", "label": "Resume"]])
        XCTAssertTrue(askButton("resume").waitForExistence(timeout: 10))
        let opened = try sendControlCommand("pick.open", args: ["items": [["id": "picked", "label": "Pick me"]]])
        XCTAssertEqual(opened["ok"] as? Bool, true)
        let pick = try XCTUnwrap((opened["result"] as? [String: Any])?["id"] as? String)
        let palette = app.descendants(matching: .any).matching(identifier: "pick-palette").firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(palette.waitForNonExistence(timeout: 10))
        let response = try sendControlCommand("pick.result", target: pick)
        let result = try XCTUnwrap((response["result"] as? [String: Any])?["pick"] as? [String: Any])
        XCTAssertEqual(result["id"] as? String, "picked")
        XCTAssertEqual(try askResult(ask)["result"] as? String, "pending")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(ask)["id"] as? String, "resume")
    }

    func testOverlayExitAndSiblingCloseKeepAskKeyboardWhileTargetCloseCancels() throws {
        let session = try splitActiveSession()
        let release = markerDir.appendingPathComponent("exit-overlay")
        let command = "sh -c 'while [ ! -e \"\(release.path)\" ]; do sleep 0.1; done'"
        XCTAssertEqual(try sendControlCommand("session.overlay.open", target: session, args: ["command": command])["ok"] as? Bool, true)
        let first = try openAsk([["id": "after-overlay", "label": "Continue"]], options: ["pane": "right"])
        XCTAssertTrue(askButton("after-overlay").waitForExistence(timeout: 10))
        try Data("exit".utf8).write(to: release)
        XCTAssertTrue(poll(until: (try? sessionNode(id: session)["overlay"] as? Bool) == false, timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(first)["id"] as? String, "after-overlay")
        XCTAssertEqual(try sendControlCommand("session.focus", target: session, args: ["pane": "left"])["ok"] as? Bool, true)
        let second = try openAsk([["id": "after-sibling", "label": "Continue"]], options: ["pane": "left"])
        XCTAssertTrue(askButton("after-sibling").waitForExistence(timeout: 10))
        XCTAssertEqual(try sendControlCommand("session.split.close", target: session)["ok"] as? Bool, true)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(second)["id"] as? String, "after-sibling")
        _ = try splitActiveSession()
        let third = try openAsk([["id": "closed-target", "label": "Continue"]], options: ["pane": "right"])
        XCTAssertTrue(askButton("closed-target").waitForExistence(timeout: 10))
        XCTAssertEqual(try sendControlCommand("session.split.close", target: session)["ok"] as? Bool, true)
        XCTAssertEqual(try askResult(third)["result"] as? String, "cancelled")
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
    }

    func testZoomHidesAskAndLetsTheZoomedTerminalReceiveKeys() throws {
        let session = try activeSessionID()
        let ask = try openAsk([["id": "after-zoom", "label": "Continue"]])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertEqual(try sendControlCommand("surface.zoom", args: ["mode": "show"])["ok"] as? Bool, true)
        XCTAssertTrue(app.buttons["terminal-zoom-exit"].waitForExistence(timeout: 10))
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
        let marker = markerDir.appendingPathComponent("zoom-typing")
        XCTAssertEqual(keyboardTypeUntilMarker("printf zoom > '\(marker.path)'", file: marker), "zoom")
        XCTAssertEqual(try askResult(ask)["result"] as? String, "pending")
        XCTAssertEqual(try sessionAskPending(session), ask)
        XCTAssertEqual(try sendControlCommand("surface.zoom", args: ["mode": "hide"])["ok"] as? Bool, true)
        XCTAssertTrue(askButton("after-zoom").waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(ask)["id"] as? String, "after-zoom")
    }

    func testScratchKeepsSessionAskAboveItAndHidesPaneAsk() throws {
        let session = try activeSessionID()
        let whole = try openAsk([["id": "whole", "label": "Continue"]])
        XCTAssertTrue(askButton("whole").waitForExistence(timeout: 10))
        XCTAssertEqual(try sendControlCommand("session.scratch", target: session, args: ["mode": "on"])["ok"] as? Bool, true)
        XCTAssertTrue(poll(until: (try? sessionNode(id: session)["scratch"] as? Bool) == true, timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(whole)["id"] as? String, "whole")
        XCTAssertEqual(try sendControlCommand("session.scratch", target: session, args: ["mode": "off"])["ok"] as? Bool, true)
        _ = try splitActiveSession()
        let pane = try openAsk([["id": "pane", "label": "Continue"]], options: ["pane": "right"])
        XCTAssertTrue(askButton("pane").waitForExistence(timeout: 10))
        XCTAssertEqual(try sendControlCommand("session.scratch", target: session, args: ["mode": "on"])["ok"] as? Bool, true)
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
        let marker = markerDir.appendingPathComponent("scratch-typing")
        XCTAssertEqual(keyboardTypeUntilMarker("printf scratch > '\(marker.path)'", file: marker), "scratch")
        XCTAssertEqual(try askResult(pane)["result"] as? String, "pending")
        XCTAssertEqual(try sendControlCommand("session.scratch", target: session, args: ["mode": "off"])["ok"] as? Bool, true)
        XCTAssertTrue(askButton("pane").waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(try awaitAskResult(pane)["id"] as? String, "pane")
    }

    func testAnsweredAskThenSocketCloseFocusesTheReselectedSession() throws {
        let neighbour = try activeSessionID()
        let before = markerDir.appendingPathComponent("neighbour-tty")
        let neighbourTTY = try XCTUnwrap(typeUntilMarker("tty > '\(before.path)'\n", target: neighbour, file: before, select: false))
        for style in ["terminal", "gui"] {
            let closing = try newSession("closing-\(style)", select: true)
            XCTAssertTrue(poll(until: (try? sessionNode(id: closing)["active"] as? Bool) == true, timeout: 10))
            let ask = try openAsk([["id": "close", "label": "Close"]], target: closing, options: ["style": style])
            XCTAssertTrue(askButton("close").waitForExistence(timeout: 10))
            app.typeKey(.return, modifierFlags: [])
            XCTAssertEqual(try awaitAskResult(ask)["id"] as? String, "close")
            XCTAssertEqual(try sendControlCommand("session.close", target: closing)["ok"] as? Bool, true)
            XCTAssertEqual(try sessionNode(id: neighbour)["active"] as? Bool, true)
            let after = markerDir.appendingPathComponent("neighbour-after-\(style)")
            XCTAssertEqual(keyboardTypeUntilMarker("tty > '\(after.path)'", file: after, attempts: 1, perAttempt: 5), neighbourTTY, style)
        }
    }

    func testSoftCloseCancelsImmediatelyAndUndoDoesNotRestoreAsk() throws {
        let first = try newSession("closing-a", select: false)
        let second = try newSession("closing-b", select: false)
        let ask = try openAsk([["id": "discarded", "label": "Continue"]], target: first)
        XCTAssertEqual(try sendControlCommand("session.close", args: ["targets": [first, second]])["ok"] as? Bool, true)
        XCTAssertEqual(try askResult(ask)["result"] as? String, "cancelled")
        XCTAssertNil(try sessionNodeIfPresent(id: first))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(poll(until: (try? sessionNodeIfPresent(id: first)) != nil, timeout: 10))
        XCTAssertNil(try sessionAskPending(first))
        XCTAssertEqual(try askResult(ask)["result"] as? String, "cancelled")
        XCTAssertFalse(askButton("discarded").exists)
    }

    func testButtonsShareWidthInBothLayoutsAndStyles() throws {
        for style in ["terminal", "gui"] {
            for width in [20, 80] {
                let id = try openAsk([["id": "ok", "label": "OK"], ["id": "cancel", "label": "Cancel everything"]],
                                     options: ["style": style, "width": width])
                XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
                let first = askButton("ok").frame
                let last = askButton("cancel").frame
                XCTAssertEqual(first.width, last.width, accuracy: 1)
                if width == 20 {
                    XCTAssertGreaterThan(last.midY, first.midY)
                    XCTAssertGreaterThan(last.height, first.height)
                } else {
                    XCTAssertEqual(first.midY, last.midY, accuracy: 1)
                    XCTAssertGreaterThan(last.midX, first.midX)
                }
                clickAskButton("cancel")
                XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "cancel")
                XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
            }
        }
    }

    func testCLIFixedWidthHonorsRangeInBothStyles() throws {
        let session = try activeSessionID()
        let anchor = terminalPanes.firstMatch.frame
        for style in ["terminal", "gui"] {
            for width in [10, 50, 100] {
                let id = try openAskCLI(["--style", style, "--target", session, "--width", String(width), "--button", "ok=OK"])
                XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
                XCTAssertEqual(askDialog.frame.width, anchor.width * Double(width) / 100, accuracy: 2)
                XCTAssertEqual(askDialog.frame.midX, anchor.midX, accuracy: 2)
                clickAskButton("ok")
                XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "ok")
                XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
            }
        }
    }

    func testButtonBlockAlignmentInBothStylesAndLayouts() throws {
        for style in ["terminal", "gui"] {
            for vertical in [false, true] {
                let label = vertical ? "A longer choice that forces the button row to wrap" : "First"
                for align in ["left", "center", "right"] {
                    let id = try openAsk([["id": "first", "label": label], ["id": "last", "label": label]],
                                         title: "Choose what happens next for the current working session and its files",
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
        XCTAssertEqual(try sessionAskPending(try activeSessionID()), id)
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
        XCTAssertEqual(try sessionAskPending(try activeSessionID()), id)
        XCTAssertEqual(try sendControlCommand("ask.cancel", target: id)["ok"] as? Bool, true)
    }

    func testGUIAskAndPickRejectCompetingOpenRequests() throws {
        let picked = try sendControlCommand("pick.open", args: ["items": [["id": "one", "label": "One"]]])
        XCTAssertEqual(picked["ok"] as? Bool, true)
        let pickID = try XCTUnwrap((picked["result"] as? [String: Any])?["id"] as? String)
        let picker = app.descendants(matching: .any).matching(identifier: "pick-palette").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let rejectedAsk = try sendControlCommand("ask.open", args: [
            "style": "gui", "title": "Competing question", "buttons": [["id": "ok", "label": "OK"]],
        ])
        XCTAssertEqual(rejectedAsk["ok"] as? Bool, false)
        XCTAssertNil(try treeAskPending())
        XCTAssertEqual(try sendControlCommand("pick.cancel", target: pickID)["ok"] as? Bool, true)
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10))

        let askID = try openAsk([["id": "ok", "label": "OK"]], options: ["style": "gui"])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        let rejectedPick = try sendControlCommand("pick.open", args: ["items": [["id": "one", "label": "One"]]])
        XCTAssertEqual(rejectedPick["ok"] as? Bool, false)
        XCTAssertEqual(try treeAskPending(), askID)
        XCTAssertEqual(try askResult(askID)["result"] as? String, "pending")
    }

    func testGUIPendingAskRefusesControlDrivenCovers() throws {
        let session = try activeSessionID()
        let id = try openAsk([["id": "ok", "label": "OK"]], options: ["style": "gui"])
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

    func testRightPaneAnchorFollowsResizeAndStaysPendingWhenHidden() throws {
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
        XCTAssertTrue(poll(until: askDialog.frame.midX > before.midX, timeout: 5))
        XCTAssertTrue(right.frame.insetBy(dx: -1, dy: -1).contains(askDialog.frame))
        XCTAssertEqual(try sendControlCommand("session.focus", target: session, args: ["pane": "left"])["ok"] as? Bool, true)
        XCTAssertEqual(try sendControlCommand("session.split", target: session, args: ["mode": "off"])["ok"] as? Bool, true)
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try askResult(id)["result"] as? String, "pending")
        XCTAssertEqual(try sessionAskPending(session), id)
        XCTAssertEqual(try sendControlCommand("session.split", target: session, args: ["mode": "on"])["ok"] as? Bool, true)
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        clickAskButton("ok")
        XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "ok")
    }

    func testGUIHiddenSessionRejectsAndSelectionChangeCancelsAnchor() throws {
        let original = try activeSessionID()
        let created = try sendControlCommand("session.new", args: ["name": "other"])
        XCTAssertEqual(created["ok"] as? Bool, true)
        let other = try XCTUnwrap((created["result"] as? [String: Any])?["id"] as? String)
        let rejected = try sendControlCommand("ask.open", target: original, args: [
            "style": "gui", "title": "Hidden question", "buttons": [["id": "ok", "label": "OK"]],
        ])
        XCTAssertEqual(rejected["ok"] as? Bool, false)
        XCTAssertEqual(rejected["error"] as? String, "session not visible")
        XCTAssertNil(try treeAskPending())
        XCTAssertEqual(try sendControlCommand("session.select", target: original)["ok"] as? Bool, true)
        let id = try openAsk([["id": "ok", "label": "OK"]], target: original, options: ["style": "gui"])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))

        XCTAssertEqual(try sendControlCommand("session.select", target: other)["ok"] as? Bool, true)

        XCTAssertEqual(try awaitAskResult(id)["result"] as? String, "cancelled")
        XCTAssertTrue(askDialog.waitForNonExistence(timeout: 10))
    }

    func testSessionWideAnchorCentersAcrossBothPanesAndSurvivesCollapse() throws {
        let session = try activeSessionID()
        XCTAssertEqual(try sendControlCommand("session.split", target: session, args: ["mode": "on"])["ok"] as? Bool, true)
        XCTAssertTrue(try pollSplit(session, timeout: 10))
        XCTAssertTrue(poll(until: terminalPanes.count == 2, timeout: 10))
        let panes = terminalPanes.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        let area = panes[0].frame.union(panes[1].frame)
        let id = try openAsk([["id": "ok", "label": "OK"]], target: session)
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertEqual(askDialog.frame.midX, area.midX, accuracy: 2)
        XCTAssertLessThanOrEqual(askDialog.frame.width, area.width * 0.9)

        XCTAssertEqual(try sendControlCommand("session.split", target: session, args: ["mode": "off"])["ok"] as? Bool, true)

        XCTAssertFalse(askDialog.waitForNonExistence(timeout: 1))
        XCTAssertEqual(try askResult(id)["result"] as? String, "pending")
        clickAskButton("ok")
        XCTAssertEqual(try awaitAskResult(id)["id"] as? String, "ok")
    }

    func testGUIUnanchoredAskRendersAboveZoomAndAnchoredAskRejects() throws {
        let session = try activeSessionID()
        XCTAssertEqual(try sendControlCommand("surface.zoom", args: ["mode": "show"])["ok"] as? Bool, true)
        XCTAssertTrue(app.buttons["terminal-zoom-exit"].waitForExistence(timeout: 10))
        let rejected = try sendControlCommand("ask.open", target: session, args: [
            "style": "gui", "title": "Covered session", "buttons": [["id": "ok", "label": "OK"]],
        ])
        XCTAssertEqual(rejected["ok"] as? Bool, false)
        XCTAssertEqual(rejected["error"] as? String, "session not visible")
        let id = try openAsk([["id": "ok", "label": "OK"]], options: ["style": "gui"])
        XCTAssertTrue(askDialog.waitForExistence(timeout: 10))
        XCTAssertTrue(askButton("ok").isHittable)

        clickAskButton("ok")

        XCTAssertEqual(try awaitAskResult(id)["result"] as? String, "answered")
        XCTAssertTrue(app.buttons["terminal-zoom-exit"].exists)
    }

    private func newSession(_ name: String, select: Bool) throws -> String {
        let response = try sendControlCommand("session.new", args: ["name": name, "noSelect": !select])
        XCTAssertEqual(response["ok"] as? Bool, true)
        return try XCTUnwrap((response["result"] as? [String: Any])?["id"] as? String)
    }

    private func splitActiveSession() throws -> String {
        let session = try activeSessionID()
        XCTAssertEqual(try sendControlCommand("session.split", target: session, args: ["mode": "on"])["ok"] as? Bool, true)
        XCTAssertTrue(try pollSplit(session, timeout: 10))
        XCTAssertTrue(poll(until: terminalPanes.count == 2, timeout: 10))
        return session
    }

    private func sessionAskPending(_ session: String) throws -> String? {
        (try sessionNode(id: session)["ask"] as? [String: Any])?["id"] as? String
    }

    private var terminalPanes: XCUIElementQuery {
        app.textViews.matching(NSPredicate(format: "label == %@", "Terminal"))
    }
}
