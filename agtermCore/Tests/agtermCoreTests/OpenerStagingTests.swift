import Foundation
import Testing
@testable import agtermCore

struct OpenerStagingTests {
    @Test func aStagedCopyIsWrittenUnderItsNameInAPrivateFolder() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let staging = OpenerStaging(root: dir.root.appendingPathComponent("open"))

        let path = try staging.stage(name: "notes.md", data: Data("# hi".utf8), size: 4)

        #expect((path as NSString).lastPathComponent == "notes.md")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("# hi".utf8))
        #expect(try permissions((path as NSString).deletingLastPathComponent) == 0o700)
        #expect(try permissions(staging.root.path) == 0o700)
        #expect(try permissions(path) == 0o600)
    }

    @Test(arguments: ["", ".", "..", "a/b.md", "a\0.md"])
    func anUnsafeNameStagesNothing(name: String) throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let staging = OpenerStaging(root: dir.root.appendingPathComponent("open"))

        #expect(throws: OpenerStaging.Failure.unsafeName) { try staging.stage(name: name, data: Data("x".utf8), size: 1) }
        #expect(try stagedFolders(staging).isEmpty)
    }

    @Test func aSizeOverItsKindsCapOrNotAPreviewKindStagesNothing() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let staging = OpenerStaging(root: dir.root.appendingPathComponent("open"))

        #expect(throws: OpenerStaging.Failure.tooLarge) {
            try staging.stage(name: "notes.md", data: Data(), size: MarkdownPage.maxBytes + 1)
        }
        #expect(throws: OpenerStaging.Failure.tooLarge) { try staging.stage(name: "a.zip", data: Data("x".utf8), size: 1) }
        #expect(try stagedFolders(staging).isEmpty)
    }

    @Test func bytesThatDoNotMatchTheOfferedSizeLeaveNoCopy() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let staging = OpenerStaging(root: dir.root.appendingPathComponent("open"))

        #expect(throws: OpenerStaging.Failure.sizeMismatch) { try staging.stage(name: "notes.md", data: Data("abc".utf8), size: 4) }
        #expect(try stagedFolders(staging).isEmpty)
    }

    @Test func stagingAndASweepRemoveCopiesOlderThanAnHour() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let root = dir.root.appendingPathComponent("open")
        let old = try OpenerStaging(root: root).stage(name: "old.md", data: Data("o".utf8), size: 1)
        let keep = root.appendingPathComponent("not-a-copy")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: false)
        let later = Date().addingTimeInterval(OpenerStaging.retention + 60)

        let fresh = try OpenerStaging(root: root, now: { later }).stage(name: "new.md", data: Data("n".utf8), size: 1)
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: fresh))

        OpenerStaging(root: root, now: { later.addingTimeInterval(OpenerStaging.retention + 60) }).sweep()
        #expect(!FileManager.default.fileExists(atPath: fresh))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func sweepAndRemoveLeaveEverythingUnderARootThatIsNotPrivate() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let target = dir.root.appendingPathComponent("target")
        let old = target.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        let link = dir.root.appendingPathComponent("open")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let staging = OpenerStaging(root: link)

        staging.sweep()
        staging.remove(link.appendingPathComponent(old.lastPathComponent).appendingPathComponent("a.md").path)

        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func removeDeletesOnlyAStagedCopysFolder() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let staging = OpenerStaging(root: dir.root.appendingPathComponent("open"))
        let path = try staging.stage(name: "notes.md", data: Data("x".utf8), size: 1)
        let outside = dir.root.appendingPathComponent("outside.md")
        try Data("y".utf8).write(to: outside)

        staging.remove(outside.path)
        staging.remove(path)

        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try stagedFolders(staging).isEmpty)
    }

    private func stagedFolders(_ staging: OpenerStaging) throws -> [String] {
        guard FileManager.default.fileExists(atPath: staging.root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: staging.root.path)
    }

    private func permissions(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) & 0o777
    }
}
