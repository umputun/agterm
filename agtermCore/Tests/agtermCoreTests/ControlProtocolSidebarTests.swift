import Foundation
import Testing
@testable import agtermCore

struct ControlProtocolSidebarTests {
    private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(ControlRequest.self, from: data)
    }

    private func roundTrip(_ response: ControlResponse) throws -> ControlResponse {
        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(ControlResponse.self, from: data)
    }

    @Test func sidebarModeRawStringMapsToCommand() throws {
        let raw = #"{"cmd":"sidebar.mode","args":{"mode":"flagged"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(raw.utf8))
        #expect(decoded.cmd == .sidebarMode)
        #expect(decoded.args?.mode == "flagged")
    }

    @Test func treeRoundTripsWithSidebarMode() throws {
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [], sidebarMode: "flagged")))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.sidebarMode == "flagged")
    }

    @Test func treeRoundTripsWithSidebarFlaggedLayoutAndOmitsWhenNil() throws {
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [], sidebarFlaggedLayout: "tree")))
        #expect(try roundTrip(response) == response)

        let json = String(decoding: try JSONEncoder().encode(ControlTree(workspaces: [])), as: UTF8.self)
        #expect(!json.contains("sidebarFlaggedLayout"), "a nil flagged layout must be omitted; got \(json)")
        #expect(try JSONDecoder().decode(ControlTree.self, from: Data(json.utf8)).sidebarFlaggedLayout == nil)
    }

    @Test func treeRoundTripsWithSidebarDensityAndOmitsWhenNil() throws {
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(workspaces: [], sidebarDensity: "compact")))
        #expect(try roundTrip(response) == response)

        let json = String(decoding: try JSONEncoder().encode(ControlTree(workspaces: [])), as: UTF8.self)
        #expect(!json.contains("sidebarDensity"), "a nil density must be omitted; got \(json)")
        #expect(try JSONDecoder().decode(ControlTree.self, from: Data(json.utf8)).sidebarDensity == nil)
    }

    @Test func sidebarDensityRequestUsesItsWireName() throws {
        let raw = #"{"cmd":"sidebar.density","args":{"mode":"compact"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(raw.utf8))
        #expect(decoded == ControlRequest(cmd: .sidebarDensity, args: ControlArgs(mode: "compact")))
    }

    @Test func flaggedLayoutRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .sidebarFlaggedLayout, args: ControlArgs(mode: "tree"))
        let data = try JSONEncoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self).contains("sidebar.flagged-layout"))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
    }

    @Test func treeRoundTripsWithSidebarWidthAndOmitsWhenNil() throws {
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [], sidebarWidth: 271.3)))
        #expect(try roundTrip(response) == response)

        let json = String(decoding: try JSONEncoder().encode(ControlTree(workspaces: [])), as: UTF8.self)
        #expect(!json.contains("sidebarWidth"), "a nil sidebar width must be omitted from the JSON; got \(json)")
        #expect(try JSONDecoder().decode(ControlTree.self, from: Data(json.utf8)).sidebarWidth == nil)
    }

    @Test func sidebarWidthRequestAndEchoRoundTrip() throws {
        let request = ControlRequest(cmd: .sidebarWidth, args: ControlArgs(window: "win", sidebarWidth: 271.3))
        let decodedRequest = try roundTrip(request)
        #expect(decodedRequest.cmd == .sidebarWidth)
        #expect(decodedRequest.args?.sidebarWidth == 271.3)

        let echo = ControlResponse(ok: true, result: ControlResult(sidebarWidth: 560))
        #expect(try roundTrip(echo) == echo)

        let json = String(decoding: try JSONEncoder().encode(ControlArgs(window: "win")), as: UTF8.self)
        #expect(!json.contains("sidebarWidth"), "a nil sidebar width must be omitted from the JSON; got \(json)")
    }

    @Test func sidebarExpandCollapseRequestsRoundTrip() throws {
        let cases = [
            ControlRequest(cmd: .sidebarExpand),
            ControlRequest(cmd: .sidebarCollapse),
            ControlRequest(cmd: .sidebarExpand, args: ControlArgs(window: "abc")),
            ControlRequest(cmd: .sidebarCollapse, args: ControlArgs(window: "abc")),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sidebarExpandRawStringMapsToCommand() throws {
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"cmd":"sidebar.expand"}"#.utf8))
        #expect(decoded.cmd == .sidebarExpand)
    }

    @Test func sidebarCollapseRawStringMapsToCommand() throws {
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"cmd":"sidebar.collapse"}"#.utf8))
        #expect(decoded.cmd == .sidebarCollapse)
    }
}
