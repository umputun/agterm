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

    @Test(arguments: [("browser", LinkOpenMode.browser), ("overlay", .overlay)])
    func browserLinksSetsTheModeAndKeepsTheReply(_ raw: String, _ mode: LinkOpenMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextBrowserLinksResponse = ControlResponse(ok: true, result: ControlResult(text: raw))

        let response = await dispatcher.dispatch(ControlRequest(cmd: .browserLinks, args: ControlArgs(mode: raw)))

        #expect(response == ControlResponse(ok: true, result: ControlResult(text: raw)))
        #expect(actions.calls == [.browserLinks(mode)])
    }

    @Test func browserLinksWithNoModeReads() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .browserLinks))

        #expect(actions.calls == [.browserLinks(nil)])
    }

    @Test func browserLinksRefusesAnUnknownModeATargetOrAWindowBeforeAnyAction() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let unknown = await dispatcher.dispatch(ControlRequest(cmd: .browserLinks, args: ControlArgs(mode: "tab")))
        let targeted = await dispatcher.dispatch(ControlRequest(cmd: .browserLinks, target: "active"))
        let windowed = await dispatcher.dispatch(ControlRequest(cmd: .browserLinks, args: ControlArgs(window: "w1")))

        #expect(unknown == ControlResponse(ok: false, error: "invalid link mode: tab"))
        #expect(targeted == ControlResponse(ok: false, error: "browser.links takes no target or --window"))
        #expect(windowed == ControlResponse(ok: false, error: "browser.links takes no target or --window"))
        #expect(actions.calls.isEmpty)
    }

    @Test func browserLinksAndBrowseRoundTripOnTheWire() throws {
        let links = ControlRequest(cmd: .browserLinks, args: ControlArgs(mode: "overlay"))
        let encoded = try JSONEncoder().encode(links)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""cmd":"browser.links""#))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: encoded) == links)

        let open = ControlRequest(cmd: .sessionOverlayOpen, args: ControlArgs(url: "http://localhost:5173/", browse: true))
        let data = try JSONEncoder().encode(open)
        #expect(String(decoding: data, as: UTF8.self).contains(#""browse":true"#))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == open)
    }

    @Test(arguments: [(1, "1 persistent page still open"), (3, "3 persistent pages still open")])
    func browserClearNamesHowManyPagesBlockIt(_ count: Int, _ message: String) {
        #expect(BrowserClearError.pagesOpen(count) == message)
    }
}
