import Foundation
import Testing
@testable import agtermCore

@Suite struct ControlKeymapTests {
    @Test func projectsEveryBuiltinActionInDeclarationOrder() {
        let payload = ControlKeymap.project(keymap: Keymap(builtinOverrides: [:], commands: []),
                                            diagnostics: [], path: "/tmp/keymap.conf")

        #expect(payload.actions.count == BuiltinAction.allCases.count)
        #expect(payload.actions.map(\.action) == BuiltinAction.allCases.map(\.rawValue))
        #expect(payload.path == "/tmp/keymap.conf")
    }

    @Test func reportsShippedDefaultsUnmarked() throws {
        let payload = ControlKeymap.project(keymap: Keymap(builtinOverrides: [:], commands: []),
                                            diagnostics: [], path: "/tmp/keymap.conf")
        let close = try #require(payload.actions.first { $0.action == "close_session" })

        #expect(close.chord == "cmd+w")
        #expect(close.overridden == nil, "a shipped default is not an override")
    }

    @Test func marksAnOverriddenActionAndReportsItsNewChord() throws {
        let keymap = Keymap(builtinOverrides: [.closeSession: Chord(mods: [.command], key: "e")], commands: [])
        let payload = ControlKeymap.project(keymap: keymap, diagnostics: [], path: "/tmp/keymap.conf")
        let close = try #require(payload.actions.first { $0.action == "close_session" })

        #expect(close.chord == "cmd+e")
        #expect(close.overridden == true)
    }

    // the listing is the whole action set, not the bound subset — a caller checking "what is free"
    // needs the gaps.
    @Test func keylessActionsAppearWithNoChord() throws {
        let payload = ControlKeymap.project(keymap: Keymap(builtinOverrides: [:], commands: []),
                                            diagnostics: [], path: "/tmp/keymap.conf")
        let keyless = BuiltinAction.allCases.filter { $0.defaultChord == nil }
        try #require(!keyless.isEmpty, "the fixture assumes some actions ship keyless")

        for action in keyless {
            let row = try #require(payload.actions.first { $0.action == action.rawValue })
            #expect(row.chord == nil)
        }
    }

    // `overridden` compares CHORDS, not "is there a map line".
    @Test func mappingAnActionToItsOwnDefaultIsNotAnOverride() throws {
        let parsed = parseKeymap("map cmd+w close_session\n")
        try #require(parsed.diagnostics.isEmpty, "an identity map is a clean line")
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: parsed.diagnostics,
                                            path: "/tmp/keymap.conf")
        let close = try #require(payload.actions.first { $0.action == "close_session" })

        #expect(close.chord == "cmd+w")
        #expect(close.overridden == nil, "the action is still on its default, so nothing was overridden")
    }

    @Test func mappingAKeylessActionCountsAsAnOverride() throws {
        let keyless = try #require(BuiltinAction.allCases.first { $0.defaultChord == nil })
        let keymap = Keymap(builtinOverrides: [keyless: Chord(mods: [.command], key: "y")], commands: [])
        let payload = ControlKeymap.project(keymap: keymap, diagnostics: [], path: "/tmp/keymap.conf")
        let row = try #require(payload.actions.first { $0.action == keyless.rawValue })

        #expect(row.chord == "cmd+y")
        #expect(row.overridden == true)
    }

    @Test func carriesCustomCommandsAndDistinguishesPaletteOnlyOnes() throws {
        let text = """
        command "Bound" cmd+shift+e echo hi
        command "Palette Only" echo hi
        """
        let parsed = parseKeymap(text)
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: parsed.diagnostics,
                                            path: "/tmp/keymap.conf")

        #expect(payload.commands.count == 2)
        #expect(payload.commands.first { $0.name == "Bound" }?.shortcut == "cmd+shift+e")
        #expect(payload.commands.first { $0.name == "Palette Only" }?.shortcut == nil,
                "an empty shortcut reads as palette-only, not as a chord")
    }

    @Test func carriesParseDiagnostics() {
        let parsed = parseKeymap("map cmd+shift+d not_an_action\n")
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: parsed.diagnostics,
                                            path: "/tmp/keymap.conf")

        #expect(payload.diagnostics.count == parsed.diagnostics.count)
        #expect(payload.diagnostics.first?.line == 1)
        #expect(payload.diagnostics.first?.message == parsed.diagnostics.first?.message)
    }

    @Test func reportsAlternativesBesideTheMenuChord() throws {
        let parsed = parseKeymap("map cmd+t|ctrl+space>s toggle_split")
        try #require(parsed.diagnostics.isEmpty)
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: [], path: "/tmp/keymap.conf")
        let row = try #require(payload.actions.first { $0.action == "toggle_split" })

        #expect(row.chord == "cmd+t", "chord stays the menu key equivalent alone")
        #expect(row.alternates == ["ctrl+space>s"])
        #expect(row.overridden == true)
    }

    @Test func reportsEveryAlternativeInLineOrder() throws {
        let parsed = parseKeymap("map cmd+t|ctrl+space>s|cmd+ctrl+y toggle_split")
        try #require(parsed.diagnostics.isEmpty)
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: [], path: "/tmp/keymap.conf")
        let row = try #require(payload.actions.first { $0.action == "toggle_split" })

        #expect(row.alternates == ["ctrl+space>s", "ctrl+cmd+y"], "kitty syntax, in the modifier order displayString fixes")
    }

    // an unbound action's shipped default must not resurface here: the file said it has no menu chord.
    @Test func reportsAnUnboundActionWithAlternativesOnly() throws {
        let parsed = parseKeymap("map ctrl+space>s toggle_split")
        try #require(parsed.diagnostics.isEmpty)
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: [], path: "/tmp/keymap.conf")
        let row = try #require(payload.actions.first { $0.action == "toggle_split" })

        #expect(row.chord == nil)
        #expect(row.alternates == ["ctrl+space>s"])
        #expect(row.overridden == true)
    }

    @Test func omitsAlternatesForAnActionWithNone() throws {
        let payload = ControlKeymap.project(keymap: Keymap(builtinOverrides: [:], commands: []),
                                            diagnostics: [], path: "/tmp/keymap.conf")
        #expect(payload.actions.allSatisfy { $0.alternates == nil })

        let encoded = try JSONEncoder().encode(payload)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("alternates"))
    }

    @Test func alternatesRoundTripOverTheWire() throws {
        let parsed = parseKeymap("map cmd+t|ctrl+space>s toggle_split")
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: [], path: "/tmp/keymap.conf")
        let encoded = try JSONEncoder().encode(ControlResponse(ok: true, result: ControlResult(keymap: payload)))
        let back = try #require(try JSONDecoder().decode(ControlResponse.self, from: encoded).result?.keymap)

        #expect(back == payload)
        #expect(back.actions.first { $0.action == "toggle_split" }?.alternates == ["ctrl+space>s"])
    }

    @Test func projectsAPipeFreeKeymapWithNoAlternatesAtAll() throws {
        let parsed = parseKeymap(pipeFreeKeymapFixture)
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: parsed.diagnostics,
                                            path: "/tmp/keymap.conf")

        #expect(payload.actions.allSatisfy { $0.alternates == nil })
        #expect(payload.actions.map(\.action) == BuiltinAction.allCases.map(\.rawValue))
        let chord: (String) -> String? = { name in payload.actions.first { $0.action == name }?.chord }
        #expect(chord("toggle_split") == "cmd+shift+e")
        #expect(chord("toggle_sidebar") == "t")
        #expect(chord("focus_left_pane") == "ctrl+cmd+left")
        #expect(chord("close_session") == "cmd+w")
        #expect(chord("new_session") == "cmd+n", "its colliding map was dropped, so it keeps its default")
        #expect(chord("first_session") == nil, "a keyless action reports no chord")
        let encoded = try JSONEncoder().encode(payload)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("alternates"))
    }

    @Test func menuIsOmittedWhenTheCallerSuppliesNone() {
        let payload = ControlKeymap.project(keymap: Keymap(builtinOverrides: [:], commands: []),
                                            diagnostics: [], path: "/tmp/keymap.conf")
        #expect(payload.menu == nil)
    }

    // the model can say cmd+w while the menu carries it elsewhere; both halves must survive the wire
    // for a caller to see that.
    @Test func roundTripsWithDivergingModelAndMenuChords() throws {
        let keymap = Keymap(builtinOverrides: [.closeSession: Chord(mods: [.command], key: "e")], commands: [])
        let menu = [ControlKeymapMenuItem(menu: "File", title: "Close", chord: "cmd+w", selector: "performClose:")]
        let payload = ControlKeymap.project(keymap: keymap, diagnostics: [], path: "/tmp/keymap.conf", menu: menu)
        let response = ControlResponse(ok: true, result: ControlResult(keymap: payload))

        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: encoded)
        let back = try #require(decoded.result?.keymap)

        #expect(back == payload)
        #expect(back.actions.first { $0.action == "close_session" }?.chord == "cmd+e")
        #expect(back.menu?.first?.chord == "cmd+w")
        #expect(back.menu?.first?.selector == "performClose:")
    }

    @Test func keymapListRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .keymapList)
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: encoded)
        #expect(decoded.cmd == .keymapList)
    }

    @Test func keymapListRawStringMapsToCommand() throws {
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"cmd":"keymap.list"}"#.utf8))
        #expect(decoded.cmd == .keymapList)
    }

    @Test func resultOmitsKeymapWhenNil() throws {
        let encoded = try JSONEncoder().encode(ControlResponse(ok: true, result: ControlResult()))
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("keymap"))
    }
}
