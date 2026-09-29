import Foundation
import Testing
@testable import agtermCore

struct HtmlBridgeTests {
    let session = UUID()
    let page: HtmlBridgePage

    init() {
        page = HtmlBridgePage(window: "W1", session: session, pane: .right)
    }

    private func build(_ json: String, from origin: HtmlBridgePage? = nil) -> Result<ControlRequest, HtmlBridgeError> {
        HtmlBridge.request(from: Data(json.utf8), page: origin ?? page)
    }

    private func request(_ json: String) throws -> ControlRequest {
        try build(json).get()
    }

    @Test func aMessageDecodesIntoTheSocketRequest() throws {
        let built = try request(#"{"cmd":"theme.set","args":{"name":"Dracula"}}"#)
        #expect(built.cmd == .themeSet)
        #expect(built.args?.name == "Dracula")
    }

    @Test func anUnknownCommandOrWrongTypeGetsTheSocketsErrorText() throws {
        let unknown = build(#"{"cmd":"session.nope"}"#)
        let wrongType = build(#"{"cmd":"session.overlay.resize","args":{"sizePercent":"big"}}"#)
        for result in [unknown, wrongType] {
            guard case .failure(let error) = result else { Issue.record("expected a refusal"); return }
            #expect(error.message.hasPrefix("invalid request: "))
        }
        let data = Data(#"{"cmd":"session.nope"}"#.utf8)
        let socketError = try #require(throws: DecodingError.self) { try JSONDecoder().decode(ControlRequest.self, from: data) }
        guard case .failure(let error) = unknown else { return }
        #expect(error.message == ControlWire.invalidRequestMessage(socketError))
    }

    @Test func anUntargetedSessionCommandActsOnThePagesOwnSession() throws {
        for json in [#"{"cmd":"session.rename","args":{"name":"build"}}"#, #"{"cmd":"session.status","args":{"status":"completed"}}"#] {
            let built = try request(json)
            #expect(built.target == session.uuidString)
            #expect(built.args?.window == nil)
        }
    }

    @Test func explicitTargetsWindowsAndBatchesAreKeptAsGiven() throws {
        let active = try request(#"{"cmd":"session.rename","target":"active","args":{"name":"x"}}"#)
        #expect(active.target == "active")
        let other = try request(#"{"cmd":"session.select","target":"9C41"}"#)
        #expect(other.target == "9C41")
        #expect(other.args?.window == nil)
        let batch = try request(#"{"cmd":"session.close","args":{"targets":["A","B"]}}"#)
        #expect(batch.target == nil)
        #expect(batch.args?.targets == ["A", "B"])
    }

    @Test func anExplicitWindowGetsNoPageSessionOrPane() throws {
        let rename = try request(#"{"cmd":"session.rename","args":{"name":"x","window":"W2"}}"#)
        #expect(rename.target == nil)
        #expect(rename.args?.window == "W2")
        let close = try request(#"{"cmd":"session.overlay.close","args":{"window":"W2"}}"#)
        #expect(close.target == nil)
        #expect(close.args?.pane == nil)
    }

    @Test func theWindowIsFilledOnlyWhenNothingElseAddressesTheRequest() throws {
        let tree = try request(#"{"cmd":"tree"}"#)
        #expect(tree.args?.window == "W1")
        let go = try request(#"{"cmd":"session.go","args":{"to":"next"}}"#)
        #expect(go.args?.window == "W1")
        #expect(go.target == nil)
        let workspace = try request(#"{"cmd":"workspace.select","target":"WS"}"#)
        #expect(workspace.args?.window == nil)
    }

    @Test(arguments: ["window.close", "window.select", "window.rename", "window.delete", "window.resize", "window.move",
                      "window.zoom", "window.fullscreen", "window.minimize"])
    func anUntargetedWindowCommandActsOnThePagesWindow(_ cmd: String) throws {
        let built = try request(#"{"cmd":"\#(cmd)"}"#)
        #expect(built.target == "W1")
        #expect(try request(#"{"cmd":"\#(cmd)","target":"W2"}"#).target == "W2")
    }

    @Test(arguments: ["font.inc", "font.dec", "font.reset"])
    func anUntargetedFontCommandActsOnThePagesSession(_ cmd: String) throws {
        let built = try request(#"{"cmd":"\#(cmd)"}"#)
        #expect(built.target == session.uuidString)
        #expect(built.args?.window == nil)
    }

    @Test func aTerminalAskGoesToThePagesSessionAndAGuiAskToItsWindow() throws {
        let terminal = try request(#"{"cmd":"ask.open","args":{"title":"t"}}"#)
        #expect(terminal.target == session.uuidString)
        let gui = try request(#"{"cmd":"ask.open","args":{"title":"t","style":"gui"}}"#)
        #expect(gui.target == nil)
        #expect(gui.args?.window == "W1")
    }

    @Test func attachAndDashboardKeepTheirIdsAndLandInThePagesWindow() throws {
        let attach = try request(#"{"cmd":"zmx.attach","target":"REMOTE","args":{"host":"mac"}}"#)
        #expect(attach.target == "REMOTE")
        #expect(attach.args?.window == "W1")
        let dashboard = try request(#"{"cmd":"dashboard","args":{"targets":["A","B"]}}"#)
        #expect(dashboard.args?.targets == ["A", "B"])
        #expect(dashboard.args?.window == "W1")
        let elsewhere = try request(#"{"cmd":"dashboard","args":{"targets":["A"],"window":"W2"}}"#)
        #expect(elsewhere.args?.window == "W2")
    }

    @Test func thePaneIsFilledOnlyForThePagesOwnOverlayCommands() throws {
        for cmd in ["session.overlay.close", "session.overlay.reload", "session.overlay.navigate", "session.overlay.submit"] {
            let built = try request(#"{"cmd":"\#(cmd)"}"#)
            #expect(built.target == session.uuidString, "\(cmd)")
            #expect(built.args?.pane == "right", "\(cmd)")
        }
        let rename = try request(#"{"cmd":"session.rename","args":{"name":"x"}}"#)
        #expect(rename.args?.pane == nil)
        let targeted = try request(#"{"cmd":"session.overlay.close","target":"9C41"}"#)
        #expect(targeted.args?.pane == nil)
        let sessionWide = try build(#"{"cmd":"session.overlay.close"}"#,
                                    from: HtmlBridgePage(window: "W1", session: session, pane: nil)).get()
        #expect(sessionWide.args?.pane == nil)
    }

    @Test func reloadIsCurrentOnlyWhenCurrentWasOmitted() throws {
        #expect(try request(#"{"cmd":"session.overlay.reload"}"#).args?.current == true)
        #expect(try request(#"{"cmd":"session.overlay.reload","args":{"current":false}}"#).args?.current == false)
    }

    @Test(arguments: ["zmx.present", "session.overlay.job.run", "zmx.reset"])
    func streamAndAfterReplyCommandsAreRefused(_ cmd: String) {
        guard case .failure(let error) = build(#"{"cmd":"\#(cmd)"}"#) else { Issue.record("\(cmd) must be refused"); return }
        #expect(error.message == HtmlBridgeError.unsupported(cmd).message)
    }
}
