import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherHudTests {
    @Test func openRejectsMissingAndEmptyMessageWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen))
        let empty = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                             args: ControlArgs(message: "", detail: "still here")))

        let expected = ControlResponse(ok: false, error: "session.hud.open requires a message")
        #expect(missing == expected)
        #expect(empty == expected)
        #expect(actions.calls.isEmpty)
    }

    // `HudLayout.wrap` drops whitespace-only text, so a blank message would paint an empty frame while
    // `tree` reported a live HUD.
    @Test func openRejectsAWhitespaceOnlyMessage() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let blank = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                             args: ControlArgs(message: "   ")))

        #expect(blank == ControlResponse(ok: false, error: "session.hud.open requires a message"))
        #expect(actions.calls.isEmpty)
    }

    @Test func updateRejectsMissingAndEmptyMessageWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudUpdate))
        let empty = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudUpdate, args: ControlArgs(message: "")))

        let expected = ControlResponse(ok: false, error: "session.hud.update requires a message")
        #expect(missing == expected)
        #expect(empty == expected)
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsControlCharactersInMessageAndDetailWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let escape = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                              args: ControlArgs(message: "paint\u{1b}[2Jme")))
        let newline = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                               args: ControlArgs(message: "two\nlines")))
        let detail = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudUpdate,
            args: ControlArgs(message: "fine", detail: "bad\u{7f}")
        ))

        let expected = ControlResponse(ok: false, error: "hud text must not contain control characters")
        #expect(escape == expected)
        #expect(newline == expected)
        #expect(detail == expected)
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsOversizedMessageAndDetailWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let tooLong = String(repeating: "a", count: HudSpec.maxTextLength + 1)
        let atCap = String(repeating: "b", count: HudSpec.maxTextLength)

        let message = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                               args: ControlArgs(message: tooLong)))
        let detail = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                              args: ControlArgs(message: "fine", detail: tooLong)))
        let accepted = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                                args: ControlArgs(message: atCap, detail: atCap)))

        #expect(message == ControlResponse(ok: false, error: "hud message too long (max 256 characters)"))
        #expect(detail == ControlResponse(ok: false, error: "hud detail too long (max 256 characters)"))
        #expect(accepted == ControlResponse(ok: true))
        #expect(actions.calls.count == 1)
    }

    // the cap must bound what the LAYOUT measures: `HudLayout.textLength` counts precomposed scalars, so a
    // ZWJ emoji costs five against a grapheme count's one, and a decomposed accent costs one against two.
    @Test func capsTextInTheUnitTheLayoutMeasures() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let emoji = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 100)
        let decomposed = String(repeating: "e\u{0301}", count: HudSpec.maxTextLength)

        #expect(emoji.count <= HudSpec.maxTextLength, "a grapheme count would let this through")
        let rejected = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                                args: ControlArgs(message: emoji)))
        let accepted = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                                args: ControlArgs(message: decomposed)))

        #expect(rejected == ControlResponse(ok: false,
                                            error: "hud message too long (max \(HudSpec.maxTextLength) characters)"))
        #expect(accepted == ControlResponse(ok: true))
        #expect(actions.calls.count == 1)
    }

    @Test func rejectsInvalidColorWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            args: ControlArgs(message: "working", color: "blue")
        ))

        #expect(response == ControlResponse(ok: false, error: "invalid color: blue (#rrggbb)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsSizePercentOutsideRangeWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let zero = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                            args: ControlArgs(sizePercent: 0, message: "working")))
        let over = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudUpdate,
                                                            args: ControlArgs(sizePercent: 101, message: "working")))

        #expect(zero == ControlResponse(ok: false, error: "session.hud.open: --size-percent must be 1...100"))
        #expect(over == ControlResponse(ok: false, error: "session.hud.update: --size-percent must be 1...100"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsUnknownPositionWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            args: ControlArgs(message: "working", position: "top-middle")
        ))

        #expect(response == ControlResponse(
            ok: false, error: "invalid position: top-middle (\(HudPosition.acceptedNamesList))"))
        #expect(actions.calls.isEmpty)
    }

    /// The rejection has to name the aliases, or it refuses a value the dispatcher takes.
    @Test func theRejectedPositionMessageListsTheAliasesBesideTheAnchors() async {
        let dispatcher = ControlDispatcher(actions: MockControlActions())

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen, args: ControlArgs(message: "working", position: "nope")))

        let error = try? #require(response?.error)
        #expect(error?.contains("top-right") == true)
        #expect(error?.hasSuffix("|top|bottom)") == true)
    }

    @Test func acceptsEveryAnchorAndBothAliases() async throws {
        for raw in ["top-left", "center-right", "bottom-right", "top", "bottom"] {
            let actions = MockControlActions()
            let dispatcher = ControlDispatcher(actions: actions)

            let response = await dispatcher.dispatch(ControlRequest(
                cmd: .sessionHudOpen, args: ControlArgs(message: "working", position: raw)))

            #expect(response?.error == nil)
            let call = try #require(actions.calls.first)
            guard case let .hudOpen(_, _, spec) = call else { Issue.record("not a hud open"); return }
            #expect(spec.position == HudPosition.parse(raw))
        }
    }

    @Test func rejectsMalformedTextColorWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            args: ControlArgs(message: "working", textColor: "#gg0000")
        ))

        #expect(response == ControlResponse(ok: false, error: "invalid text color: #gg0000 (#rrggbb)"))
        #expect(actions.calls.isEmpty)
    }

    /// An update carries the open's background forward but NOT its text color, the header being what paints
    /// the text and the surface config what paints the backing.
    @Test func updateCarriesItsOwnTextColorThrough() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudUpdate,
            args: ControlArgs(message: "done", textColor: "#7ec07e", position: "bottom-right")))

        let call = try #require(actions.calls.first)
        guard case let .hudUpdate(_, _, spec) = call else { Issue.record("not a hud update"); return }
        #expect(spec.textColor == "#7ec07e")
        #expect(spec.position == .bottomRight)
    }

    @Test func rejectsUnknownSpinnerStyleWithoutCallingHost() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            args: ControlArgs(message: "working", spinner: "swirl")
        ))

        // the message lists `none` too: it is accepted, so a rejection naming only the styles would name a
        // narrower set than the dispatcher takes
        #expect(response == ControlResponse(
            ok: false, error: "invalid spinner: swirl (bar|braille|circle|blocks|dot|none)"))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: HudSpinner.allCases) func acceptsEverySpinnerStyle(style: HudSpinner) async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                     args: ControlArgs(message: "working",
                                                                       spinner: style.rawValue)))

        guard case let .hudOpen(_, _, spec) = try #require(actions.calls.first) else {
            Issue.record("expected session.hud.open host call")
            return
        }
        #expect(spec.spinner == style)
    }

    // the read-back spells a static panel `none`, so a caller round-tripping what `tree` gave it must not be
    // rejected for a style that does not exist
    @Test func acceptsTheReadBacksNoneAsNoSpinner() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen,
                                                     args: ControlArgs(message: "working",
                                                                       spinner: HudSpinner.noneName)))

        guard case let .hudOpen(_, _, spec) = try #require(actions.calls.first) else {
            Issue.record("expected session.hud.open host call")
            return
        }
        #expect(spec.spinner == nil)
    }

    @Test func openRoutesParsedSpecAndReturnsHostResponse() async throws {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true, result: ControlResult(id: "session-id"))
        actions.nextHudOpenResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            target: "session-id",
            args: ControlArgs(sizePercent: 40, message: "gathering options", detail: "scanning 400 files",
                              spinner: "bar", window: "window-id", color: "#112233", position: "top")
        ))

        #expect(response == expected)
        let call = try #require(actions.calls.first)
        #expect(call == .hudOpen(target: "session-id", window: "window-id",
                                 HudSpec(message: "gathering options", detail: "scanning 400 files", spinner: .bar,
                                         backgroundColor: "#112233", sizePercent: 40, position: .topCenter)))
    }

    @Test func updateRoutesParsedSpecAndReturnsHostResponse() async throws {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true, result: ControlResult(id: "session-id"))
        actions.nextHudUpdateResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudUpdate,
            target: "session-id",
            args: ControlArgs(message: "still working", detail: "312 of 400", position: "bottom")
        ))

        #expect(response == expected)
        let call = try #require(actions.calls.first)
        #expect(call == .hudUpdate(target: "session-id", window: nil,
                                   HudSpec(message: "still working", detail: "312 of 400", position: .bottomCenter)))
    }

    @Test func omittedPositionSpinnerAndOverridesTakeTheirDefaults() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionHudOpen, args: ControlArgs(message: "working")))

        let call = try #require(actions.calls.first)
        guard case let .hudOpen(_, _, spec) = call else {
            Issue.record("expected session.hud.open host call")
            return
        }
        #expect(spec.position == .center)
        #expect(spec.spinner == nil)
        #expect(spec.detail == nil)
        #expect(spec.backgroundColor == nil)
        #expect(spec.sizePercent == nil)
    }

    @Test(arguments: HudPosition.allCases)
    func everyPositionRoundTripsToTheHost(position: HudPosition) async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudOpen,
            args: ControlArgs(message: "working", position: position.rawValue)
        ))

        let call = try #require(actions.calls.first)
        guard case let .hudOpen(_, _, spec) = call else {
            Issue.record("expected session.hud.open host call")
            return
        }
        #expect(spec.position == position)
    }

    @Test func closeRoutesTargetAndWindowAndIgnoresEverythingElse() async {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true, result: ControlResult(id: "session-id"))
        actions.nextHudCloseResponse = expected
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionHudClose,
            target: "session-id",
            args: ControlArgs(message: "", window: "window-id", color: "not a color", position: "nowhere")
        ))

        #expect(response == expected)
        #expect(actions.calls == [.hudClose(target: "session-id", window: "window-id")])
    }
}
