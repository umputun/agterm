import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct PasteCommandsTests {
    @Test func sessionPasteStdinSendsTheTextCommand() throws {
        let command = try Session.Paste.parse(["--stdin", "--pane", "right", "--pane-id", "P", "--target", "9f3c"])
        let expected = ControlRequest(cmd: .sessionPasteText, target: "9f3c", args: ControlArgs(text: "a\nb\n", pane: "right", paneID: "P"))
        #expect(try command.makeRequest(input: Data("a\nb\n".utf8)) == expected)
    }

    @Test(arguments: [(Data(), "stdin is empty: nothing to paste"), (Data([0xFF]), "stdin must be valid UTF-8")])
    func sessionPasteStdinRefusesUnusableInput(input: Data, error: String) throws {
        let command = try Session.Paste.parse(["--stdin"])
        let thrown = #expect(throws: (any Error).self) { try command.makeRequest(input: input) }
        #expect(thrown.map(Agtermctl.message(for:)) == error)
    }

    @Test func sessionPastePaneIDRequiresStdin() {
        #expect(throws: (any Error).self) { try Session.Paste.parse(["--pane-id", "P"]) }
    }

    @Test func receiveStagesTheBundleAndRepliesWithItsPaths() throws {
        let dir = try PasteTestFolder()
        defer { dir.cleanUp() }
        let bundle = try PasteBundle.temporaryFile(PasteBundle.entries(image: Data([1, 2]), name: "c.png"))
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let reply = Paste.Receive.receive(from: try FileHandle(forReadingFrom: bundle),
                                          staging: PasteStaging(root: dir.url.appendingPathComponent("paste")))

        let path = try #require(reply.paths?.first)
        #expect(reply.error == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([1, 2]))
    }

    @Test(arguments: [
        ("garbage\n", "unsupported paste format"),
        ("agterm-paste 1\n{\"root\":0,\"path\":\"a\",\"kind\":\"file\",\"size\":209715200}\n", "too large to paste (limit 100 MB)"),
    ])
    func receiveRepliesWithTheReasonForABadBundle(raw: String, reason: String) throws {
        let dir = try PasteTestFolder()
        defer { dir.cleanUp() }
        let input = dir.url.appendingPathComponent("in")
        try Data(raw.utf8).write(to: input)

        let reply = Paste.Receive.receive(from: try FileHandle(forReadingFrom: input),
                                          staging: PasteStaging(root: dir.url.appendingPathComponent("paste")))

        #expect(reply == PasteStaging.Reply(error: reason))
    }

    #if os(Linux)
    @Test func theInstalledCommandStagesUnderTheXDGCacheFolderAndPrintsTheReply() throws {
        let dir = try PasteTestFolder()
        defer { dir.cleanUp() }
        let bundle = try PasteBundle.temporaryFile(PasteBundle.entries(image: Data([9]), name: "shot.png"))
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/agtermctl")
        process.arguments = ["paste", "receive"]
        process.environment = ["HOME": dir.url.path, "XDG_CACHE_HOME": dir.url.appendingPathComponent("cache").path]
        process.standardInput = try FileHandle(forReadingFrom: bundle)
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let clock = ContinuousClock(), started = clock.now
        while process.isRunning, clock.now - started < .seconds(30) { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            Issue.record("agtermctl paste receive did not exit within 30 s")
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()

        let reply = try JSONDecoder().decode(PasteStaging.Reply.self, from: data)
        let path = try #require(reply.paths?.first)
        #expect(process.terminationStatus == 0)
        #expect(path.hasPrefix(dir.url.path + "/cache/agterm/paste/"))
        #expect(path.hasSuffix("/0/shot.png"))
    }
    #endif
}

struct PasteTestFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}
