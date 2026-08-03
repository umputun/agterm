import Foundation
import Testing

// Tests the shipped panel painter `agterm/Resources/hud/hud.sh` by running it against a temp body file and
// reading the escape stream it writes. It reaches the app target's resource on purpose: the script is the
// rendering half of the agtermCore `HudLayout` model, and the two contracts (the rendered body's empty-line
// separator, the app-supplied box) only hold if both halves are pinned together.
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

        init(_ body: String, cols: Int, rows: Int, spinner: Bool = false) throws {
            let fm = FileManager.default
            dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-hud-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            bodyFile = dir.appendingPathComponent("body")
            outFile = dir.appendingPathComponent("out")
            try body.write(to: bodyFile, atomically: true, encoding: .utf8)
            fm.createFile(atPath: outFile.path, contents: nil)

            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [HudHelperTests.helper]
            proc.environment = ["AGTERM_HUD_FILE": bodyFile.path, "AGTERM_HUD_COLS": String(cols),
                                "AGTERM_HUD_ROWS": String(rows), "AGTERM_HUD_SPINNER": spinner ? "1" : "0"]
            proc.standardOutput = try FileHandle(forWritingTo: outFile)
            proc.standardError = FileHandle.nullDevice
            try proc.run()
        }

        var painted: String { (try? String(contentsOf: outFile, encoding: .utf8)) ?? "" }
        var running: Bool { proc.isRunning }

        func rewrite(_ body: String) throws { try body.write(to: bodyFile, atomically: true, encoding: .utf8) }
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

    @Test func placesTheMessageInTheBoxTheEnvironmentGave() throws {
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
        try run.rewrite("second\n")
        #expect(run.wait { $0.contains("second") }.contains("second"))
        #expect(run.running)
    }

    @Test func rewritingResizesTheContentInsideTheSameBox() throws {
        let run = try Run("abc\n", cols: 41, rows: 9, spinner: true)
        defer { run.stop() }
        run.wait { $0.contains("abc") }
        try run.rewrite("abcdefg\n")
        // 41 - 7 content - 2 spinner leaves 16 to the left, versus 18 for the shorter message
        #expect(run.wait { $0.contains("\(Self.esc)[16C") }.contains("\(Self.esc)[16C"))
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
