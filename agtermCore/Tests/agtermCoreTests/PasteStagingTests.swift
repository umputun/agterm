import Foundation
import Testing
@testable import agtermCore

struct PasteStagingTests {
    @Test func aReceivedBundlePlacesEachItemInItsOwnSubfolderInOfferOrder() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let first = try dir.file("one/report.png", "first")
        let second = try dir.file("two/report.png", "second")
        let folder = try dir.folder("pics", files: ["sub/y.txt": "why"])
        let staging = PasteStaging(root: dir.root.appendingPathComponent("stage/paste"))

        let bundle = try dir.bundle(PasteBundle.entries(files: [first, second, folder]))
        let paths = try staging.receive(from: FileHandle(forReadingFrom: bundle))

        try #require(paths.count == 3)
        #expect(paths.map { ($0 as NSString).lastPathComponent } == ["report.png", "report.png", "pics"])
        #expect(Set(paths).count == 3)
        #expect(try String(contentsOfFile: paths[0], encoding: .utf8) == "first")
        #expect(try String(contentsOfFile: paths[1], encoding: .utf8) == "second")
        #expect(try String(contentsOfFile: paths[2] + "/sub/y.txt", encoding: .utf8) == "why")
        #expect(paths.allSatisfy { $0.hasPrefix(staging.root.path + "/") })
        #expect(try permissions(staging.root.path) == 0o700)
        #expect(try permissions(paths[0]) == 0o600)
    }

    @Test func aStagedImageIsWrittenUnderItsName() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let staging = PasteStaging(root: dir.root.appendingPathComponent("paste"))
        let path = try staging.stage(image: Data([1, 2, 3]), name: "clipboard-1.png")
        #expect((path as NSString).lastPathComponent == "clipboard-1.png")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([1, 2, 3]))
    }

    @Test func aRootThatIsASymlinkOrNotPrivateIsRefused() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let real = dir.root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: PasteStaging.Failure.unsafeRoot(link.path)) {
            try PasteStaging(root: link).stage(image: Data([1]), name: "a.png")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        #expect(throws: PasteStaging.Failure.unsafeRoot(real.path)) {
            try PasteStaging(root: real).stage(image: Data([1]), name: "a.png")
        }
    }

    @Test func aFailedReceiveLeavesNoPartialFolder() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let staging = PasteStaging(root: dir.root.appendingPathComponent("paste"))
        let raw = "agterm-paste 1\n{\"root\":0,\"path\":\"a\",\"kind\":\"dir\",\"size\":0}\n"
            + "{\"root\":0,\"path\":\"a/b\",\"kind\":\"file\",\"size\":9}\nabc"

        #expect(throws: PasteBundle.Failure.truncated) { try staging.receive(from: dir.raw(Data(raw.utf8))) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.root.path).isEmpty)
    }

    @Test func anEntryIsNeverCreatedOverAnExistingName() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let folder = dir.root.path + "/batch"
        try PasteStaging.makeDirectory(folder)
        var batch = PasteStaging.Batch(folder: folder)
        let header = PasteBundle.Header(root: 0, path: "x.txt", kind: .file, size: 0)
        try batch.create(header) { _ in }

        #expect(throws: PasteStaging.Failure.exists("x.txt")) {
            try batch.create(PasteBundle.Header(root: 0, path: "x.txt", kind: .file, size: 0)) { _ in }
        }
        #expect(throws: PasteStaging.Failure.exists("0")) { try PasteStaging.makeDirectory(folder + "/0") }
    }

    @Test func stagingRemovesPastesOlderThanTheRetention() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let root = dir.root.appendingPathComponent("paste")
        let old = try PasteStaging(root: root).stage(image: Data([1]), name: "old.png")
        let keep = root.appendingPathComponent("not-a-paste")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: false)

        let later = Date().addingTimeInterval(PasteStaging.retention + 60)
        let fresh = try PasteStaging(root: root, now: { later }).stage(image: Data([2]), name: "new.png")

        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: fresh))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    private func permissions(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) & 0o777
    }
}
