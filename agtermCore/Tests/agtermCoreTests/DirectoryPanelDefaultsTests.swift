import Foundation
import Testing
@testable import agtermCore

@Suite("Directory panel defaults")
struct DirectoryPanelDefaultsTests {
    @Test func firstExistingDirectoryWins() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        #expect(DirectoryPanelDefaults.url(paths: first.path, second.path) == first)
    }

    @Test func staleFirstCandidateFallsThrough() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)

        #expect(DirectoryPanelDefaults.url(paths: root.appendingPathComponent("gone/project").path,
                                                  fallback.path) == fallback)
    }

    @Test func filesAreNotAcceptedAsDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-directory")
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)
        try Data().write(to: file)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)

        #expect(DirectoryPanelDefaults.url(paths: file.path, fallback.path) == fallback)
    }

    @Test func emptyAndMissingCandidatesFallBackToHome() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        #expect(DirectoryPanelDefaults.url(paths: nil, "", missing)
                == FileManager.default.homeDirectoryForCurrentUser)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-directory-defaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
