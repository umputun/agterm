import Foundation
import Testing
@testable import agtermCore

struct DirectoryCopyTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("directory-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/sub"), withIntermediateDirectories: true)
        return root
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    @Test func copiesNestedFilesWithTheirModes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src")
        try "run".write(to: source.appendingPathComponent("sub/tool.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("sub/tool.sh").path)
        try "data".write(to: source.appendingPathComponent("plain.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.appendingPathComponent("plain.txt").path)
        let destination = root.appendingPathComponent("dst")

        try DirectoryCopy.copy(source, to: destination)

        #expect(try String(contentsOf: destination.appendingPathComponent("sub/tool.sh"), encoding: .utf8) == "run")
        #expect(try mode(destination.appendingPathComponent("sub/tool.sh")) == 0o755)
        #expect(try String(contentsOf: destination.appendingPathComponent("plain.txt"), encoding: .utf8) == "data")
        #expect(try mode(destination.appendingPathComponent("plain.txt")) == 0o600)
    }

    @Test func refusesASymlink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("src/link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")

        #expect(throws: DirectoryCopy.UnsupportedEntry(path: link.path)) {
            try DirectoryCopy.copy(root.appendingPathComponent("src"), to: root.appendingPathComponent("dst"))
        }
    }

    @Test func refusesAnExistingDestination() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: (any Error).self) {
            try DirectoryCopy.copy(root.appendingPathComponent("src"), to: root.appendingPathComponent("src/sub"))
        }
    }
}
