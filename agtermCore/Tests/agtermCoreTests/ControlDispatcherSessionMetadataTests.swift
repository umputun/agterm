import Foundation
import Testing
@testable import agtermCore

// Dispatcher coverage for the session commands carrying per-session METADATA — flag, seen, status and
// restore — mirroring the `SessionMetadataCommands` split on the CLI side. Split out of
// `ControlDispatcherTests.swift` for the file size limit.
@MainActor
struct ControlDispatcherSessionMetadataTests {
    @Test func sessionFlagRoutesModeForHostSideValidation() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let flagged = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionFlag,
            target: "session",
            args: ControlArgs(mode: "on", window: "win")
        ))
        let cleared = await dispatcher.dispatch(ControlRequest(cmd: .sessionFlag, args: ControlArgs(mode: "clear")))

        #expect(flagged == ControlResponse(ok: true))
        #expect(cleared == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionFlag(target: "session", window: "win", "on"),
            .sessionFlag(target: nil, window: nil, "clear")
        ])
    }

    @Test func sessionSeenRoutesTargetAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let seen = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionSeen,
            target: "session",
            args: ControlArgs(window: "win")
        ))
        let active = await dispatcher.dispatch(ControlRequest(cmd: .sessionSeen))

        #expect(seen == ControlResponse(ok: true))
        #expect(active == ControlResponse(ok: true))
        #expect(actions.calls == [
            .markSessionSeen(target: "session", window: "win"),
            .markSessionSeen(target: nil, window: nil)
        ])
    }

    @Test func sessionStatusRoutesParsedStatusAndRejectsInvalidStatus() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let status = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(window: "win", status: "blocked", blink: true,
                              autoReset: true, sound: "default", color: "#ff0000")
        ))
        let bad = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(status: "bogus")
        ))
        let badColor = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(status: "blocked", color: "nope")
        ))

        #expect(status == ControlResponse(ok: true))
        #expect(bad == ControlResponse(ok: false, error: "invalid status"))
        #expect(badColor == ControlResponse(ok: false, error: "invalid color (expected #rrggbb)"))
        #expect(actions.calls == [
            .sessionStatus(target: "session", window: "win",
                           ControlSessionStatusUpdate(status: .blocked, blink: true,
                                                      autoReset: true, sound: "default", color: "#ff0000", pane: nil))
        ])
    }

    @Test func sessionStatusRevertsColorWhenOmitted() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        // the second update must carry color nil: the app arm builds a fresh AgentIndicator from
        // update.color, so a call without --color clears the tint.
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionStatus, target: "session",
                                                     args: ControlArgs(status: "blocked", color: "#ff0000")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionStatus, target: "session",
                                                     args: ControlArgs(status: "blocked")))

        #expect(actions.calls == [
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .blocked, blink: nil, autoReset: nil,
                                                      sound: nil, color: "#ff0000")),
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .blocked, blink: nil, autoReset: nil,
                                                      sound: nil, color: nil))
        ])
    }

    @Test func sessionStatusCarriesValidPaneAndRejectsInvalidPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        // the opaque --pane-id rides through untouched alongside a valid role --pane (the app-side arm, not
        // the dispatcher, resolves the token against the session's live surfaces).
        let tagged = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(pane: "right", paneID: "agent-tok", status: "blocked")
        ))
        let badPane = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(pane: "middle", status: "blocked")
        ))

        #expect(tagged == ControlResponse(ok: true))
        #expect(badPane == ControlResponse(ok: false, error: "--pane must be left, right, or scratch"))
        #expect(actions.calls == [
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .blocked, blink: nil, autoReset: nil,
                                                      sound: nil, pane: .right, paneID: "agent-tok"))
        ])
    }

    @Test(arguments: StatusShape.allCases)
    func sessionStatusCarriesEveryValidShape(_ shape: StatusShape) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(status: "blocked", shape: shape.rawValue)
        ))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .blocked, blink: nil, autoReset: nil,
                                                      sound: nil, shape: shape))
        ])
    }

    @Test func sessionStatusForwardsShapeOnlyWhenTheArgIsPresent() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        // present → the parsed shape, absent → nil. The user-facing "next call without --shape discards
        // it" contract is the store's (AppStoreTests.controlTreeDropsStatusShapeOnTheNextSetWithoutOne).
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionStatus, target: "session",
                                                     args: ControlArgs(status: "blocked", shape: "triangle")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionStatus, target: "session",
                                                     args: ControlArgs(status: "blocked")))

        #expect(actions.calls == [
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .blocked, blink: nil, autoReset: nil,
                                                      sound: nil, shape: .triangle)),
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .blocked, blink: nil, autoReset: nil,
                                                      sound: nil, shape: nil))
        ])
    }

    @Test func sessionStatusRejectsInvalidShapeWithoutMutating() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(status: "blocked", shape: "hexagon")
        ))

        // the accepted set in the message is derived from allCases, so it tracks the enum.
        let accepted = StatusShape.allCases.map(\.rawValue).joined(separator: "|")
        #expect(response == ControlResponse(ok: false, error: "invalid shape: hexagon (\(accepted))"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionStatusAcceptsShapeOnIdle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        // idle renders no glyph, so a shape is accepted and simply carries nothing to draw — same as --color.
        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(status: "idle", shape: "star")
        ))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionStatus(target: "session", window: nil,
                           ControlSessionStatusUpdate(status: .idle, blink: nil, autoReset: nil,
                                                      sound: nil, shape: .star))
        ])
    }

    @Test func sessionStatusColorErrorWinsOverInvalidPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus,
            target: "session",
            args: ControlArgs(pane: "middle", status: "blocked", color: "nope")
        ))

        #expect(response == ControlResponse(ok: false, error: "invalid color (expected #rrggbb)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionStatusValidatesColorThenShapeThenPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let accepted = StatusShape.allCases.map(\.rawValue).joined(separator: "|")

        // pin both boundaries, so reordering the three guards cannot change which error a caller sees
        // without failing here.
        let colorOverShape = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus, target: "session",
            args: ControlArgs(status: "blocked", color: "nope", shape: "hexagon")
        ))
        let shapeOverPane = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionStatus, target: "session",
            args: ControlArgs(pane: "middle", status: "blocked", shape: "hexagon")
        ))

        #expect(colorOverShape == ControlResponse(ok: false, error: "invalid color (expected #rrggbb)"))
        #expect(shapeOverPane == ControlResponse(ok: false, error: "invalid shape: hexagon (\(accepted))"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionRestoreRoutesEachModeToTheHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionRestoreResponse = ControlResponse(ok: true, result: ControlResult(id: "session"))

        let set = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionRestore, target: "session",
            args: ControlArgs(mode: "set", command: "claude --resume abc", window: "win")
        ))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestore, target: "session",
                                                     args: ControlArgs(mode: "none")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestore, target: "session",
                                                     args: ControlArgs(mode: "clear")))

        #expect(set == ControlResponse(ok: true, result: ControlResult(id: "session")))
        #expect(actions.calls == [
            .sessionRestore(target: "session", window: "win",
                            ControlSessionRestoreUpdate(pin: .pin("claude --resume abc"))),
            .sessionRestore(target: "session", window: nil, ControlSessionRestoreUpdate(pin: .pinNone)),
            .sessionRestore(target: "session", window: nil, ControlSessionRestoreUpdate(pin: .unpin))
        ])
    }

    @Test func sessionRestoreCarriesPaneAndPaneIDThrough() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionRestore, target: "session",
            args: ControlArgs(mode: "set", command: "htop", pane: "right", paneID: "pane-tok")
        ))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionRestore(target: "session", window: nil,
                            ControlSessionRestoreUpdate(pin: .pin("htop"), pane: .right, paneID: "pane-tok"))
        ])
    }

    @Test func sessionRestoreKeepsShellMetacharactersVerbatim() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        // a pinned value is a SHELL LINE: operators, quotes, and variables are the point and must reach
        // the host unmodified (never re-quoted).
        let line = "cd \"$HOME/dev\" && claude --resume abc | tee /tmp/x; echo done"
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestore, target: "session",
                                                     args: ControlArgs(mode: "set", command: line)))

        #expect(actions.calls == [
            .sessionRestore(target: "session", window: nil, ControlSessionRestoreUpdate(pin: .pin(line)))
        ])
    }

    @Test func sessionRestoreRejectsBadModeAndMissingCommand() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let unknown = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestore, target: "session",
                                                               args: ControlArgs(mode: "pin")))
        let missingMode = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestore, target: "session"))
        let noCommand = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestore, target: "session",
                                                                  args: ControlArgs(mode: "set")))

        #expect(unknown == ControlResponse(ok: false, error: "invalid restore mode: pin (set|none|clear)"))
        #expect(missingMode == ControlResponse(ok: false, error: "invalid restore mode:  (set|none|clear)"))
        #expect(noCommand == ControlResponse(ok: false, error: "session.restore set requires a command"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionRestoreSetWithAnEmptyCommandPinsNothing() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        // an empty command is the tri-state's "pinned to nothing" — the same state `none` writes — so it
        // reaches the host as `.pin("")` and `agtermctl session restore ""` agrees with `--none`.
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestore, target: "session",
                                                     args: ControlArgs(mode: "set", command: "")))

        #expect(actions.calls == [
            .sessionRestore(target: "session", window: nil, ControlSessionRestoreUpdate(pin: .pin("")))
        ])
    }

    @Test func sessionRestoreRejectsControlCharactersAndBadPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let newline = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionRestore, target: "session",
            args: ControlArgs(mode: "set", command: "echo one\necho two")
        ))
        let tab = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionRestore, target: "session",
            args: ControlArgs(mode: "set", command: "echo\tone")
        ))
        let badPane = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionRestore, target: "session",
            args: ControlArgs(mode: "set", command: "htop", pane: "middle")
        ))

        // the message names the whole control-character class, so a tab rejection is not called multi-line.
        #expect(newline == ControlResponse(ok: false, error: "command must not contain control characters"))
        #expect(tab == ControlResponse(ok: false, error: "command must not contain control characters"))
        #expect(badPane == ControlResponse(ok: false, error: "--pane must be left, right, or scratch"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionRestoreRejectsInvalidPaneOnNonSetModes() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let none = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestore, target: "session",
                                                             args: ControlArgs(mode: "none", pane: "middle")))
        let clear = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestore, target: "session",
                                                              args: ControlArgs(mode: "clear", pane: "middle")))

        #expect(none == ControlResponse(ok: false, error: "--pane must be left, right, or scratch"))
        #expect(clear == ControlResponse(ok: false, error: "--pane must be left, right, or scratch"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionRestoreCapsCommandAtByteLimitNotGraphemeCount() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let cap = ControlRestoreOverride.maxCommandBytes

        let exact = String(repeating: "a", count: cap)
        let over = String(repeating: "a", count: cap + 1)
        // 400 four-byte scalars = 1600 UTF-8 bytes but only 400 characters: under the cap by grapheme
        // count, over it by BYTES — the cap is a storage bound, so this must be rejected.
        let multiByte = String(repeating: "🌍", count: 400)

        let exactResponse = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionRestore, target: "session", args: ControlArgs(mode: "set", command: exact)))
        let overResponse = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionRestore, target: "session", args: ControlArgs(mode: "set", command: over)))
        let multiByteResponse = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionRestore, target: "session", args: ControlArgs(mode: "set", command: multiByte)))

        #expect(multiByte.count < cap)
        #expect(multiByte.utf8.count > cap)
        #expect(exactResponse == ControlResponse(ok: true))
        #expect(overResponse == ControlResponse(ok: false, error: "command too long (max \(cap) bytes)"))
        #expect(multiByteResponse == ControlResponse(ok: false, error: "command too long (max \(cap) bytes)"))
        #expect(actions.calls == [
            .sessionRestore(target: "session", window: nil, ControlSessionRestoreUpdate(pin: .pin(exact)))
        ])
    }
}
