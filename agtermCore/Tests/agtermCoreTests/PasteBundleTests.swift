import Foundation
import Testing
@testable import agtermCore

struct PasteBundleTests {
    @Test func aWrittenBundleReadsBackTheSameHeadersAndBytes() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let file = try dir.file("a.txt", "hello")
        let folder = try dir.folder("pics", files: ["x.png": "png", "sub/y.txt": "why"])

        let entries = try PasteBundle.entries(files: [file, folder])
        let bundle = try dir.bundle(entries)
        var reader = PasteBundle.Reader(handle: try FileHandle(forReadingFrom: bundle))
        var headers: [PasteBundle.Header] = []
        var bodies: [String: String] = [:]
        while let header = try reader.next() {
            headers.append(header)
            guard header.kind == .file else { continue }
            let out = dir.root.appendingPathComponent("out-\(headers.count)")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            try reader.copyBody(to: handle.fileDescriptor)
            try handle.close()
            bodies[header.path] = try String(contentsOf: out, encoding: .utf8)
        }

        #expect(headers == entries.map(\.header))
        #expect(Set(headers.map(\.path)) == ["a.txt", "pics", "pics/x.png", "pics/sub", "pics/sub/y.txt"])
        #expect(headers.filter { $0.root == 1 }.allSatisfy { $0.path.hasPrefix("pics") })
        #expect(bodies == ["a.txt": "hello", "pics/x.png": "png", "pics/sub/y.txt": "why"])
    }

    @Test func aFoldersSymlinksAreSkippedAndAnOfferedSymlinkIsRefused() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let target = try dir.file("target.txt", "t")
        let folder = try dir.folder("f", files: ["real.txt": "r"])
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: target)
        let link = dir.root.appendingPathComponent("top-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let elsewhere = try dir.folder("elsewhere", files: ["secret.txt": "s"])
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("dirlink"), withDestinationURL: elsewhere)

        #expect(try PasteBundle.entries(files: [folder]).map(\.header.path) == ["f", "f/real.txt"])
        #expect(throws: PasteBundle.Failure.unsupported("top-link")) { try PasteBundle.entries(files: [link]) }
    }

    // regression: an unreadable subfolder was skipped, so the paste reported a folder with that part missing
    @Test(.enabled(if: geteuid() != 0, "root reads a mode-000 folder"))
    func anUnreadableSubfolderFailsTheWalk() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let folder = try dir.folder("f", files: ["ok.txt": "o", "locked/hidden.txt": "h"])
        let locked = folder.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        #expect(throws: PasteBundle.Failure.unreadable("locked")) { try PasteBundle.entries(files: [folder]) }
    }

    @Test func theWalkStopsAtTheFirstExceededLimit() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let folder = try dir.folder("many", files: ["1": "a", "2": "b", "3": "c", "4": "d"])
        let big = try dir.file("big", String(repeating: "x", count: 11))

        #expect(throws: PasteBundle.Failure.tooManyEntries(3)) {
            try PasteBundle.entries(files: [folder], limits: .init(totalBytes: 100, entries: 3))
        }
        #expect(throws: PasteBundle.Failure.tooLarge(10)) {
            try PasteBundle.entries(files: [big], limits: .init(totalBytes: 10, entries: 10))
        }
        #expect(throws: PasteBundle.Failure.tooLarge(3)) { try PasteBundle.entries(image: Data(count: 4), name: "i.png",
                                                                                     limits: .init(totalBytes: 3, entries: 1)) }
    }

    @Test(arguments: [
        ("agterm-paste 2\n", PasteBundle.Failure.unsupportedVersion),
        ("agterm-paste 1\n", .empty),
        ("agterm-paste 1\n{\"root\":0,\"path\":\"../x\",\"kind\":\"file\",\"size\":0}\n", .badPath("../x")),
        ("agterm-paste 1\n{\"root\":0,\"path\":\"/etc\",\"kind\":\"dir\",\"size\":0}\n", .badPath("/etc")),
        ("agterm-paste 1\n{\"root\":0,\"path\":\"a\",\"kind\":\"dir\",\"size\":0}\n{\"root\":0,\"path\":\"b/c\",\"kind\":\"file\",\"size\":0}\n",
         .badPath("b/c")),
        ("agterm-paste 1\n{\"root\":0,\"path\":\"a\",\"kind\":\"file\",\"size\":0}\n{\"root\":0,\"path\":\"a/c\",\"kind\":\"file\",\"size\":0}\n",
         .badPath("a/c")),
        ("agterm-paste 1\n{\"root\":0,\"path\":\"a\",\"kind\":\"dir\",\"size\":0}\n{\"root\":0,\"path\":\"a/c\",\"kind\":\"dir\",\"size\":0}\n"
            + "{\"root\":0,\"path\":\"a/c\",\"kind\":\"dir\",\"size\":0}\n", .duplicate("a/c")),
        ("agterm-paste 1\n{\"root\":1,\"path\":\"a\",\"kind\":\"file\",\"size\":0}\n", .malformedHeader),
        ("agterm-paste 1\nnot json\n", .malformedHeader),
        ("agterm-paste 1\n{\"root\":0,\"path\":\"a\",\"kind\":\"file\",\"size\":5}\nabc", .truncated),
        ("agterm-paste 1\n{\"root\":0,\"path\":\"a\",\"kind\":\"file\",\"size\":0}", .truncated),
        ("agterm-paste 1\n{\"root\":0,\"path\":\"a\",\"kind\":\"file\",\"size\":11}\n", .tooLarge(10)),
    ])
    func theReaderRefusesWhatItCannotPlaceSafely(raw: String, failure: PasteBundle.Failure) throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        #expect(throws: failure) { try dir.drain(Data(raw.utf8), limits: .init(totalBytes: 10, entries: 10)) }
    }

    @Test func theTemporaryBundleIsPrivateAndReadsBack() throws {
        let file = try PasteBundle.temporaryFile(PasteBundle.entries(image: Data([7, 8]), name: "c.png"))
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        var reader = PasteBundle.Reader(handle: try FileHandle(forReadingFrom: file))
        #expect(try reader.next() == PasteBundle.Header(root: 0, path: "c.png", kind: .file, size: 2))
    }

    @Test func aHeaderLineOverTheCapIsRefusedBeforeItIsParsed() throws {
        let dir = try PasteFixture()
        defer { dir.cleanUp() }
        let raw = Data("agterm-paste 1\n".utf8) + Data(repeating: 0x61, count: PasteBundle.maxHeaderBytes + 1) + Data("\n".utf8)
        #expect(throws: PasteBundle.Failure.headerTooLong) { try dir.drain(raw) }
    }
}

struct PasteFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func folder(_ name: String, files: [String: String]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (path, text) in files { _ = try file(name + "/" + path, text) }
        return url
    }

    func bundle(_ entries: [PasteBundle.Entry]) throws -> URL {
        let url = root.appendingPathComponent("bundle-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try PasteBundle.write(entries, to: handle)
        return url
    }

    func raw(_ data: Data) throws -> FileHandle {
        let url = root.appendingPathComponent("raw-\(UUID().uuidString)")
        try data.write(to: url)
        return try FileHandle(forReadingFrom: url)
    }

    func drain(_ data: Data, limits: PasteBundle.Limits = .standard) throws {
        var reader = PasteBundle.Reader(handle: try raw(data), limits: limits)
        let sink = open("/dev/null", O_WRONLY)
        defer { close(sink) }
        while let header = try reader.next() {
            if header.kind == .file { try reader.copyBody(to: sink) }
        }
    }
}
