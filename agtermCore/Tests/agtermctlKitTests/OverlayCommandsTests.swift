import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct OverlayCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func rejects(_ argv: [String]) -> Bool {
        (try? Agtermctl.parseAsRoot(argv)) == nil
    }

    @Test func htmlOpenSendsTheNormalizedPageAndGrant() throws {
        let req = try request(["session", "overlay", "open", "--html", "/tmp/a/../a/./r.html", "--cwd", "/tmp/a/",
                               "--pane", "right", "--background-color", "#102030", "--target", "s"])
        #expect(req.cmd == .sessionOverlayOpen)
        #expect(req.args?.html == "/tmp/a/r.html")
        #expect(req.args?.cwd == "/tmp/a")
        #expect(req.args?.command == nil)
        #expect(req.args?.pane == "right")
        #expect(req.args?.color == "#102030")
        #expect(req.args?.navigation == nil)
        let withToolbar = try request(["session", "overlay", "open", "--html", "/tmp/r.html", "--navigation"])
        #expect(withToolbar.args?.navigation == true)
    }

    @Test func aRelativePageResolvesAgainstTheCallersDirectory() throws {
        let req = try request(["session", "overlay", "open", "--html", "out/r.html", "--cwd", "out"])
        let cwd = FileManager.default.currentDirectoryPath
        #expect(req.args?.html == URL(fileURLWithPath: cwd).appendingPathComponent("out/r.html").standardizedFileURL.path)
        #expect(req.args?.cwd == URL(fileURLWithPath: cwd).appendingPathComponent("out").standardizedFileURL.path)
    }

    @Test func urlOpenSendsTheAddressUntouched() throws {
        let req = try request(["session", "overlay", "open", "--url", "http://localhost:5173/a/../b", "--navigation"])
        #expect(req.args?.url == "http://localhost:5173/a/../b")
        #expect(req.args?.html == nil)
        #expect(req.args?.cwd == nil)
        #expect(req.args?.navigation == true)
    }

    @Test func aProgramOpenLeavesItsCwdAsTyped() throws {
        let req = try request(["session", "overlay", "open", "revdiff", "--cwd", "repo"])
        #expect(req.args?.command == "revdiff")
        #expect(req.args?.cwd == "repo")
        #expect(req.args?.html == nil)
    }

    @Test(arguments: [
        ["session", "overlay", "open"],
        ["session", "overlay", "open", "revdiff", "--html", "/tmp/r.html"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--wait"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--block"],
        ["session", "overlay", "open", "revdiff", "--navigation"],
        ["session", "overlay", "open", "revdiff", "--url", "http://localhost:5173/"],
        ["session", "overlay", "open", "--html", "/tmp/r.html", "--url", "http://localhost:5173/"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--wait"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--block"],
        ["session", "overlay", "open", "--url", "http://localhost:5173/", "--cwd", "/tmp"],
    ])
    func openRejectsAMissingOrConflictingContent(_ argv: [String]) {
        #expect(rejects(argv))
    }

    @Test func reloadDefaultsToTheOriginalFile() throws {
        let original = try request(["session", "overlay", "reload", "--pane", "left", "--target", "s"])
        let current = try request(["session", "overlay", "reload", "--current"])
        #expect(original.cmd == .sessionOverlayReload)
        #expect(original.args?.pane == "left")
        #expect(original.args?.current == nil)
        #expect(current.args?.current == true)
        #expect(rejects(["session", "overlay", "reload", "--pane", "middle"]))
    }

    @Test(arguments: ["back", "forward", "browser"])
    func navigateSendsTheStep(_ step: String) throws {
        let req = try request(["session", "overlay", "navigate", step, "--pane", "right"])
        #expect(req.cmd == .sessionOverlayNavigate)
        #expect(req.args?.to == step)
        #expect(req.args?.pane == "right")
    }

    @Test func navigateRejectsAnUnknownStep() {
        #expect(rejects(["session", "overlay", "navigate", "up"]))
        #expect(rejects(["session", "overlay", "navigate"]))
    }
}
