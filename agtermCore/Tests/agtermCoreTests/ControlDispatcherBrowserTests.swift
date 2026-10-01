import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherBrowserTests {
    @Test func browserClearRoutesToActionsAndKeepsTheReply() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextBrowserClearResponse = ControlResponse(ok: false, error: BrowserClearError.pagesOpen(2))

        let response = await dispatcher.dispatch(ControlRequest(cmd: .browserClear))

        #expect(response == ControlResponse(ok: false, error: "2 persistent pages still open"))
        #expect(actions.calls == [.browserClear])
    }

    @Test func browserClearRefusesATargetOrWindowBeforeAnyAction() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let targeted = await dispatcher.dispatch(ControlRequest(cmd: .browserClear, target: "active"))
        let windowed = await dispatcher.dispatch(ControlRequest(cmd: .browserClear, args: ControlArgs(window: "w1")))

        #expect(targeted == ControlResponse(ok: false, error: "browser.clear takes no target or --window"))
        #expect(windowed == ControlResponse(ok: false, error: "browser.clear takes no target or --window"))
        #expect(actions.calls.isEmpty)
    }

    @Test func browserClearAndPersistentRoundTripOnTheWire() throws {
        let clear = try JSONEncoder().encode(ControlRequest(cmd: .browserClear))
        #expect(String(decoding: clear, as: UTF8.self) == #"{"cmd":"browser.clear"}"#)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: clear).cmd == .browserClear)

        let open = ControlRequest(cmd: .sessionOverlayOpen, args: ControlArgs(url: "http://localhost:5173/", persistent: true))
        let data = try JSONEncoder().encode(open)
        #expect(String(decoding: data, as: UTF8.self).contains(#""persistent":true"#))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == open)
    }

    @Test(arguments: [(1, "1 persistent page still open"), (3, "3 persistent pages still open")])
    func browserClearNamesHowManyPagesBlockIt(_ count: Int, _ message: String) {
        #expect(BrowserClearError.pagesOpen(count) == message)
    }
}
