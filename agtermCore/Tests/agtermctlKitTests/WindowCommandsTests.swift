import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

/// `agtermctl window …` argv parsing: which subcommand each spelling reaches and the `ControlRequest` it
/// builds. Split out of `CommandsTests` for the swiftlint file limit.
struct WindowCommandsTests {
    /// Parse argv into a subcommand and build its `ControlRequest`. Throws if parsing or request-building fails.
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func windowNewWithName() throws {
        #expect(try request(["window", "new", "Work"]) == ControlRequest(cmd: .windowNew, args: ControlArgs(name: "Work")))
    }

    @Test func windowNewWithoutName() throws {
        #expect(try request(["window", "new"]) == ControlRequest(cmd: .windowNew, args: ControlArgs(name: nil)))
    }

    @Test func windowNewMinimized() throws {
        #expect(try request(["window", "new", "Work", "--minimized"])
            == ControlRequest(cmd: .windowNew, args: ControlArgs(name: "Work", minimized: true)))
        // omitted rather than false, so an un-flagged create stays byte-identical on the wire
        #expect(try request(["window", "new", "Work"])
            == ControlRequest(cmd: .windowNew, args: ControlArgs(name: "Work", minimized: nil)))
    }

    @Test func windowList() throws {
        #expect(try request(["window", "list"]) == ControlRequest(cmd: .windowList))
    }

    @Test func windowSelect() throws {
        #expect(try request(["window", "select", "9f3c"]) == ControlRequest(cmd: .windowSelect, target: "9f3c"))
    }

    @Test func windowSelectDefaultsActive() throws {
        #expect(try request(["window", "select"]) == ControlRequest(cmd: .windowSelect, target: "active"))
    }

    @Test func windowClose() throws {
        #expect(try request(["window", "close", "ab"]) == ControlRequest(cmd: .windowClose, target: "ab"))
    }

    @Test func windowRename() throws {
        let expected = ControlRequest(cmd: .windowRename, target: "9f3c", args: ControlArgs(name: "Renamed"))
        #expect(try request(["window", "rename", "9f3c", "Renamed"]) == expected)
    }

    @Test func windowDelete() throws {
        #expect(try request(["window", "delete", "9f3c"]) == ControlRequest(cmd: .windowDelete, target: "9f3c"))
    }

    @Test func windowResize() throws {
        let expected = ControlRequest(cmd: .windowResize, target: "9f3c", args: ControlArgs(width: 1200, height: 800))
        #expect(try request(["window", "resize", "9f3c", "--width", "1200", "--height", "800"]) == expected)
    }

    @Test func windowResizeDefaultsToActive() throws {
        let expected = ControlRequest(cmd: .windowResize, target: "active", args: ControlArgs(width: 1000, height: 700))
        #expect(try request(["window", "resize", "--width", "1000", "--height", "700"]) == expected)
    }

    @Test func windowMoveWithDisplay() throws {
        let expected = ControlRequest(cmd: .windowMove, target: "9f3c", args: ControlArgs(x: 100, y: 50, display: 1))
        #expect(try request(["window", "move", "9f3c", "--x", "100", "--y", "50", "--display", "1"]) == expected)
    }

    @Test func windowMoveDefaultsActiveAndCurrentDisplay() throws {
        let expected = ControlRequest(cmd: .windowMove, target: "active", args: ControlArgs(x: 100, y: 50))
        #expect(try request(["window", "move", "--x", "100", "--y", "50"]) == expected)
    }

    @Test func windowZoom() throws {
        #expect(try request(["window", "zoom", "9f3c"]) == ControlRequest(cmd: .windowZoom, target: "9f3c"))
    }

    @Test func windowFullscreen() throws {
        #expect(try request(["window", "fullscreen", "9f3c"]) == ControlRequest(cmd: .windowFullscreen, target: "9f3c"))
    }

    @Test func windowFullscreenDefaultsActive() throws {
        #expect(try request(["window", "fullscreen"]) == ControlRequest(cmd: .windowFullscreen, target: "active"))
    }

    @Test func windowMinimize() throws {
        #expect(try request(["window", "minimize", "9f3c", "on"])
            == ControlRequest(cmd: .windowMinimize, target: "9f3c", args: ControlArgs(mode: "on")))
        #expect(try request(["window", "minimize", "9f3c", "off"])
            == ControlRequest(cmd: .windowMinimize, target: "9f3c", args: ControlArgs(mode: "off")))
    }

    @Test func windowMinimizeDefaultsActiveAndToggle() throws {
        #expect(try request(["window", "minimize"])
            == ControlRequest(cmd: .windowMinimize, target: "active", args: ControlArgs(mode: "toggle")))
    }

    @Test func windowMinimizeBareModeTargetsActive() throws {
        // both positionals are optional, so a bare mode word would otherwise bind to the id; a window
        // address is a hex prefix or `active`, never a mode word, so the recovery can't misfire.
        #expect(try request(["window", "minimize", "on"])
            == ControlRequest(cmd: .windowMinimize, target: "active", args: ControlArgs(mode: "on")))
        #expect(try request(["window", "minimize", "toggle"])
            == ControlRequest(cmd: .windowMinimize, target: "active", args: ControlArgs(mode: "toggle")))
        // an id that merely looks like a mode word is still an id (hex `0ff`, not the word `off`)
        #expect(try request(["window", "minimize", "0ff"])
            == ControlRequest(cmd: .windowMinimize, target: "0ff", args: ControlArgs(mode: "toggle")))
    }

    @Test func windowDeleteDefaultsActive() throws {
        #expect(try request(["window", "delete"]) == ControlRequest(cmd: .windowDelete, target: "active"))
    }

    @Test func windowRenameRequiresBothArgsFails() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "rename", "9f3c"]) }
    }

    @Test func windowCommandsRejectWindowSelector() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "list", "--window", "w1"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "select", "9f3c", "--window", "w1"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["quick", "--window", "w1"]) }
    }

    @Test func windowCommandsKeepSocketAndJSON() throws {
        let parsed = try Agtermctl.parseAsRoot(["window", "list", "--socket", "/tmp/x.sock", "--json"])
        let command = try #require(parsed as? Window.List)
        #expect(command.options.json)
        #expect(command.options.socketPath(env: [:]) == "/tmp/x.sock")
    }

    @Test func windowGo() throws {
        #expect(try request(["window", "go", "--to", "next"]) == ControlRequest(cmd: .windowGo, args: ControlArgs(to: "next")))
        #expect(try request(["window", "go", "--to", "prev"]) == ControlRequest(cmd: .windowGo, args: ControlArgs(to: "prev")))
    }

    @Test func windowGoTakesNoIdAndRequiresADirection() {
        // the other window subcommands take an id first; this one is relative, so a bare word is not a target
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "go", "active"]) }
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["window", "go"]) }
    }
}
