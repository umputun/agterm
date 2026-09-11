import Foundation
import Testing
@testable import agtermCore

/// Wire format for the window commands and `ControlWindowNode`: what each field round-trips as and which
/// ones are omitted when nil. Split out of `ControlProtocolTests` for the swiftlint file limit.
struct ControlWindowProtocolTests {
    private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(ControlRequest.self, from: data)
    }

    private func roundTrip(_ response: ControlResponse) throws -> ControlResponse {
        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(ControlResponse.self, from: data)
    }

    @Test func windowNodeRoundTripsWithPerWindowFields() throws {
        let node = ControlWindowNode(id: "w1", name: "work", open: true, active: true, autoFollowMs: 5000,
                                     sidebarVisible: true)
        let response = ControlResponse(ok: true, result: ControlResult(windows: [node]))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.windows?.first?.autoFollowMs == 5000)
        #expect(decoded.result?.windows?.first?.sidebarVisible == true)
    }

    @Test func windowNodeOmitsPerWindowFieldsWhenNil() throws {
        let node = ControlWindowNode(id: "w1", name: "work", open: true, active: false)
        let json = String(data: try JSONEncoder().encode(node), encoding: .utf8) ?? ""
        #expect(!json.contains("autoFollowMs"), "a nil autoFollowMs must be omitted from the JSON; got \(json)")
        #expect(!json.contains("sidebarVisible"), "a nil sidebarVisible must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlWindowNode.self, from: Data(json.utf8))
        #expect(decoded.autoFollowMs == nil)
        #expect(decoded.sidebarVisible == nil)
    }

    @Test func windowNodeRoundTripsWithGeometry() throws {
        // the frame fields match the CLI's --x/--y/--width/--height, so a read-back restores verbatim.
        let node = ControlWindowNode(id: "w1", name: "work", open: true, active: true,
                                     geometry: ControlWindowFrame(x: 100, y: 40, width: 1200, height: 800, display: 1))
        let response = ControlResponse(ok: true, result: ControlResult(windows: [node]))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        let frame = try #require(decoded.result?.windows?.first?.geometry)
        #expect(frame == ControlWindowFrame(x: 100, y: 40, width: 1200, height: 800, display: 1))
    }

    @Test func windowNodeOmitsGeometryWhenNil() throws {
        let node = ControlWindowNode(id: "w1", name: "work", open: false, active: false)
        let json = String(data: try JSONEncoder().encode(node), encoding: .utf8) ?? ""
        #expect(!json.contains("geometry"), "a nil geometry must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlWindowNode.self, from: Data(json.utf8))
        #expect(decoded.geometry == nil)
    }

    @Test func windowNodeRoundTripsWithFullscreenAndZoom() throws {
        let node = ControlWindowNode(id: "w1", name: "work", open: true, active: true, fullscreen: true, zoomed: false)
        let response = ControlResponse(ok: true, result: ControlResult(windows: [node]))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.windows?.first?.fullscreen == true)
        #expect(decoded.result?.windows?.first?.zoomed == false)
    }

    @Test func windowNodeOmitsFullscreenAndZoomWhenNil() throws {
        let node = ControlWindowNode(id: "w1", name: "work", open: false, active: false)
        let json = String(data: try JSONEncoder().encode(node), encoding: .utf8) ?? ""
        #expect(!json.contains("fullscreen"), "a nil fullscreen must be omitted from the JSON; got \(json)")
        #expect(!json.contains("zoomed"), "a nil zoomed must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlWindowNode.self, from: Data(json.utf8))
        #expect(decoded.fullscreen == nil)
        #expect(decoded.zoomed == nil)
    }

    @Test func windowNodeRoundTripsWithMinimized() throws {
        let frame = ControlWindowFrame(x: 100, y: 50, width: 900, height: 600, display: 0)
        let node = ControlWindowNode(id: "w1", name: "work", open: true, active: false,
                                     geometry: frame, minimized: true)
        let response = ControlResponse(ok: true, result: ControlResult(windows: [node]))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.windows?.first?.minimized == true)
        #expect(decoded.result?.windows?.first?.geometry == frame)
    }

    @Test func windowNodeOmitsMinimizedWhenNil() throws {
        let node = ControlWindowNode(id: "w1", name: "work", open: false, active: false)
        let json = String(data: try JSONEncoder().encode(node), encoding: .utf8) ?? ""
        #expect(!json.contains("minimized"), "a nil minimized must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlWindowNode.self, from: Data(json.utf8))
        #expect(decoded.minimized == nil)
    }

    @Test func windowGoRoundTripsWithDirection() throws {
        let request = ControlRequest(cmd: .windowGo, args: ControlArgs(to: "prev"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .windowGo)
        #expect(decoded.cmd.rawValue == "window.go")
        #expect(WorkspaceNavigation(wire: decoded.args!.to!) == .previous)
    }

    @Test func windowCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .windowNew, args: ControlArgs(name: "work")),
            ControlRequest(cmd: .windowNew, args: ControlArgs(name: "parked", minimized: true)),
            ControlRequest(cmd: .windowList),
            ControlRequest(cmd: .windowSelect, target: "9f3c"),
            ControlRequest(cmd: .windowClose, target: "9f3c"),
            ControlRequest(cmd: .windowRename, target: "active", args: ControlArgs(name: "renamed")),
            ControlRequest(cmd: .windowDelete, target: "9f3c"),
            ControlRequest(cmd: .windowZoom, target: "9f3c"),
            ControlRequest(cmd: .windowFullscreen, target: "9f3c"),
            ControlRequest(cmd: .windowMinimize, target: "9f3c", args: ControlArgs(mode: "on")),
            ControlRequest(cmd: .windowMinimize, target: "active"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
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
}
