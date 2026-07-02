import Foundation
import Testing
@testable import agtermCore

struct ThemeCatalogTests {
    @Test func namesInDirectorySortCaseInsensitively() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["Nord", "alabaster", "Zenburn"] {
            try "".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        #expect(ThemeCatalog.names(in: dir.path) == ["alabaster", "Nord", "Zenburn"])
        #expect(ThemeCatalog.names(in: "/no/such/dir") == [])
    }

    @Test func entriesPutGhosttyDefaultBeforeNamedThemes() {
        let catalog = ThemeCatalog(names: ["Nord", "agterm", "Adwaita Dark"])

        #expect(catalog.names == ["Adwaita Dark", "agterm", "Nord"])
        #expect(catalog.entries == [
            ThemeCatalog.Entry(id: "theme:__default__", name: nil, title: "default ghostty"),
            ThemeCatalog.Entry(id: "theme:Adwaita Dark", name: "Adwaita Dark", title: "Adwaita Dark"),
            ThemeCatalog.Entry(id: "theme:agterm", name: "agterm", title: "agterm"),
            ThemeCatalog.Entry(id: "theme:Nord", name: "Nord", title: "Nord"),
        ])
        #expect(catalog.entries.first?.isDefault == true)
    }

    @Test func idsRepresentDefaultAndNamedThemes() {
        #expect(ThemeCatalog.id(for: nil) == "theme:__default__")
        #expect(ThemeCatalog.id(for: "agterm") == "theme:agterm")
    }

    @Test func resolvedNameTreatsNilAndBlankAsDefault() {
        #expect(ThemeCatalog.resolvedName(nil) == nil)
        #expect(ThemeCatalog.resolvedName("") == nil)
        #expect(ThemeCatalog.resolvedName("   ") == nil)
        #expect(ThemeCatalog.resolvedName("  Nord  ") == "Nord")
    }

    @Test func containsMatchesBundledNamesExactly() {
        let catalog = ThemeCatalog(names: ["agterm", "Nord"])

        #expect(catalog.contains(name: "agterm"))
        #expect(catalog.contains(name: "Nord"))
        #expect(!catalog.contains(name: "nord"))
    }
}
