import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct TintCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Agtermctl.parseAsRoot(argv)
            return nil
        } catch {
            return Agtermctl.message(for: error)
        }
    }

    @Test func sessionTintSetsAColorWithoutPlacement() throws {
        let expected = ControlRequest(cmd: .sessionTint, target: "s1", args: ControlArgs(mode: "set", tint: "red"))
        #expect(try request(["session", "tint", "Red", "--target", "s1"]) == expected)
    }

    @Test func sessionTintSplitsTheOnList() throws {
        let req = try request(["session", "tint", "blue", "--on", "icon,name"])
        #expect(req.args?.tintOn == ["icon", "name"])
    }

    @Test func sessionTintClears() throws {
        let expected = ControlRequest(cmd: .sessionTint, target: "active", args: ControlArgs(mode: "clear"))
        #expect(try request(["session", "tint", "clear"]) == expected)
    }

    @Test func workspaceTintTargetsTheWorkspaceCommand() throws {
        let req = try request(["workspace", "tint", "gray", "--on", "name", "--target", "w1"])
        #expect(req == ControlRequest(cmd: .workspaceTint, target: "w1",
                                      args: ControlArgs(mode: "set", tint: "gray", tintOn: ["name"])))
    }

    @Test(arguments: [
        (["session", "tint", "maroon"], "tint must be one of: red|orange|yellow|green|blue|purple|gray|teal|pink|brown|indigo|mint, a #rrggbb color, or clear"),
        (["session", "tint", "#3a7bd"], "tint must be one of: red|orange|yellow|green|blue|purple|gray|teal|pink|brown|indigo|mint, a #rrggbb color, or clear"),
        (["session", "tint", "clear", "--on", "icon"], "--on does not apply to clear"),
        (["session", "tint", "red", "--on", "icon,strip"], "--on must list icon and/or name, comma-separated"),
        (["workspace", "tint", "red", "--on", ""], "--on must list icon and/or name, comma-separated"),
    ])
    func tintRejectsBadInputAtParseTime(_ tc: ([String], String)) {
        #expect(validationMessage(tc.0) == tc.1)
    }

    @Test func sessionNewCarriesTheCreationTint() throws {
        let req = try request(["session", "new", "--tint", "Green", "--tint-on", "icon,name"])
        #expect(req.args?.tint == "green")
        #expect(req.args?.tintOn == ["icon", "name"])
    }

    @Test func tintTakesAHexForSetAndCreation() throws {
        #expect(try request(["session", "tint", "#3A7BD5"]).args == ControlArgs(mode: "set", tint: "#3a7bd5"))
        #expect(try request(["workspace", "tint", "3a7bd5", "--on", "name"]).args
            == ControlArgs(mode: "set", tint: "3a7bd5", tintOn: ["name"]))
        #expect(try request(["session", "new", "--tint", "#3a7bd5"]).args?.tint == "#3a7bd5")
        #expect(try request(["workspace", "new", "--tint", "3A7BD5"]).args?.tint == "3a7bd5")
    }

    @Test func workspaceNewCarriesTheCreationTint() throws {
        let req = try request(["workspace", "new", "prod", "--tint", "red"])
        #expect(req == ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "prod", tint: "red")))
    }

    @Test(arguments: [
        (["session", "new", "--tint-on", "icon"], "--tint-on requires --tint"),
        (["workspace", "new", "--tint", "maroon"], "--tint must be one of: red|orange|yellow|green|blue|purple|gray|teal|pink|brown|indigo|mint, or a #rrggbb color"),
        (["workspace", "new", "--tint", "red", "--tint-on", "both"], "--tint-on must list icon and/or name, comma-separated"),
    ])
    func creationTintRejectsBadInputAtParseTime(_ tc: ([String], String)) {
        #expect(validationMessage(tc.0) == tc.1)
    }
}
