import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct SidebarCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func sidebarDefaultsToggle() throws {
        #expect(try request(["sidebar"]) == ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "toggle")))
    }

    @Test func sidebarHide() throws {
        #expect(try request(["sidebar", "hide"]) == ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "hide")))
    }

    @Test func sidebarModeDefaultsToggle() throws {
        #expect(try request(["sidebar", "mode"]) == ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "toggle")))
    }

    @Test func sidebarModeFlagged() throws {
        #expect(try request(["sidebar", "mode", "flagged"]) == ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "flagged")))
    }

    @Test func sidebarFlaggedLayoutDefaultsToggle() throws {
        #expect(try request(["sidebar", "flagged-layout"])
            == ControlRequest(cmd: .sidebarFlaggedLayout, args: ControlArgs(mode: "toggle")))
    }

    @Test(arguments: ["flat", "plain", "tree"]) func sidebarFlaggedLayoutNamesALayout(_ layout: String) throws {
        #expect(try request(["sidebar", "flagged-layout", layout])
            == ControlRequest(cmd: .sidebarFlaggedLayout, args: ControlArgs(mode: layout)))
    }

    @Test func sidebarFlaggedLayoutRejectsBadLayoutAndAWindowTarget() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["sidebar", "flagged-layout", "grid"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["sidebar", "flagged-layout", "tree", "--window", "w"]) }
    }

    @Test func sidebarDensityDefaultsToggle() throws {
        #expect(try request(["sidebar", "density"]) == ControlRequest(cmd: .sidebarDensity, args: ControlArgs(mode: "toggle")))
    }

    @Test(arguments: ["default", "compact"]) func sidebarDensityNamesADensity(_ density: String) throws {
        #expect(try request(["sidebar", "density", density]) == ControlRequest(cmd: .sidebarDensity, args: ControlArgs(mode: density)))
    }

    @Test func sidebarDensityRejectsBadDensityAndAWindowTarget() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["sidebar", "density", "dense"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["sidebar", "density", "compact", "--window", "w"]) }
    }

    @Test func sidebarModeRejectsBadMode() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["sidebar", "mode", "sideways"]) }
    }

    @Test func sidebarExpand() throws {
        #expect(try request(["sidebar", "expand"]) == ControlRequest(cmd: .sidebarExpand))
    }

    @Test func sidebarCollapse() throws {
        #expect(try request(["sidebar", "collapse"]) == ControlRequest(cmd: .sidebarCollapse))
    }

    @Test func sidebarExpandWithWindow() throws {
        #expect(try request(["sidebar", "expand", "--window", "abc"]) ==
            ControlRequest(cmd: .sidebarExpand, args: ControlArgs(window: "abc")))
    }

    @Test func sidebarCollapseWithWindow() throws {
        #expect(try request(["sidebar", "collapse", "--window", "abc"]) ==
            ControlRequest(cmd: .sidebarCollapse, args: ControlArgs(window: "abc")))
    }

    @Test func sidebarWidth() throws {
        #expect(try request(["sidebar", "width", "271.3"]) ==
            ControlRequest(cmd: .sidebarWidth, args: ControlArgs(sidebarWidth: 271.3)))
    }

    @Test func sidebarWidthWithWindow() throws {
        #expect(try request(["sidebar", "width", "300", "--window", "abc"]) ==
            ControlRequest(cmd: .sidebarWidth, args: ControlArgs(window: "abc", sidebarWidth: 300)))
    }

    @Test func sidebarWidthRejectsNonNumericPoints() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["sidebar", "width", "wide"]) }
    }

    @Test func sidebarWidthRejectsNonFinitePoints() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["sidebar", "width", "nan"]) }
    }
}
