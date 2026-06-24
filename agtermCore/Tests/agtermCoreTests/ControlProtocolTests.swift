import Foundation
import Testing
@testable import agtermCore

struct ControlProtocolTests {
    // round-trip a request through JSON and back, asserting equality with the original.
    private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(ControlRequest.self, from: data)
    }

    private func roundTrip(_ response: ControlResponse) throws -> ControlResponse {
        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(ControlResponse.self, from: data)
    }

    @Test func treeRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .tree)
        #expect(try roundTrip(request) == request)
    }

    @Test func workspaceCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "work")),
            ControlRequest(cmd: .workspaceRename, target: "active", args: ControlArgs(name: "renamed")),
            ControlRequest(cmd: .workspaceDelete, target: "9f3c"),
            ControlRequest(cmd: .workspaceSelect, target: "9f3c"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .sessionNew, args: ControlArgs(cwd: "/tmp", workspace: "active")),
            ControlRequest(cmd: .sessionNew, args: ControlArgs(cwd: "/tmp", command: "ssh host -p 22")),
            ControlRequest(cmd: .sessionClose, target: "9f3c"),
            ControlRequest(cmd: .sessionSelect, target: "9f3c"),
            ControlRequest(cmd: .sessionRename, target: "active", args: ControlArgs(name: "build")),
            ControlRequest(cmd: .sessionMove, target: "9f3c", args: ControlArgs(workspace: "other")),
            ControlRequest(cmd: .sessionCopy, target: "9f3c"),
            ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(cwd: "/b", command: "revdiff")),
            ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(command: "htop", sizePercent: 70)),
            ControlRequest(cmd: .sessionOverlayClose, target: "9f3c"),
            ControlRequest(cmd: .sessionOverlayResult, target: "9f3c"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionTypeWithSelectRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionType, target: "9f3c", args: ControlArgs(text: "ls\n", select: true))
        #expect(try roundTrip(request) == request)
    }

    @Test func sessionTypeWithoutSelectRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionType, target: "active", args: ControlArgs(text: "pwd\n"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.select == nil)
    }

    @Test func sessionStatusRoundTripsWithStateAndBlink() throws {
        let request = ControlRequest(cmd: .sessionStatus, target: "9f3c",
                                     args: ControlArgs(status: "active", blink: true, autoReset: true))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionStatus)
        #expect(decoded.args?.status == "active")
        #expect(decoded.args?.blink == true)
        #expect(decoded.args?.autoReset == true)
    }

    @Test func sessionStatusRawStringMapsToCommandAndArgs() throws {
        let json = #"{"cmd":"session.status","args":{"status":"blocked"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .sessionStatus)
        #expect(decoded.args?.status == "blocked")
        #expect(decoded.args?.blink == nil)
        #expect(decoded.args?.autoReset == nil)
    }

    @Test func sessionStatusDecodesAutoReset() throws {
        let json = #"{"cmd":"session.status","args":{"status":"completed","autoReset":true}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .sessionStatus)
        #expect(decoded.args?.status == "completed")
        #expect(decoded.args?.autoReset == true)
    }

    @Test func sessionStatusUnknownStateDecodesForServerToReject() throws {
        // an unknown status string decodes fine; the server rejects it via AgentStatus(rawValue:) -> nil.
        let json = #"{"cmd":"session.status","args":{"status":"bogus"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .sessionStatus)
        #expect(decoded.args?.status == "bogus")
        #expect(AgentStatus(rawValue: decoded.args?.status ?? "") == nil)
    }

    @Test func modeBearingCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .sessionSplit, target: "active", args: ControlArgs(mode: "toggle")),
            ControlRequest(cmd: .sessionScratch, target: "active", args: ControlArgs(mode: "toggle")),
            ControlRequest(cmd: .sessionScratch, target: "9f3c", args: ControlArgs(mode: "on")),
            ControlRequest(cmd: .quick, args: ControlArgs(mode: "show")),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionFocusRoundTripsWithPane() throws {
        let request = ControlRequest(cmd: .sessionFocus, target: "active", args: ControlArgs(pane: "right"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.pane == "right")
    }

    @Test func sessionGoRoundTripsWithDirection() throws {
        let request = ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "next"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionGo)
        #expect(decoded.args?.to == "next")
    }

    @Test func sessionGoRoundTripsWithAttentionDirection() throws {
        let request = ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "next-attention"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.to == "next-attention")
        #expect(SessionNavigation(wire: decoded.args!.to!) == .nextAttention)
    }

    @Test func sessionMoveReorderRoundTripsWithDirection() throws {
        let request = ControlRequest(cmd: .sessionMove, target: "9f3c", args: ControlArgs(to: "up"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionMove)
        #expect(decoded.args?.to == "up")
        #expect(decoded.args?.workspace == nil)
    }

    @Test func workspaceMoveRoundTripsWithDirection() throws {
        let request = ControlRequest(cmd: .workspaceMove, target: "active", args: ControlArgs(to: "top"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .workspaceMove)
        #expect(decoded.args?.to == "top")
    }

    @Test func workspaceMoveRawStringMapsToCommand() throws {
        let json = #"{"cmd":"workspace.move","target":"active","args":{"to":"bottom"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .workspaceMove)
        #expect(decoded.args?.to == "bottom")
    }

    @Test func notifyRoundTripsWithTitleAndBody() throws {
        let request = ControlRequest(cmd: .notify, target: "active", args: ControlArgs(title: "Build", body: "done"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.title == "Build")
        #expect(decoded.args?.body == "done")
    }

    @Test func fontCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .fontInc, target: "active"),
            ControlRequest(cmd: .fontDec, target: "active"),
            ControlRequest(cmd: .fontReset, target: "active"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func windowCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .windowNew, args: ControlArgs(name: "work")),
            ControlRequest(cmd: .windowList),
            ControlRequest(cmd: .windowSelect, target: "9f3c"),
            ControlRequest(cmd: .windowClose, target: "9f3c"),
            ControlRequest(cmd: .windowRename, target: "active", args: ControlArgs(name: "renamed")),
            ControlRequest(cmd: .windowDelete, target: "9f3c"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func keymapReloadRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .keymapReload)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .keymapReload)
    }

    @Test func keymapReloadRawStringMapsToCommand() throws {
        let json = #"{"cmd":"keymap.reload"}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .keymapReload)
    }

    @Test func responseOkWithCountRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(count: 3))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.count == 3)
    }

    @Test func sessionCommandWithWindowArgRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionSelect, target: "9f3c", args: ControlArgs(window: "main"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.window == "main")
    }

    @Test func requestUsesExpectedWireFieldNames() throws {
        let request = ControlRequest(cmd: .sessionType, target: "9f3c", args: ControlArgs(text: "ls\n", select: true))
        let json = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
        #expect(json.contains("\"cmd\":\"session.type\""))
        #expect(json.contains("\"target\":\"9f3c\""))
        #expect(json.contains("\"args\":"))
        #expect(json.contains("\"text\":\"ls\\n\""))
        #expect(json.contains("\"select\":true"))
    }

    @Test func responseOkWithIDRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.id == "9f3c")
    }

    @Test func responseOkWithTreeRoundTrips() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let workspace = ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(workspaces: [workspace])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.name == "shell")
    }

    @Test func responseOkWithTextRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(text: "selected\nlines"))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.text == "selected\nlines")
    }

    @Test func responseOkWithExitCodeRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c", exitCode: 10))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.exitCode == 10)
    }

    @Test func responseOkWithWindowsRoundTrips() throws {
        let windows = [
            ControlWindowNode(id: "w1", name: "work", open: true, active: true),
            ControlWindowNode(id: "w2", name: "personal", open: false, active: false),
        ]
        let response = ControlResponse(ok: true, result: ControlResult(windows: windows))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.windows?.count == 2)
        #expect(decoded.result?.windows?.first?.name == "work")
        #expect(decoded.result?.windows?.first?.open == true)
        #expect(decoded.result?.windows?.first?.active == true)
        #expect(decoded.result?.windows?.last?.open == false)
    }

    @Test func windowsResultUsesExpectedWireFieldNames() throws {
        let windows = [ControlWindowNode(id: "w1", name: "work", open: true, active: false)]
        let response = ControlResponse(ok: true, result: ControlResult(windows: windows))
        let json = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))
        #expect(json.contains("\"windows\":"))
        #expect(json.contains("\"id\":\"w1\""))
        #expect(json.contains("\"name\":\"work\""))
        #expect(json.contains("\"open\":true"))
        #expect(json.contains("\"active\":false"))
    }

    @Test func responseErrorRoundTrips() throws {
        let response = ControlResponse(ok: false, error: "ambiguous prefix '9f'")
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.ok == false)
        #expect(decoded.error == "ambiguous prefix '9f'")
    }

    @Test func responseUsesExpectedWireFieldNames() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let json = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))
        #expect(json.contains("\"ok\":true"))
        #expect(json.contains("\"result\":"))
        #expect(json.contains("\"id\":\"9f3c\""))
    }

    @Test func unknownCommandFailsToDecode() {
        let json = #"{"cmd":"bogus.command"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        }
    }
}
