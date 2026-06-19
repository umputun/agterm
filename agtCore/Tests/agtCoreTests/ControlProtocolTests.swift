import Foundation
import Testing
@testable import agtCore

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
            ControlRequest(cmd: .sessionClose, target: "9f3c"),
            ControlRequest(cmd: .sessionSelect, target: "9f3c"),
            ControlRequest(cmd: .sessionRename, target: "active", args: ControlArgs(name: "build")),
            ControlRequest(cmd: .sessionMove, target: "9f3c", args: ControlArgs(workspace: "other")),
            ControlRequest(cmd: .sessionCopy, target: "9f3c"),
            ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(cwd: "/b", command: "revdiff")),
            ControlRequest(cmd: .sessionOverlayClose, target: "9f3c"),
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

    @Test func modeBearingCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .sessionSplit, target: "active", args: ControlArgs(mode: "toggle")),
            ControlRequest(cmd: .quick, args: ControlArgs(mode: "show")),
            ControlRequest(cmd: .statusbar, args: ControlArgs(mode: "off")),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
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
