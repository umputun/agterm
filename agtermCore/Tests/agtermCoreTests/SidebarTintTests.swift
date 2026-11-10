import Foundation
import Testing
@testable import agtermCore

struct SidebarTintTests {
    @Test func partsAreOrderedAndNeverEmpty() {
        #expect(SidebarTint(color: .red, parts: [.name, .icon]).parts == [.icon, .name])
        #expect(SidebarTint(color: .red, parts: []).parts == [.icon])
        #expect(SidebarTint(color: .red, parts: [.name, .icon]) == SidebarTint(color: .red, parts: [.icon, .name]))
        #expect(SidebarTint(color: .red, parts: [.name]).shows(.name))
        #expect(!SidebarTint(color: .red, parts: [.name]).shows(.icon))
    }

    static let knownParts: [([String], Set<TintPart>)] = [
        (["icon"], [.icon]),
        (["name", "icon"], [.icon, .name]),
        ([" Name "], [.name]),
        (["icon", "icon"], [.icon]),
    ]

    @Test(arguments: knownParts)
    func parsePartsAcceptsKnownParts(_ tc: ([String], Set<TintPart>)) {
        #expect(SidebarTint.parseParts(tc.0) == tc.1)
    }

    @Test(arguments: [[String](), ["strip"], ["icon", ""], ["icon", "both"]])
    func parsePartsRejectsEmptyOrUnknown(raw: [String]) {
        #expect(SidebarTint.parseParts(raw) == nil)
    }

    @Test func recolorKeepsPartsAndStartsUntintedOnTheIcon() {
        let named = SidebarTint(color: .green, parts: [.name])
        #expect(SidebarTint.recolor(named, to: .red) == SidebarTint(color: .red, parts: [.name]))
        #expect(SidebarTint.recolor(nil, to: .red) == SidebarTint(color: .red, parts: [.icon]))
        #expect(SidebarTint.recolor(named, to: nil) == nil)
    }

    @Test func placeKeepsColorAndLeavesUntintedAlone() {
        #expect(SidebarTint.place(SidebarTint(color: .blue), on: [.name]) == SidebarTint(color: .blue, parts: [.name]))
        #expect(SidebarTint.place(nil, on: [.name]) == nil)
    }

    @Test func codableRoundTripsColorAndParts() throws {
        let tint = SidebarTint(color: .purple, parts: [.icon, .name])
        let data = try JSONEncoder().encode(tint)
        #expect(String(decoding: data, as: UTF8.self).contains("\"on\":[\"icon\",\"name\"]"))
        #expect(try JSONDecoder().decode(SidebarTint.self, from: data) == tint)
    }

    @Test func decodeSkipsUnknownPartsAndDefaultsToTheIcon() throws {
        let unknown = try JSONDecoder().decode(SidebarTint.self, from: Data(#"{"color":"red","on":["strip","name"]}"#.utf8))
        #expect(unknown == SidebarTint(color: .red, parts: [.name]))
        let missing = try JSONDecoder().decode(SidebarTint.self, from: Data(#"{"color":"red"}"#.utf8))
        #expect(missing == SidebarTint(color: .red, parts: [.icon]))
        let garbled = try JSONDecoder().decode(SidebarTint.self, from: Data(#"{"color":"red","on":"icon"}"#.utf8))
        #expect(garbled == SidebarTint(color: .red, parts: [.icon]))
    }

    @Test(arguments: ["maroon", "#12345", "#1234567", "#12345g"])
    func decodeThrowsOnAnUnknownColor(color: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SidebarTint.self, from: Data(#"{"color":"\#(color)","on":["icon"]}"#.utf8))
        }
    }

    @Test func paletteListsTheTwelveNamesInMenuOrder() {
        #expect(TintColor.validNamesList == "red|orange|yellow|green|blue|purple|gray|teal|pink|brown|indigo|mint")
    }

    static let parsedValues: [(String, TintValue)] = [
        ("red", .named(.red)),
        ("Teal", .named(.teal)),
        ("#3A7BD5", .hex("#3a7bd5")),
        ("3a7bd5", .hex("#3a7bd5")),
    ]

    @Test(arguments: parsedValues)
    func valueParsesANameOrANormalizedHex(_ tc: (String, TintValue)) {
        #expect(TintValue(rawValue: tc.0) == tc.1)
    }

    @Test(arguments: ["", "maroon", "#3a7bd", "#3a7bd5ff", "#3a7bdz", "##3a7bd5"])
    func valueRejectsAnythingElse(raw: String) {
        #expect(TintValue(rawValue: raw) == nil)
    }

    @Test func valueRawIsTheNameOrTheHex() {
        #expect(TintValue.named(.indigo).rawValue == "indigo")
        #expect(TintValue.hex("#3a7bd5").rawValue == "#3a7bd5")
    }

    @Test func hexTintEncodesAsOneColorString() throws {
        let tint = SidebarTint(color: .hex("#3a7bd5"), parts: [.name])
        let data = try JSONEncoder().encode(tint)
        #expect(String(decoding: data, as: UTF8.self).contains(##""color":"#3a7bd5""##))
        #expect(try JSONDecoder().decode(SidebarTint.self, from: data) == tint)
    }

    @Test func namedTintKeepsItsSnapshotSpelling() throws {
        let data = try JSONEncoder().encode(SidebarTint(color: .mint))
        #expect(String(decoding: data, as: UTF8.self).contains(#""color":"mint""#))
        #expect(SidebarTint(color: .mint) == SidebarTint(color: TintValue.named(.mint)))
    }

    @Test func recolorTakesAHexAndKeepsParts() {
        let named = SidebarTint(color: .green, parts: [.name])
        #expect(SidebarTint.recolor(named, to: .hex("#3a7bd5")) == SidebarTint(color: .hex("#3a7bd5"), parts: [.name]))
        #expect(SidebarTint.recolor(SidebarTint(color: .hex("#3a7bd5"), parts: [.name]), to: .red)
            == SidebarTint(color: .red, parts: [.name]))
    }

    @Test func recolorStartsAnUntintedRowOnTheGivenPlacement() {
        let named = SidebarTint(color: .green, parts: [.name])
        #expect(SidebarTint.recolor(nil, to: .named(.red), startingOn: [.icon, .name]) == SidebarTint(color: .red, parts: [.icon, .name]))
        #expect(SidebarTint.recolor(named, to: .named(.red), startingOn: [.icon]) == SidebarTint(color: .red, parts: [.name]))
    }

    @Test func updateResolvesAgainstTheCurrentTint() {
        let named = SidebarTint(color: .green, parts: [.name])
        #expect(ControlTintUpdate.set(.red, parts: nil).resolved(over: named) == SidebarTint(color: .red, parts: [.name]))
        #expect(ControlTintUpdate.set(.red, parts: nil).resolved(over: nil) == SidebarTint(color: .red))
        #expect(ControlTintUpdate.set(.red, parts: [.icon, .name]).resolved(over: named)
            == SidebarTint(color: .red, parts: [.icon, .name]))
        #expect(ControlTintUpdate.clear.resolved(over: named) == nil)
        #expect(ControlTintUpdate.set(TintValue.hex("#3a7bd5"), parts: nil).resolved(over: named)
            == SidebarTint(color: .hex("#3a7bd5"), parts: [.name]))
    }
}
