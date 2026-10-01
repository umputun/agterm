import Foundation
import Testing
@testable import agtermCore

struct BrowserProfileTests {
    private static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-browser-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aMissingFileCreatesAnIdentifierThatLaterReadsReturn() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = BrowserProfile(directory: dir)
        #expect(!profile.exists)

        let first = try profile.identifier()

        #expect(profile.exists)
        #expect(try profile.identifier() == first)
        #expect(try BrowserProfile(directory: dir).identifier() == first)
    }

    @Test func twoDirectoriesGetDifferentIdentifiers() throws {
        let one = try Self.directory()
        let two = try Self.directory()
        defer {
            try? FileManager.default.removeItem(at: one)
            try? FileManager.default.removeItem(at: two)
        }

        #expect(try BrowserProfile(directory: one).identifier() != BrowserProfile(directory: two).identifier())
    }

    @Test func aMissingDirectoryIsCreated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-browser-profile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try BrowserProfile(directory: dir).identifier()

        #expect(BrowserProfile(directory: dir).exists)
    }

    @Test(arguments: ["", "not-a-uuid", "123"])
    func aMalformedFileIsAnErrorAndStaysAsItWas(_ content: String) throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(BrowserProfile.filename)
        try Data(content.utf8).write(to: file)

        #expect(throws: BrowserProfile.Failure.malformed(file.path)) { try BrowserProfile(directory: dir).identifier() }
        #expect(try Data(contentsOf: file) == Data(content.utf8))
    }

    @Test func anUnreadableFileIsAnErrorAndStaysAsItWas() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(BrowserProfile.filename)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        #expect(throws: BrowserProfile.Failure.unreadable(file.path)) { try BrowserProfile(directory: dir).identifier() }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func aTrailingNewlineIsAccepted() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try Data("\(id.uuidString)\n".utf8).write(to: dir.appendingPathComponent(BrowserProfile.filename))

        #expect(try BrowserProfile(directory: dir).identifier() == id)
    }
}
