import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherAskTests {
    @Test(arguments: [(Optional("right"), Optional<String>.none), (nil, "pane-id")])
    func terminalPaneSelectorsReachHostWithoutSession(pane: String?, paneID: String?) async throws {
        let actions = MockControlActions()
        let args = ControlArgs(buttons: [ControlAskButton(id: "yes", label: "Yes")], pane: pane, paneID: paneID, title: "Choose")
        _ = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askOpen, args: args))
        guard case let .askOpen(ask, target, _, placement, _) = try #require(actions.calls.first) else {
            Issue.record("expected ask.open")
            return
        }
        #expect(ask.style == .terminal)
        #expect(target == nil)
        #expect(placement.pane == pane.flatMap(OverlayPane.init(controlName:)))
        #expect(placement.paneID == paneID)
    }

    @Test(arguments: [-1, 0, 9, 101, Int.max])
    func invalidWidthNeverReachesHost(width: Int) async {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askOpen, args: ControlArgs(
            buttons: [ControlAskButton(id: "ok", label: "OK")], title: "Choose", width: width
        )))
        #expect(response == ControlResponse(ok: false, error: "width must be 10 to 100"))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [10, 50, 100])
    func fixedWidthReachesHost(width: Int) async throws {
        let actions = MockControlActions()
        _ = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askOpen, args: ControlArgs(
            buttons: [ControlAskButton(id: "ok", label: "OK")], title: "Choose", width: width
        )))
        guard case let .askOpen(ask, _, _, _, _) = try #require(actions.calls.first) else {
            Issue.record("expected ask.open")
            return
        }
        #expect(ask.width == width)
    }

    @Test(arguments: ["", "GUI", "other"])
    func invalidStyleOrAlignmentNeverReachesTheHost(value: String) async {
        for args in [ControlArgs(buttons: [ControlAskButton(id: "ok", label: "OK")], style: value, title: "Choose"),
                     ControlArgs(buttons: [ControlAskButton(id: "ok", label: "OK")], align: value, title: "Choose")] {
            let actions = MockControlActions()
            let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askOpen, args: args))
            #expect(response == ControlResponse(ok: false, error: args.style == nil ? "unknown align" : "unknown style"))
            #expect(actions.calls.isEmpty)
        }
    }

    @Test(arguments: ControlAskStyle.allCases, ControlAskAlignment.allCases)
    func decorationReachesHost(style: ControlAskStyle, align: ControlAskAlignment) async throws {
        let actions = MockControlActions()
        _ = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askOpen, args: ControlArgs(
            buttons: [ControlAskButton(id: "ok", label: "OK")], style: style.rawValue, align: align.rawValue, title: "Choose"
        )))
        guard case let .askOpen(ask, _, _, _, _) = try #require(actions.calls.first) else {
            Issue.record("expected ask.open")
            return
        }
        #expect(ask.style == style)
        #expect(ask.align == align)
    }

    @Test(arguments: [
        (ControlArgs(), "ask.open requires a title"),
        (ControlArgs(title: ""), "ask.open requires a title"),
        (ControlArgs(title: "  "), "ask.open requires a title"),
        (ControlArgs(title: "\t\n"), "ask.open requires a title"),
        (ControlArgs(title: "Choose"), "ask.open requires buttons"),
        (ControlArgs(buttons: [], title: "Choose"), "ask.open requires at least one button"),
        (ControlArgs(buttons: (0..<7).map { ControlAskButton(id: "\($0)", label: "Button \($0)") }, title: "Choose"),
         "too many buttons (max 6)"),
        (ControlArgs(buttons: [ControlAskButton(id: "empty", label: "")], title: "Choose"),
         "ask button label must not be empty"),
        (ControlArgs(buttons: [ControlAskButton(id: "same", label: "First"), ControlAskButton(id: "same", label: "Second")],
                     title: "Choose"), "ask button ids must be unique"),
        (ControlArgs(buttons: [ControlAskButton(id: "yes", label: "Yes")], title: "Bad\ntitle"),
         "ask text must not contain control characters"),
        (ControlArgs(message: "Bad\tmessage", buttons: [ControlAskButton(id: "yes", label: "Yes")], title: "Choose"),
         "ask text must not contain control characters"),
        (ControlArgs(buttons: [ControlAskButton(id: "yes", label: "Bad\u{7f}label")], title: "Choose"),
         "ask text must not contain control characters"),
        (ControlArgs(buttons: [ControlAskButton(id: "yes", label: "Yes")], defaultButton: "missing", title: "Choose"),
         "unknown default button: missing"),
        (ControlArgs(buttons: [ControlAskButton(id: "yes", label: "Yes")], destructiveButton: "missing", title: "Choose"),
         "unknown destructive button: missing"),
        (ControlArgs(buttons: [ControlAskButton(id: "delete", label: "Delete")],
                     defaultButton: "delete", destructiveButton: "delete", title: "Choose"),
         "default button must not be destructive"),
        (ControlArgs(buttons: [ControlAskButton(id: "one", label: "One", hotkey: "y"),
                              ControlAskButton(id: "two", label: "Two", hotkey: "Y")], title: "Choose"),
         "ask button hotkeys must be unique"),
    ])
    func invalidOpenDoesNotReachHost(args: ControlArgs, error: String) async {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askOpen, args: args))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test func openWithoutArgsDoesNotReachHost() async {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askOpen))

        #expect(response == ControlResponse(ok: false, error: "ask.open requires a title"))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: ["", "yes", "1", "!", " ", "\r", "\t", "\u{1b}", "→", "é", "a\u{301}", "🦊"])
    func hotkeysMustBeSingleASCIILetters(hotkey: String) async {
        let actions = MockControlActions()
        let args = ControlArgs(buttons: [ControlAskButton(id: "yes", label: "Yes", hotkey: hotkey)], title: "Choose")
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askOpen, args: args))

        #expect(response == ControlResponse(ok: false, error: "ask button hotkey must be one ASCII letter"))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [(Optional("right"), Optional<String>.none), (nil, "pane-id"), (nil, "")])
    func guiPaneSelectorsRequireSession(pane: String?, paneID: String?) async {
        let actions = MockControlActions()
        let args = ControlArgs(buttons: [ControlAskButton(id: "yes", label: "Yes")],
                               style: "gui", pane: pane, paneID: paneID, title: "Choose")
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askOpen, args: args))

        #expect(response == ControlResponse(ok: false, error: "--pane requires a session"))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: ["", "scratch", "overlay", "unknown", "RIGHT"])
    func invalidPaneDoesNotReachHost(pane: String) async {
        let actions = MockControlActions()
        let args = ControlArgs(buttons: [ControlAskButton(id: "yes", label: "Yes")], pane: pane, title: "Choose")
        let response = await ControlDispatcher(actions: actions).dispatch(
            ControlRequest(cmd: .askOpen, target: "active", args: args)
        )

        #expect(response == ControlResponse(ok: false, error: "--pane must be left or right"))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [(Command.askResult, "ask.result requires an ask id"), (.askCancel, "ask.cancel requires an ask id")])
    func lookupsRequireAnAskID(command: Command, error: String) async {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: command))

        #expect(response == ControlResponse(ok: false, error: error))
        #expect(actions.calls.isEmpty)
    }

    @Test func validOpenPreservesFieldsAndNormalizesHotkeys() async throws {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: true, result: ControlResult(id: "ask-id", pane: "right"))
        actions.nextAskOpenResponse = expected
        let args = ControlArgs(
            follow: true, message: "Changes are unsaved.",
            buttons: [
                ControlAskButton(id: "Save", label: "Save", hotkey: "S"),
                ControlAskButton(id: "cancel", label: "Not now", hotkey: "n"),
                ControlAskButton(id: "delete", label: "Delete"),
            ],
            defaultButton: "Save", destructiveButton: "delete", style: "gui", align: "center",
            window: "window-id", pane: "right", paneID: "pane-id", title: "  Choose  "
        )
        let response = await ControlDispatcher(actions: actions).dispatch(
            ControlRequest(cmd: .askOpen, target: "session-id", args: args)
        )

        #expect(response == expected)
        #expect(actions.calls.count == 1)
        guard case let .askOpen(ask, target, window, placement, follow) = try #require(actions.calls.first) else {
            Issue.record("expected ask.open host call")
            return
        }
        #expect(UUID(uuidString: ask.id) != nil)
        #expect(ask.title == "  Choose  ")
        #expect(ask.message == "Changes are unsaved.")
        #expect(ask.buttons == [
            ControlAskButton(id: "Save", label: "Save", hotkey: "s"),
            ControlAskButton(id: "cancel", label: "Not now", hotkey: "n"),
            ControlAskButton(id: "delete", label: "Delete"),
        ])
        #expect(ask.defaultID == "Save")
        #expect(ask.style == .gui)
        #expect(ask.align == .center)
        #expect(ask.destructiveID == "delete")
        #expect(ask.anchor == nil)
        #expect(target == "session-id")
        #expect(window == "window-id")
        #expect(placement == ControlAskPlacement(pane: .right, paneID: "pane-id"))
        #expect(follow)
    }

    @Test(arguments: [1, 6])
    func validButtonCountsLeaveOmittedOptionsUnset(count: Int) async throws {
        let actions = MockControlActions()
        let buttons = (0..<count).map { ControlAskButton(id: "\($0)", label: "Button \($0)") }
        let response = await ControlDispatcher(actions: actions).dispatch(
            ControlRequest(cmd: .askOpen, args: ControlArgs(buttons: buttons, title: "Choose"))
        )

        #expect(response == ControlResponse(ok: true))
        guard case let .askOpen(ask, target, window, placement, follow) = try #require(actions.calls.first) else {
            Issue.record("expected ask.open host call")
            return
        }
        #expect(ask.buttons == buttons)
        #expect(ask.message == nil)
        #expect(ask.defaultID == nil)
        #expect(ask.style == .terminal)
        #expect(ask.align == .right)
        #expect(ask.width == nil)
        #expect(ask.destructiveID == nil)
        #expect(ask.anchor == nil)
        #expect(target == nil)
        #expect(window == nil)
        #expect(placement == ControlAskPlacement())
        #expect(!follow)
    }

    @Test(arguments: [("left", OverlayPane.left), ("primary", .left), ("top", .left),
                      ("right", .right), ("split", .right), ("bottom", .right)])
    func paneAliasesReachHostAsCanonicalRoles(raw: String, expected: OverlayPane) async throws {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .askOpen, target: "active",
            args: ControlArgs(buttons: [ControlAskButton(id: "ok", label: "OK")], pane: raw, title: "Choose")
        ))

        #expect(response == ControlResponse(ok: true))
        guard case let .askOpen(_, target, _, placement, _) = try #require(actions.calls.first) else {
            Issue.record("expected ask.open host call")
            return
        }
        #expect(target == "active")
        #expect(placement.pane == expected)
    }

    @Test func paneIDPassesThroughWithoutAPaneFallback() async throws {
        let actions = MockControlActions()
        _ = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .askOpen, target: "session-id",
            args: ControlArgs(buttons: [ControlAskButton(id: "ok", label: "OK")], paneID: "identity", title: "Choose")
        ))
        guard case let .askOpen(_, target, _, placement, _) = try #require(actions.calls.first) else {
            Issue.record("expected ask.open host call")
            return
        }
        #expect(target == "session-id")
        #expect(placement == ControlAskPlacement(paneID: "identity"))
    }

    @Test func cancelLabelIsAnOrdinaryDefaultButton() async {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .askOpen,
            args: ControlArgs(buttons: [ControlAskButton(id: "cancel", label: "Cancel")],
                              defaultButton: "cancel", title: "Choose")
        ))
        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls.count == 1)
    }

    @Test func repeatedOpenGeneratesDistinctRequestIDs() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let request = ControlRequest(cmd: .askOpen,
                                     args: ControlArgs(buttons: [ControlAskButton(id: "ok", label: "OK")], title: "Choose"))
        _ = await dispatcher.dispatch(request)
        _ = await dispatcher.dispatch(request)
        #expect(actions.calls.count == 2)
        guard case let .askOpen(first, _, _, _, _) = try #require(actions.calls.first),
              case let .askOpen(second, _, _, _, _) = try #require(actions.calls.last) else {
            Issue.record("expected two ask.open host calls")
            return
        }
        #expect(first.id != second.id)
    }

    @Test func openReturnsHostFailureUnchanged() async {
        let actions = MockControlActions()
        let expected = ControlResponse(ok: false, error: "ask already pending")
        actions.nextAskOpenResponse = expected
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .askOpen, args: ControlArgs(buttons: [ControlAskButton(id: "ok", label: "OK")], title: "Choose")
        ))
        #expect(response == expected)
        #expect(actions.calls.count == 1)
    }

    @Test(arguments: [
        ControlResponse(ok: true, result: ControlResult(ask: ControlAskResult(result: .pending))),
        ControlResponse(ok: true, result: ControlResult(ask: ControlAskResult(result: .answered, id: "ok", label: "OK", index: 0))),
        ControlResponse(ok: true, result: ControlResult(ask: ControlAskResult(result: .cancelled))),
        ControlResponse(ok: false, error: "unknown ask: ask-id"),
    ])
    func resultRoutesIDAndPreservesHostResponse(expected: ControlResponse) async {
        let actions = MockControlActions()
        actions.nextAskResultResponse = expected
        let response = await ControlDispatcher(actions: actions).dispatch(
            ControlRequest(cmd: .askResult, target: "ask-id", args: ControlArgs(window: "window-id"))
        )
        #expect(response == expected)
        #expect(actions.calls == [.askResult(target: "ask-id", window: "window-id")])
    }

    @Test(arguments: [ControlResponse(ok: true), ControlResponse(ok: false, error: "unknown ask: ask-id")])
    func cancelRoutesIDAndPreservesHostResponse(expected: ControlResponse) async {
        let actions = MockControlActions()
        actions.nextAskCancelResponse = expected
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .askCancel, target: "ask-id"))
        #expect(response == expected)
        #expect(actions.calls == [.askCancel(target: "ask-id", window: nil)])
    }
}
