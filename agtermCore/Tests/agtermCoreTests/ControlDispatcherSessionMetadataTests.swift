import Foundation
import Testing
@testable import agtermCore

// Dispatcher coverage for the session commands carrying per-session METADATA — flag, context, seen, status
// and restore — mirroring the `SessionMetadataCommands` split on the CLI side. Split out of
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

    @Test func sessionFlagMoveRoutesTheOneAnchorAndItsSide() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        var before = ControlArgs(mode: "move", window: "win")
        before.before = "b"
        var after = ControlArgs(mode: "move")
        after.after = "c"

        #expect(await dispatcher.dispatch(ControlRequest(cmd: .sessionFlag, target: "a", args: before)) == ControlResponse(ok: true))
        #expect(await dispatcher.dispatch(ControlRequest(cmd: .sessionFlag, args: after)) == ControlResponse(ok: true))
        #expect(actions.calls == [
            .flaggedMove(target: "a", window: "win", anchor: "b", .before),
            .flaggedMove(target: nil, window: nil, anchor: "c", .after),
        ])
    }

    @Test func sessionFlagMoveRefusesNoAnchorOrBoth() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        var both = ControlArgs(mode: "move")
        both.before = "b"
        both.after = "c"

        let none = await dispatcher.dispatch(ControlRequest(cmd: .sessionFlag, args: ControlArgs(mode: "move")))
        let two = await dispatcher.dispatch(ControlRequest(cmd: .sessionFlag, args: both))

        let refusal = ControlResponse(ok: false, error: "session.flag move requires exactly one of --before or --after")
        #expect(none == refusal)
        #expect(two == refusal)
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: ["on", "toggle", "clear", nil] as [String?])
    func sessionFlagRefusesAnAnchorOutsideMove(_ mode: String?) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        var args = ControlArgs(mode: mode)
        args.after = "c"

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionFlag, args: args))

        #expect(response == ControlResponse(ok: false, error: "--before and --after apply only to session.flag move"))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionFlagWithoutAModeStillRoutesToTheToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionFlag, target: "a"))

        #expect(actions.calls == [.sessionFlag(target: "a", window: nil, nil)])
    }

    @Test func sessionContextRoutesSetAndClear() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let set = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionContext,
            target: "session",
            args: ControlArgs(text: "  PR #517  ", mode: "set", window: "win")
        ))
        let cleared = await dispatcher.dispatch(ControlRequest(cmd: .sessionContext, args: ControlArgs(mode: "clear")))

        #expect(set == ControlResponse(ok: true))
        #expect(cleared == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionContext(target: "session", window: "win", context: "PR #517"),
            .sessionContext(target: nil, window: nil, context: nil)
        ])
    }

    @Test(arguments: [
        ControlArgs(mode: "set"),
        ControlArgs(text: "PR #517", mode: "clear"),
        ControlArgs(text: "PR #517"),
        ControlArgs(text: "PR #517", mode: "toggle"),
        ControlArgs(text: "   ", mode: "set"),
        ControlArgs(text: "PR\n517", mode: "set"),
    ])
    func sessionContextRejectionNeverReachesTheHost(args: ControlArgs) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionContext, args: args))

        #expect(response?.ok == false)
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionContextRejectsAValueOverTheByteLimit() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let oversized = String(repeating: "a", count: Session.contextByteLimit + 1)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionContext, args: ControlArgs(text: oversized, mode: "set")
        ))

        #expect(response?.ok == false)
        #expect(actions.calls.isEmpty)
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

    @Test func sessionRestartRoutesLinePaneAndTokenToTheHost() async {
        let actions = MockControlActions()
        let receipt = ControlRestartReceipt(paneID: "token", oldPid: 11, newPid: 22)
        actions.nextSessionRestartResponse = ControlResponse(
            ok: true, result: ControlResult(id: "session", pane: "right", restart: receipt))
        let line = #"cld "brief: $HOME/x.md" && echo done | tee log"#

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .sessionRestart, target: "session",
            args: ControlArgs(command: line, window: "win", pane: "split", paneID: "token")
        ))

        #expect(response?.result?.restart == receipt)
        #expect(actions.calls == [
            .sessionRestart(target: "session", window: "win",
                            ControlSessionRestartOptions(command: line, pane: .right, paneID: "token"))
        ])
    }

    @Test func sessionRestartAcceptsEitherSelectorAlone() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestart, target: "session",
                                                     args: ControlArgs(command: "cld", paneID: "token")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionRestart, target: "session",
                                                     args: ControlArgs(command: "cld", pane: "left")))

        #expect(actions.calls == [
            .sessionRestart(target: "session", window: nil,
                            ControlSessionRestartOptions(command: "cld", pane: nil, paneID: "token")),
            .sessionRestart(target: "session", window: nil,
                            ControlSessionRestartOptions(command: "cld", pane: .left, paneID: nil))
        ])
    }

    @Test func sessionRestartWithoutACommandAsksTheHostToReplay() async {
        let actions = MockControlActions()

        _ = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .sessionRestart, target: "session", args: ControlArgs(paneID: "token")))

        #expect(actions.calls == [
            .sessionRestart(target: "session", window: nil,
                            ControlSessionRestartOptions(command: nil, pane: nil, paneID: "token"))
        ])
    }

    @Test(arguments: [
        (ControlArgs(command: "", paneID: "token"), "session.restart takes a non-empty command, or none to replay"),
        (ControlArgs(command: "   ", paneID: "token"), "session.restart takes a non-empty command, or none to replay"),
        (ControlArgs(command: "a\nb", paneID: "token"), "command must not contain control characters"),
        (ControlArgs(command: "cld", pane: "middle"), "--pane must be left, right, or scratch"),
        (ControlArgs(command: "cld", pane: "scratch"), "session.restart does not address the scratch pane"),
        (ControlArgs(command: "cld"), "session.restart requires --pane-id or --pane"),
        (ControlArgs(command: "cld", paneID: ""), "session.restart requires --pane-id or --pane"),
        (ControlArgs(command: String(repeating: "a", count: ControlSessionRestartOptions.maxCommandBytes + 1),
                     paneID: "token"),
         "command too long (max \(ControlSessionRestartOptions.maxCommandBytes) bytes)")
    ])
    func sessionRestartRejectsBeforeTheHost(args: ControlArgs, error: String) async {
        let actions = MockControlActions()

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .sessionRestart, target: "session", args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test func sessionTintSetRoutesColorAndParsedParts() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let bare = await dispatcher.dispatch(ControlRequest(cmd: .sessionTint, target: "s",
                                                            args: ControlArgs(mode: "set", window: "w", tint: "Red")))
        let placed = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionTint, args: ControlArgs(mode: "set", tint: "blue", tintOn: ["name", "icon"])))
        let cleared = await dispatcher.dispatch(ControlRequest(cmd: .sessionTint, args: ControlArgs(mode: "clear")))

        #expect(bare == ControlResponse(ok: true) && placed == ControlResponse(ok: true) && cleared == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionTint(target: "s", window: "w", .set(.red, parts: nil)),
            .sessionTint(target: nil, window: nil, .set(.blue, parts: [.icon, .name])),
            .sessionTint(target: nil, window: nil, .clear),
        ])
    }

    @Test func workspaceTintRoutesToTheWorkspaceAction() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceTint, target: "ws", args: ControlArgs(mode: "set", tint: "gray", tintOn: ["name"])))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceTint(target: "ws", window: nil, .set(.gray, parts: [.name]))])
    }

    @Test(arguments: [
        (ControlArgs(mode: "set"), "session.tint set requires a color"),
        (ControlArgs(mode: "set", tint: "teal"), "invalid tint: teal (red|orange|yellow|green|blue|purple|gray)"),
        (ControlArgs(mode: "set", tint: "red", tintOn: ["strip"]), "invalid tint placement: strip (icon,name)"),
        (ControlArgs(mode: "set", tint: "red", tintOn: []), "invalid tint placement:  (icon,name)"),
        (ControlArgs(mode: "clear", tint: "red"), "session.tint clear takes no color or placement"),
        (ControlArgs(mode: "clear", tintOn: ["icon"]), "session.tint clear takes no color or placement"),
        (ControlArgs(tint: "red"), "invalid tint mode:  (set|clear)"),
    ])
    func sessionTintRefusesContradictoryOrUnknownInput(_ tc: (ControlArgs, String)) async {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .sessionTint, args: tc.0))

        #expect(response == ControlResponse(ok: false, error: tc.1))
        #expect(actions.calls.isEmpty)
    }

    // a host predating tints must refuse the tint, never create an untinted session and answer ok.
    @Test func sessionNewThroughTheDefaultOverloadRefusesATint() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let plain = await dispatcher.dispatch(ControlRequest(cmd: .sessionNew, args: ControlArgs(name: "s")))
        let tinted = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionNew, args: ControlArgs(tint: "red", tintOn: ["name"])))

        #expect(plain?.ok == true)
        #expect(tinted == ControlResponse(ok: false, error: "session.new --tint is not supported on this platform"))
        #expect(actions.calls == [.sessionNew(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, name: "s"))])
    }

    @Test(arguments: [
        (ControlArgs(tintOn: ["icon"]), "--tint-on requires --tint"),
        (ControlArgs(tint: "teal"), "invalid tint: teal (red|orange|yellow|green|blue|purple|gray)"),
        (ControlArgs(tint: "red", tintOn: ["both"]), "invalid tint placement: both (icon,name)"),
    ])
    func creationRefusesABadTintBeforeCreatingAnything(_ tc: (ControlArgs, String)) async {
        let (args, error) = tc
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        var named = args
        named.workspaceName = "new"
        named.createWorkspace = true

        let session = await dispatcher.dispatch(ControlRequest(cmd: .sessionNew, args: named))
        let workspace = await dispatcher.dispatch(ControlRequest(cmd: .workspaceNew, args: args))

        #expect(session == ControlResponse(ok: false, error: error))
        #expect(workspace == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    // a host predating tints must refuse the tint, never create an untinted workspace and answer ok.
    @Test func workspaceNewThroughTheDefaultOverloadRefusesATint() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let plain = await dispatcher.dispatch(ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "w")))
        let tinted = await dispatcher.dispatch(ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "t", tint: "red")))

        #expect(plain == ControlResponse(ok: true))
        #expect(tinted == ControlResponse(ok: false, error: "workspace.new --tint is not supported on this platform"))
        #expect(actions.calls == [.workspaceNew(window: nil, "w", collapsed: false)])
    }
}
