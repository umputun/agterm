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

    @Test func decodeThrowsOnAnUnknownColor() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SidebarTint.self, from: Data(#"{"color":"teal","on":["icon"]}"#.utf8))
        }
    }

    @Test func updateResolvesAgainstTheCurrentTint() {
        let named = SidebarTint(color: .green, parts: [.name])
        #expect(ControlTintUpdate.set(.red, parts: nil).resolved(over: named) == SidebarTint(color: .red, parts: [.name]))
        #expect(ControlTintUpdate.set(.red, parts: nil).resolved(over: nil) == SidebarTint(color: .red))
        #expect(ControlTintUpdate.set(.red, parts: [.icon, .name]).resolved(over: named)
            == SidebarTint(color: .red, parts: [.icon, .name]))
        #expect(ControlTintUpdate.clear.resolved(over: named) == nil)
    }
}
