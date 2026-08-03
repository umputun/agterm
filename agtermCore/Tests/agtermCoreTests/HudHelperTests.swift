import Foundation
import Testing
@testable import agtermCore

// Tests the shipped panel painter `agterm/Resources/hud/hud.sh` by running it against a temp body file and
// reading the escape stream it writes. It reaches the app target's resource on purpose: the script is the
// rendering half of the agtermCore `HudLayout` model, and the three contracts (the header line, the
// rendered body's empty-line separator, the file as the ONLY changing input) only hold if both halves are
// pinned together.
struct HudHelperTests {
    private static var helper: String {
        URL(fileURLWithPath: #filePath)      // …/agtermCore/Tests/agtermCoreTests/HudHelperTests.swift
            .deletingLastPathComponent()     // agtermCoreTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // agtermCore
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("agterm/Resources/hud/hud.sh")
            .path
    }

    private static let esc = "\u{1b}"

    // a helper process painting into a temp file, so the frames can be read at any point without racing
    // a pipe's EOF.
    private final class Run {
        let bodyFile: URL
        private let dir: URL
        private let outFile: URL
        private let proc = Process()

        init(_ body: String, cols: Int, rows: Int, spinner: Bool = false,
             ownerPid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
            let fm = FileManager.default
            dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-hud-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            bodyFile = dir.appendingPathComponent("body")
            outFile = dir.appendingPathComponent("out")
            try Run.write(body, header: Run.header(cols: cols, rows: rows, spinner: spinner, owner: ownerPid),
                          to: bodyFile)
            fm.createFile(atPath: outFile.path, contents: nil)

            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [HudHelperTests.helper]
            proc.environment = [HudLayout.fileEnvKey: bodyFile.path]
            proc.standardOutput = try FileHandle(forWritingTo: outFile)
            proc.standardError = FileHandle.nullDevice
            try proc.run()
        }

        private static func header(cols: Int, rows: Int, spinner: Bool, owner: Int32) -> String {
            "\(cols) \(rows) \(spinner ? 1 : 0) \(owner)\n"
        }

        private static func write(_ body: String, header: String, to file: URL) throws {
            try (header + body).write(to: file, atomically: true, encoding: .utf8)
        }

        var painted: String { (try? String(contentsOf: outFile, encoding: .utf8)) ?? "" }
        var running: Bool { proc.isRunning }

        func rewrite(_ body: String, cols: Int = 40, rows: Int = 7, spinner: Bool = false,
                     ownerPid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
            try Run.write(body, header: Run.header(cols: cols, rows: rows, spinner: spinner, owner: ownerPid),
                          to: bodyFile)
        }
        func removeBody() throws { try FileManager.default.removeItem(at: bodyFile) }

        @discardableResult
        func wait(_ timeout: TimeInterval = 5, until check: (String) -> Bool) -> String {
            let deadline = Date().addingTimeInterval(timeout)
            var text = painted
            while !check(text), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
                text = painted
            }
            return text
        }

        func waitForExit(_ timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            return !proc.isRunning
        }

        func stop() {
            if proc.isRunning { proc.terminate() }
            proc.waitUntilExit()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func paintsTheMessage() throws {
        let run = try Run("gathering options\n", cols: 40, rows: 7)
        defer { run.stop() }
        #expect(run.wait { $0.contains("gathering options") }.contains("gathering options"))
    }

    @Test func placesTheMessageInTheBoxTheHeaderGave() throws {
        // cols 41 / "abc" leaves 19 columns to the left, rows 9 / 1 line leaves 4 rows above
        let run = try Run("abc\n", cols: 41, rows: 9)
        defer { run.stop() }
        let e = Self.esc
        let frame = "\(e)[H\(e)[J\(e)[E\(e)[E\(e)[E\(e)[E\(e)[19Cabc"
        #expect(run.wait { $0.contains(frame) }.contains(frame))
    }

    @Test func keepsAnOversizedLineAtTheLeftEdgeRatherThanOffScreen() throws {
        let run = try Run("a message wider than its box\n", cols: 10, rows: 3)
        defer { run.stop() }
        let e = Self.esc
        let frame = "\(e)[H\(e)[J\(e)[Ea message wider than its box"
        #expect(run.wait { $0.contains(frame) }.contains(frame))
    }

    @Test func dimsEverythingAfterTheBodysEmptyLine() throws {
        let run = try Run("working\n\nthis may take a while\n", cols: 40, rows: 9)
        defer { run.stop() }
        let painted = run.wait { $0.contains("this may take a while") }
        #expect(painted.contains("\(Self.esc)[2mthis may take a while"))
        #expect(!painted.contains("\(Self.esc)[2mworking"))
    }

    @Test func picksUpARewrittenBodyWithoutRespawning() throws {
        let run = try Run("first\n", cols: 40, rows: 7, spinner: true)
        defer { run.stop() }
        run.wait { $0.contains("first") }
        try run.rewrite("second\n", spinner: true)
        #expect(run.wait { $0.contains("second") }.contains("second"))
        #expect(run.running)
    }

    @Test func rewritingResizesTheContentInsideTheSameBox() throws {
        let run = try Run("abc\n", cols: 41, rows: 9, spinner: true)
        defer { run.stop() }
        run.wait { $0.contains("abc") }
        try run.rewrite("abcdefg\n", cols: 41, rows: 9, spinner: true)
        // 41 - 7 content - 2 spinner leaves 16 to the left, versus 18 for the shorter message
        #expect(run.wait { $0.contains("\(Self.esc)[16C") }.contains("\(Self.esc)[16C"))
    }

    // the header is what makes `session.hud.update` able to grow the panel: a running helper cannot see its
    // environment change, so a box carried there would leave the text centred in the box it spawned with.
    @Test func rewritingWithANewBoxRecentersWithoutRespawning() throws {
        let run = try Run("abc\n", cols: 41, rows: 9)
        defer { run.stop() }
        let e = Self.esc
        run.wait { $0.contains("\(e)[19Cabc") }
        try run.rewrite("abc\n", cols: 21, rows: 5)
        // 21 - 3 leaves 9 to the left, and 5 rows - 1 line leaves 2 rows above
        let frame = "\(e)[H\(e)[J\(e)[E\(e)[E\(e)[9Cabc"
        #expect(run.wait { $0.contains(frame) }.contains(frame))
        #expect(run.running)
    }

    @Test func rewritingTurnsTheSpinnerOnWithoutRespawning() throws {
        let run = try Run("busy\n", cols: 40, rows: 7)
        defer { run.stop() }
        run.wait { $0.contains("busy") }
        #expect(!run.painted.contains("| busy"))
        try run.rewrite("busy\n", spinner: true)
        #expect(run.wait { $0.contains("| busy") }.contains("| busy"))
        #expect(run.running)
    }

    // line one is always the header; a body whose header is not numbers paints in the built-in box instead
    // of arithmetic on garbage.
    @Test func aMalformedHeaderFallsBackToTheDefaultBox() throws {
        let run = try Run("", cols: 21, rows: 5)
        defer { run.stop() }
        try "not a header\nvisible\n".write(to: run.bodyFile, atomically: true, encoding: .utf8)
        // the default 40-column box leaves 16 to the left of a 7-character line, where 21 would leave 7
        #expect(run.wait { $0.contains("\(Self.esc)[16Cvisible") }.contains("\(Self.esc)[16Cvisible"))
    }

    @Test func spinnerPrefixesTheFirstLineAndAdvances() throws {
        let run = try Run("busy\n", cols: 40, rows: 7, spinner: true)
        defer { run.stop() }
        let painted = run.wait { $0.contains("| busy") && $0.contains("/ busy") && $0.contains("- busy") }
        #expect(painted.contains("| busy"))
        #expect(painted.contains("/ busy"))
        #expect(painted.contains("- busy"))
    }

    @Test func noSpinnerGlyphWithoutTheFlag() throws {
        let run = try Run("busy\n", cols: 40, rows: 7)
        defer { run.stop() }
        let painted = run.wait { $0.contains("busy") }
        #expect(!painted.contains("| busy"))
        #expect(!painted.contains("/ busy"))
    }

    @Test func exitsWhenTheBodyFileDisappears() throws {
        let run = try Run("bye\n", cols: 40, rows: 7, spinner: true)
        defer { run.stop() }
        run.wait { $0.contains("bye") }
        try run.removeBody()
        #expect(run.waitForExit())
    }

    // pins the fix for the orphan a HARD-killed app used to leave: no teardown deletes the body file and no
    // SIGHUP reaches the pty (its session leader is `login`), so the pid in the header is the only stop.
    @Test func exitsWhenTheOwningProcessIsGone() throws {
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sh")
        owner.arguments = ["-c", "while :; do sleep 0.2; done"]
        try owner.run()

        let run = try Run("bye\n", cols: 40, rows: 7, spinner: true, ownerPid: owner.processIdentifier)
        defer { run.stop() }
        run.wait { $0.contains("bye") }
        #expect(run.running)

        owner.terminate()
        owner.waitUntilExit()   // reaps it: kill -0 succeeds on a zombie, which still has a process entry

        #expect(run.waitForExit())
    }

    @Test func keepsPaintingWhenTheHeaderNamesNoOwner() throws {
        let run = try Run("", cols: 21, rows: 5)
        defer { run.stop() }
        try "40 7 0\nstill here\n".write(to: run.bodyFile, atomically: true, encoding: .utf8)

        #expect(run.wait { $0.contains("still here") }.contains("still here"))
        #expect(run.running)
    }

    @Test func hidesTheCursorAndRestoresItOnExit() throws {
        let run = try Run("bye\n", cols: 40, rows: 7, spinner: true)
        defer { run.stop() }
        run.wait { $0.contains("bye") }
        #expect(run.painted.hasPrefix("\(Self.esc)[?25l"))
        try run.removeBody()
        #expect(run.waitForExit())
        #expect(run.painted.contains("\(Self.esc)[?25h"))
    }

    @Test func exitsQuietlyWithoutABodyPath() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [Self.helper]
        proc.environment = [:]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
