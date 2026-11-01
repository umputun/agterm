import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct WorkspaceGoPrefixCommandTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let command = try #require(try Agtermctl.parseAsRoot(argv) as? any RequestCommand)
        return try command.makeRequest()
    }

    @Test func sendsThePrefixWithTheWindow() throws {
        let expected = ControlRequest(cmd: .workspaceGo, args: ControlArgs(window: "w1", prefix: "ag"))
        #expect(try request(["workspace", "go", "--prefix", "ag", "--window", "w1"]) == expected)
    }

    @Test func refusesToAndPrefixTogether() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["workspace", "go", "--to", "next", "--prefix", "ag"]) }
    }

    @Test func roundTripsAndOmitsPrefixWhenNil() throws {
        let request = ControlRequest(cmd: .workspaceGo, args: ControlArgs(prefix: "ag"))
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
        let bare = try JSONEncoder().encode(ControlArgs(to: "next"))
        #expect(!String(decoding: bare, as: UTF8.self).contains("prefix"))
    }
}
