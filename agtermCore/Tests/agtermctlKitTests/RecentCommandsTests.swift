import ArgumentParser
import Testing
import agtermCore
@testable import agtermctlKit

struct RecentCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func listAndClearCarryNoArgs() throws {
        #expect(try request(["recent", "list"]) == ControlRequest(cmd: .recentList))
        #expect(try request(["recent", "clear"]) == ControlRequest(cmd: .recentClear))
    }

    @Test(arguments: ["list", "clear"])
    func listAndClearRejectAWindowSelector(_ sub: String) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["recent", sub, "--window", "w1"]) }
    }

    @Test func openWithoutAnIdAsksForTheNewestEntry() throws {
        #expect(try request(["recent", "open"]) == ControlRequest(cmd: .recentOpen))
    }

    @Test func openCarriesTheIdAndWindow() throws {
        #expect(try request(["recent", "open", "ab12", "--window", "w1"])
            == ControlRequest(cmd: .recentOpen, target: "ab12", args: ControlArgs(window: "w1")))
    }
}
