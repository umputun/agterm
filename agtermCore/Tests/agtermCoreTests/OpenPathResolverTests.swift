import Foundation
import Testing
@testable import agtermCore

struct OpenPathResolverTests {
    @Test func directoryReturnsItself() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(OpenPathResolver.directory(for: dir) == dir.path)
    }

    @Test func fileReturnsParentDirectory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try Data().write(to: file)
        #expect(OpenPathResolver.directory(for: file) == dir.path)
    }

    @Test func nonexistentPathReturnsNil() throws {
        let dir = try makeTempDirectory()
        try FileManager.default.removeItem(at: dir)
        #expect(OpenPathResolver.directory(for: dir) == nil)
    }

    @Test func nonFileURLReturnsNil() throws {
        let url = try #require(URL(string: "https://example.com/tmp"))
        #expect(OpenPathResolver.directory(for: url) == nil)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
