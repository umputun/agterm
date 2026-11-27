import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct SessionCloseCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func undoableSingleTarget() throws {
        #expect(try request(["session", "close", "--target", "x", "--undoable"])
            == ControlRequest(cmd: .sessionClose, target: "x", args: ControlArgs(undoable: true)))
    }

    @Test func ordinaryCloseStillAcceptsRelativeWindowSelectors() throws {
        for window in ["active", "4ad2"] {
            #expect(try request(["session", "close", "--target", "x", "--window", window])
                == ControlRequest(cmd: .sessionClose, target: "x", args: ControlArgs(window: window)))
        }
    }

    @Test func closeHelpDistinguishesWindowSelectors() {
        let help = Session.Close.helpMessage(columns: 200)
        #expect(help.contains("unique prefix, or 'active' for ordinary close"))
        #expect(help.contains("With --expect-companions, use a full local window UUID"))
    }

    @Test func undoableDefaultsToTheActiveSession() throws {
        #expect(try request(["session", "close", "--undoable"])
            == ControlRequest(cmd: .sessionClose, target: "active", args: ControlArgs(undoable: true)))
    }

    @Test func undoableBatchKeepsTheTargetsAndWindow() throws {
        let expected = ControlRequest(cmd: .sessionClose, target: "a",
                                      args: ControlArgs(targets: ["a", "b"], window: "w1", undoable: true))
        #expect(try request(["session", "close", "--target", "a", "--target", "b", "--undoable", "--window", "w1"])
            == expected)
    }

    @Test func terminateSendsTheTerminateCommandAndPlainCloseDoesNot() throws {
        #expect(try request(["session", "close", "--terminate", "--target", "a", "--target", "b", "--undoable"])
            == ControlRequest(cmd: .sessionTerminate, target: "a", args: ControlArgs(targets: ["a", "b"], undoable: true)))
        #expect(try request(["session", "close", "--terminate"]) == ControlRequest(cmd: .sessionTerminate, target: "active"))
        #expect(try request(["session", "close", "--target", "a"]) == ControlRequest(cmd: .sessionClose, target: "a"))
    }

    @Test func checkedCloseUsesItsOwnCommandAndPreservesAnEmptyExpectation() throws {
        let id = UUID().uuidString
        let child = UUID()
        let page = UUID()
        let window = UUID().uuidString
        let command = ["session", "close", "--target", id, "--expect-companions"]

        #expect(try request(command + [""]) == ControlRequest(cmd: .sessionCloseChecked, target: id, args: ControlArgs(expectCompanions: [])))
        #expect(try request(command + ["\(child.uuidString.lowercased()),\(page.uuidString)", "--window", window])
            == ControlRequest(cmd: .sessionCloseChecked, target: id, args: ControlArgs(window: window, expectCompanions: [child, page])))
    }

    @Test func checkedCloseRejectsInvalidListsAndIncompatibleOptions() throws {
        let id = UUID().uuidString
        let command = ["session", "close", "--expect-companions", ""]
        let targeted = command + ["--target", id]
        #expect(throws: ValidationError.self) { try request(command) }
        #expect(throws: ValidationError.self) { try request(command + ["--target", String(id.prefix(8))]) }
        #expect(throws: ValidationError.self) { try request(targeted + ["--target", id]) }
        #expect(throws: ValidationError.self) { try request(targeted + ["--undoable"]) }
        #expect(throws: ValidationError.self) { try request(targeted + ["--terminate"]) }
        #expect(throws: ValidationError.self) { try request(targeted + ["--window", "active"]) }
        #expect(throws: ValidationError.self) { try request(targeted + ["--op-id", "op", "--epoch", "epoch"]) }
        for list in ["active", String(id.prefix(8)), "\(id),", ",\(id)", "\(id),,\(id)"] {
            #expect(throws: ValidationError.self) { try request(["session", "close", "--target", id, "--expect-companions", list]) }
        }
    }

    private static let forwards: [(AttachedForward, ControlRequest)] = [
        (.terminate(sessions: ["a"], undoable: false), ControlRequest(cmd: .sessionClose, target: "a")),
        (.terminate(sessions: ["a", "b"], undoable: true),
         ControlRequest(cmd: .sessionClose, target: "a", args: ControlArgs(targets: ["a", "b"], undoable: true))),
        (.duplicate(after: "s", cwd: "-d"), ControlRequest(cmd: .sessionNew, args: ControlArgs(cwd: "-d", noSelect: true, after: "s"))),
        (.duplicate(after: "s", cwd: nil), ControlRequest(cmd: .sessionNew, args: ControlArgs(noSelect: true, after: "s"))),
        (.split(session: "s", mode: "on", axis: "horizontal"),
         ControlRequest(cmd: .sessionSplit, target: "s", args: ControlArgs(mode: "on", axis: "horizontal"))),
        (.split(session: "s", mode: "off", axis: nil), ControlRequest(cmd: .sessionSplit, target: "s", args: ControlArgs(mode: "off"))),
        (.closeSplit(session: "s"), ControlRequest(cmd: .sessionSplitClose, target: "s")),
        (.scratch(session: "s", mode: "on", command: "-x"),
         ControlRequest(cmd: .sessionScratch, target: "s", args: ControlArgs(mode: "on", command: "-x"))),
        (.scratch(session: "s", mode: "toggle", command: nil), ControlRequest(cmd: .sessionScratch, target: "s", args: ControlArgs(mode: "toggle"))),
    ]

    @Test(arguments: forwards.map(\.0))
    func anAttachedForwardParsesOnItsOriginAsItsCommand(forward: AttachedForward) throws {
        let expected = try #require(Self.forwards.first { $0.0 == forward }?.1)

        let parsed = try request(forward.originArgv)

        #expect(parsed == expected)
        #expect(parsed.cmd == forward.command)
    }
}

extension AttachedForward {
    var originArgv: [String] { words + ["--json"] + (operands.isEmpty ? [] : ["--"] + operands) }
}
