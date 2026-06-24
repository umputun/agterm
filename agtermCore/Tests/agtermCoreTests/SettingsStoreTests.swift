import Foundation
import Testing
@testable import agtermCore

/// Class suite so `init`/`deinit` create and tear down a unique temp directory per test — no
/// shared on-disk state, no Application Support pollution.
@MainActor
final class SettingsStoreTests {
    private let directory: URL
    private let store: SettingsStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-settings-\(UUID().uuidString)")
        store = SettingsStore(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("settings.json") }

    @Test func saveLoadRoundTrip() throws {
        let settings = AppSettings(fontFamily: "Menlo", fontSize: 15, theme: "Adwaita Dark")
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func missingFileSeedsDefaultTheme() {
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        // a fresh install opens on the app's default theme, not ghostty's built-in.
        #expect(store.load() == AppSettings(theme: AppSettings.defaultTheme))
        #expect(store.load().theme == "agterm")
    }

    @Test func corruptFileSeedsDefaultTheme() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not valid json ]".utf8).write(to: fileURL)
        #expect(store.load() == AppSettings(theme: AppSettings.defaultTheme))
    }

    @Test func existingFileWithoutThemeKeyStaysGhosttyDefault() throws {
        // an existing settings.json with no `theme` key decodes to nil (ghostty built-in) — an
        // existing user is never silently re-themed to the new app default.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"fontSize":14}"#.utf8).write(to: fileURL)
        #expect(store.load().theme == nil)
    }

    @Test func saveCreatesDirectoryWhenMissing() throws {
        let nested = directory.appendingPathComponent("does/not/exist/yet")
        let nestedStore = SettingsStore(directory: nested)
        let settings = AppSettings(theme: "Alabaster")
        try nestedStore.save(settings)
        #expect(nestedStore.load() == settings)
    }
}
