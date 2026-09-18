import Foundation
import Testing
@testable import agtermCore

struct CommandErrorOptionsTests {
    @Test func defaultsToNoPanelAndSessionCenter() throws {
        let command = try #require(parseKeymap("command \"probe\" ./script").keymap.commands.first)
        #expect(!command.errorHud)
        #expect(command.errorPosition == .center)
        #expect(command.errorPane == nil)
    }

    @Test(arguments: ["", "ctrl+a>p "])
    func bareEnableKeepsPlacementDefaults(shortcut: String) throws {
        let parsed = parseKeymap("command \"probe\" \(shortcut)--error-hud ./script")
        #expect(parsed.diagnostics.isEmpty)
        let command = try #require(parsed.keymap.commands.first)
        #expect(command.errorHud)
        #expect(command.errorPosition == .center)
        #expect(command.errorPane == nil)
        #expect(command.shortcut == shortcut.trimmingCharacters(in: .whitespaces))
    }

    @Test(arguments: [
        "--error-hud --error-position top-right --error-pane left",
        "--error-pane left --error-position top-right --error-hud",
        "--error-position top-right --error-hud --error-pane left"
    ], ["", "ctrl+a>p "])
    func acceptsPlacementOptionsInAnyOrder(options: String, shortcut: String) throws {
        let parsed = parseKeymap("command \"probe\" \(shortcut)\(options) ./script")
        #expect(parsed.diagnostics.isEmpty)
        let command = try #require(parsed.keymap.commands.first)
        #expect(command.errorHud)
        #expect(command.errorPosition == .topRight)
        #expect(command.errorPane == .left)
        #expect(command.command == "./script")
    }

    @Test(arguments: HudPosition.allCases.map(\.rawValue) + ["top", "bottom"])
    func sharesHudPositionVocabulary(position: String) throws {
        let parsed = parseKeymap("command \"probe\" --error-hud --error-position \(position) ./script")
        #expect(parsed.diagnostics.isEmpty)
        #expect(try #require(parsed.keymap.commands.first).errorPosition == HudPosition.parse(position))
    }

    @Test func customCommandOptionsSurviveCodable() throws {
        let command = CustomCommand(name: "probe", command: "./script", shortcut: "",
                                    errorHud: true, errorPosition: .bottomLeft, errorPane: .right)
        let encoded = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(CustomCommand.self, from: encoded) == command)
    }

    @Test func oldCommandPayloadKeepsTheOldDefault() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"probe","command":"false","shortcut":""}"#.utf8)
        let command = try JSONDecoder().decode(CustomCommand.self, from: data)
        #expect(!command.errorHud)
        #expect(command.errorPosition == .center)
        #expect(command.errorPane == nil)
    }

    @Test func projectsAndRoundTripsErrorOptions() throws {
        let parsed = parseKeymap("""
        command "quiet" ./script
        command "loud" --error-hud --error-position bottom --error-pane right ./script
        """)
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: parsed.diagnostics, path: "/tmp/keymap.conf")
        try #require(payload.commands.count == 2)
        #expect(payload.commands[0].errorHud == false)
        #expect(payload.commands[0].errorPosition == .center)
        #expect(payload.commands[0].errorPane == nil)
        #expect(payload.commands[1].errorHud == true)
        #expect(payload.commands[1].errorPosition == .bottomCenter)
        #expect(payload.commands[1].errorPane == .right)
        #expect(try JSONDecoder().decode(ControlKeymap.self, from: JSONEncoder().encode(payload)) == payload)
    }

    @Test func oldReadBackPayloadKeepsTheOldDefault() throws {
        let command = try JSONDecoder().decode(ControlKeymapCommand.self, from: Data(#"{"name":"probe"}"#.utf8))
        #expect(!command.errorHud)
        #expect(command.errorPosition == .center)
        #expect(command.errorPane == nil)
    }

    @Test(arguments: ["", "ctrl+a>p "])
    func consumesOptionsBeforeTheShellBody(shortcut: String) throws {
        let parsed = parseKeymap("command \"probe\" \(shortcut)--error-hud ./script --error-pane right")
        #expect(parsed.diagnostics.isEmpty)
        let command = try #require(parsed.keymap.commands.first)
        #expect(command.command == "./script --error-pane right")
    }

    @Test(arguments: [
        "--error-position top echo ok", "--error-pane left echo ok",
        "--error-hud --error-position", "--error-hud --error-pane",
        "--error-hud --error-position sideways echo ok", "--error-hud --error-pane scratch echo ok",
        "--error-hud --error-position --error-pane left echo ok",
        "--error-hud --error-hud echo ok",
        "--error-hud --error-position top --error-position bottom echo ok",
        "--error-hud --error-pane left --error-pane right echo ok",
        "--error-positon top echo ok", "--error-hud=on echo ok",
        "--error-hud", "--error-hud --", "--"
    ])
    func rejectsMalformedOptions(body: String) {
        let parsed = parseKeymap("command \"probe\" \(body)")
        #expect(parsed.keymap.commands.isEmpty)
        #expect(parsed.diagnostics.count == 1)
        #expect(parsed.diagnostics.first?.line == 1)
    }

    @Test(arguments: ["", "ctrl+a>p "])
    func terminatorEscapesReservedShellNames(shortcut: String) throws {
        let parsed = parseKeymap("command \"probe\" \(shortcut)-- --error-hud 'two  spaces'")
        #expect(parsed.diagnostics.isEmpty)
        #expect(try #require(parsed.keymap.commands.first).command == "--error-hud 'two  spaces'")
    }

    @Test func preservesShellQuotingAndWhitespaceAfterThePrefix() throws {
        let body = #"env  FLAG='two  spaces' ./script --error-pane right; printf '%s' "a  b""#
        let parsed = parseKeymap("command \"probe\" --error-hud \(body)")
        #expect(parsed.diagnostics.isEmpty)
        #expect(try #require(parsed.keymap.commands.first).command == body)
    }

    @Test func doesNotParseAChordAfterOptions() throws {
        let parsed = parseKeymap("command \"probe\" --error-hud ctrl+a>p ./script")
        #expect(parsed.diagnostics.isEmpty)
        let command = try #require(parsed.keymap.commands.first)
        #expect(command.shortcut.isEmpty)
        #expect(command.command == "ctrl+a>p ./script")
    }
}
