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
        var expected = settings
        expected.migrateRestoreMode()
        #expect(store.load() == expected)
    }

    @Test func missingFileSeedsDefaultTheme() {
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(store.load() == AppSettings(theme: AppSettings.defaultTheme))
        #expect(store.load().theme == "agterm")
    }

    @Test func corruptFileSeedsDefaultTheme() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not valid json ]".utf8).write(to: fileURL)
        #expect(store.load() == AppSettings(theme: AppSettings.defaultTheme))
    }

    @Test func existingFileWithoutThemeKeyStaysGhosttyDefault() throws {
        // an existing user is never silently re-themed: a missing `theme` key decodes to nil, ghostty's
        // built-in, not the app default.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"fontSize":14}"#.utf8).write(to: fileURL)
        #expect(store.load().theme == nil)
    }

    @Test func saveCreatesDirectoryWhenMissing() throws {
        let nested = directory.appendingPathComponent("does/not/exist/yet")
        let nestedStore = SettingsStore(directory: nested)
        let settings = AppSettings(theme: "Alabaster")
        try nestedStore.save(settings)
        var expected = settings
        expected.migrateRestoreMode()
        #expect(nestedStore.load() == expected)
    }

    @Test(arguments: [
        (#"{"restoreRunningCommand":true}"#, RestoreMode.rerun),
        (#"{"restoreRunningCommand":false}"#, RestoreMode.none),
        (#"{}"#, RestoreMode.none),
        (#"{"restoreMode":"future"}"#, RestoreMode.none),
    ])
    func loadMigratesRestoreMode(json: String, expected: RestoreMode) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)
        let settings = store.load()
        #expect(settings.restoreMode == expected)
        #expect(settings.restoreRunningCommand == nil)
    }

    @Test func saveWritesOnlyRestoreMode() throws {
        try store.save(AppSettings(restoreRunningCommand: true))
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(json.contains(#""restoreMode" : "rerun""#))
        #expect(!json.contains("restoreRunningCommand"))
    }
}
