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

    /// The helper's own `interval` without a spinner, which is what a "did it stay quiet" assertion has to
    /// outlast; a repaint loop would write within one of these.
    private static let spinnerlessTick: TimeInterval = 0.5

    // a helper process painting into a temp file, so the frames can be read at any point without racing
    // a pipe's EOF.
    private final class Run {
        let bodyFile: URL
        private let dir: URL
        private let outFile: URL
        private let proc = Process()

        init(_ body: String, cols: Int, rows: Int, spinner: HudSpinner? = nil, textColor: String? = nil,
             ownerPid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
            let fm = FileManager.default
            dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-hud-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            bodyFile = dir.appendingPathComponent("body")
            outFile = dir.appendingPathComponent("out")
            try Run.write(body, header: Run.header(cols: cols, rows: rows, spinner: spinner,
                                                   textColor: textColor, owner: ownerPid),
                          to: bodyFile)
            fm.createFile(atPath: outFile.path, contents: nil)

            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [HudHelperTests.helper]
            // no LANG/LC_*, which is what a Dock-launched app inherits from launchd: the script's own
            // LC_CTYPE is the only thing making `${#line}` count characters.
            proc.environment = [HudLayout.fileEnvKey: bodyFile.path]
            proc.standardOutput = try FileHandle(forWritingTo: outFile)
            proc.standardError = FileHandle.nullDevice
            try proc.run()
        }

        /// Builds the header by hand rather than through `HudLayout.renderedBody`, so a test can hand the
        /// script a grid no message would produce; the FORMAT still has to match, which is the contract these
        /// tests exist to pin.
        private static func header(cols: Int, rows: Int, spinner: HudSpinner?, textColor: String?,
                                   owner: Int32) -> String {
            let interval = spinner?.interval ?? HudSpinner.staticInterval
            let frames = (spinner?.frames ?? []).map { " " + $0 }.joined()
            let color = textColor ?? HudLayout.noTextColor
            return "\(cols) \(rows) \(spinner != nil ? 1 : 0) \(owner) \(interval) \(color)\(frames)\n"
        }

        private static func write(_ body: String, header: String, to file: URL) throws {
            try (header + body).write(to: file, atomically: true, encoding: .utf8)
        }

        var painted: String { (try? String(contentsOf: outFile, encoding: .utf8)) ?? "" }
        var running: Bool { proc.isRunning }

        func rewrite(_ body: String, cols: Int = 40, rows: Int = 7, spinner: HudSpinner? = nil,
                     textColor: String? = nil,
                     ownerPid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
            try Run.write(body, header: Run.header(cols: cols, rows: rows, spinner: spinner,
                                                   textColor: textColor, owner: ownerPid),
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

        /// Whether every needle reaches the painted stream before the timeout — the whole assertion for most
        /// of these tests, since the helper writes frames and never rewrites history.
        func paints(_ needles: String...) -> Bool { paints(needles) }

        func paints(_ needles: [String]) -> Bool {
            let text = wait { painted in needles.allSatisfy(painted.contains) }
            return needles.allSatisfy(text.contains)
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

    // the script is reached through the repository layout, not a bundle, so a move breaks it at run time
    @Test func theShippedHelperIsWhereTheseTestsLookForIt() throws {
        #expect(FileManager.default.isReadableFile(atPath: Self.helper),
                "no helper at \(Self.helper): agterm/Resources/hud/hud.sh moved, or this file did")
    }

    @Test func paintsTheMessage() throws {
        let run = try Run("gathering options\n", cols: 40, rows: 7)
        defer { run.stop() }
        #expect(run.paints("gathering options"))
    }

    @Test func placesTheMessageInTheBoxTheHeaderGave() throws {
        // cols 41 / "abc" leaves 19 columns to the left, rows 9 / 1 line leaves 4 rows above
        let run = try Run("abc\n", cols: 41, rows: 9)
        defer { run.stop() }
        let e = Self.esc
        let frame = "\(e)[H\(e)[J\(e)[E\(e)[E\(e)[E\(e)[E\(e)[19Cabc"
        #expect(run.paints(frame))
    }

    @Test func keepsAnOversizedLineAtTheLeftEdgeRatherThanOffScreen() throws {
        let run = try Run("a message wider than its box\n", cols: 10, rows: 3)
        defer { run.stop() }
        let e = Self.esc
        let frame = "\(e)[H\(e)[J\(e)[Ea message wider than its box"
        #expect(run.paints(frame))
    }

    @Test func dimsEverythingAfterTheBodysEmptyLine() throws {
        let run = try Run("working\n\nthis may take a while\n", cols: 40, rows: 9)
        defer { run.stop() }
        let painted = run.wait { $0.contains("this may take a while") }
        #expect(painted.contains("\(Self.esc)[2mthis may take a while"))
        #expect(!painted.contains("\(Self.esc)[2mworking"))
    }

    @Test func picksUpARewrittenBodyWithoutRespawning() throws {
        let run = try Run("first\n", cols: 40, rows: 7, spinner: .bar)
        defer { run.stop() }
        run.wait { $0.contains("first") }
        try run.rewrite("second\n", spinner: .bar)
        #expect(run.paints("second"))
        #expect(run.running)
    }

    @Test func rewritingResizesTheContentInsideTheSameBox() throws {
        let run = try Run("abc\n", cols: 41, rows: 9, spinner: .bar)
        defer { run.stop() }
        run.wait { $0.contains("abc") }
        try run.rewrite("abcdefg\n", cols: 41, rows: 9, spinner: .bar)
        // 41 - 7 content - 2 spinner leaves 16 to the left, versus 18 for the shorter message
        #expect(run.paints("\(Self.esc)[16C"))
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
        #expect(run.paints(frame))
        #expect(run.running)
    }

    @Test func rewritingTurnsTheSpinnerOnWithoutRespawning() throws {
        let run = try Run("busy\n", cols: 40, rows: 7)
        defer { run.stop() }
        run.wait { $0.contains("busy") }
        #expect(!run.painted.contains("| busy"))
        try run.rewrite("busy\n", spinner: .bar)
        #expect(run.paints("| busy"))
        #expect(run.running)
    }

    // line one is always the header; a body whose header is not numbers paints in the built-in box instead
    // of arithmetic on garbage.
    @Test func aMalformedHeaderFallsBackToTheDefaultBox() throws {
        let run = try Run("", cols: 21, rows: 5)
        defer { run.stop() }
        try "not a header\nvisible\n".write(to: run.bodyFile, atomically: true, encoding: .utf8)
        // the default 40-column box leaves 16 to the left of a 7-character line, where 21 would leave 7
        #expect(run.paints("\(Self.esc)[16Cvisible"))
    }

    @Test func spinnerPrefixesTheFirstLineAndAdvances() throws {
        let run = try Run("busy\n", cols: 40, rows: 7, spinner: .bar)
        defer { run.stop() }
        #expect(run.paints("| busy", "/ busy", "- busy"))
    }

    // the frames live in the header, not the script, so a style the helper has never heard of animates
    @Test(arguments: HudSpinner.allCases) func paintsWhicheverFramesTheHeaderCarries(style: HudSpinner) throws {
        let run = try Run("busy\n", cols: 40, rows: 7, spinner: style)
        defer { run.stop() }
        #expect(run.paints(style.frames.map { "\($0) busy" }))
    }

    @Test func switchingStyleRepaintsWithoutRespawning() throws {
        let run = try Run("busy\n", cols: 40, rows: 7, spinner: .bar)
        defer { run.stop() }
        run.wait { $0.contains("| busy") }
        try run.rewrite("busy\n", spinner: .braille)
        #expect(run.paints("⠋ busy"))
        #expect(run.running)
    }

    // the blink's off frame is a NO-BREAK SPACE, which the header's word splitting keeps and which still
    // occupies the glyph's column: a real space would be swallowed and the message would jump two columns
    // left on every other frame.
    @Test func theBlinkKeepsItsColumnOnTheOffFrame() throws {
        let run = try Run("busy\n", cols: 40, rows: 7, spinner: .dot)
        defer { run.stop() }
        // 40 columns less 4 for "busy" less 2 for the glyph leaves 17 on both frames
        #expect(run.paints("\(Self.esc)[17C● busy"))
        #expect(run.paints("\(Self.esc)[17C\u{00A0} busy"))
    }

    @Test func theHeadersTextColorIsEmittedBeforeTheFrame() throws {
        let run = try Run("busy\n", cols: 40, rows: 7, textColor: "38;2;126;192;126")
        defer { run.stop() }
        #expect(run.paints("\(Self.esc)[38;2;126;192;126m"))
    }

    // it goes after the erase so the cleared cells keep the terminal's own colors, and before the block so
    // the detail's dim attribute composes over it rather than replacing it.
    @Test func theTextColorSitsBetweenTheEraseAndTheContent() throws {
        let run = try Run("busy\n", cols: 40, rows: 7, textColor: "38;2;0;0;255")
        defer { run.stop() }
        run.wait { $0.contains("busy") }
        #expect(run.painted.contains("\(Self.esc)[J\(Self.esc)[38;2;0;0;255m"))
    }

    @Test func noColorEscapeWhenTheHeaderCarriesTheSentinel() throws {
        let run = try Run("busy\n", cols: 40, rows: 7)
        defer { run.stop() }
        run.wait { $0.contains("busy") }
        #expect(!run.painted.contains("\(Self.esc)[38;2"))
    }

    // the color rides the header, so an update recolors the live panel with no respawn — the one half of a
    // HUD's color a `hud update` can change.
    @Test func recoloringThroughTheHeaderKeepsTheHelperAlive() throws {
        let run = try Run("busy\n", cols: 40, rows: 7)
        defer { run.stop() }
        run.wait { $0.contains("busy") }
        try run.rewrite("busy\n", textColor: "38;2;255;0;0")
        #expect(run.paints("\(Self.esc)[38;2;255;0;0m"))
        #expect(run.running)
    }

    // a header field that is not SGR parameters is dropped rather than wrapped, so a malformed body cannot
    // emit an arbitrary escape into the pane.
    @Test(arguments: ["38;2;1m;7", "abc", "1;J"])
    func aMalformedTextColorPaintsNoEscape(raw: String) throws {
        let run = try Run("busy\n", cols: 40, rows: 7, textColor: raw)
        defer { run.stop() }
        run.wait { $0.contains("busy") }
        #expect(!run.painted.contains("\(Self.esc)[\(raw)m"))
    }

    @Test func noSpinnerGlyphWithoutTheFlag() throws {
        let run = try Run("busy\n", cols: 40, rows: 7)
        defer { run.stop() }
        let painted = run.wait { $0.contains("busy") }
        #expect(!painted.contains("| busy"))
        #expect(!painted.contains("/ busy"))
    }

    @Test func exitsWhenTheBodyFileDisappears() throws {
        let run = try Run("bye\n", cols: 40, rows: 7, spinner: .bar)
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
        // `Run`'s initializer can throw, which would otherwise leave this sleeper behind for the whole run
        defer { if owner.isRunning { owner.terminate() } }

        let run = try Run("bye\n", cols: 40, rows: 7, spinner: .bar, ownerPid: owner.processIdentifier)
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

        #expect(run.paints("still here"))
        #expect(run.running)
    }

    // the fourth field has three treat-as-absent spellings; a non-numeric one reaching `kill -0` would fail
    // and take a live panel down on the next tick.
    @Test(arguments: ["", "0", "notapid"]) func keepsPaintingWhenTheOwnerFieldIsNotAPid(owner: String) throws {
        let run = try Run("", cols: 21, rows: 5)
        defer { run.stop() }
        try "40 7 0 \(owner)\nstill here\n".write(to: run.bodyFile, atomically: true, encoding: .utf8)

        #expect(run.paints("still here"))
        #expect(run.running)
    }

    // `${#line}` counts BYTES outside a UTF-8 locale, and the app sized the box in characters: under the
    // locale-less environment a Dock-launched app inherits, an unfixed script centers "…" three columns off.
    @Test func centersANonAsciiMessageByCharactersNotBytes() throws {
        let run = try Run("a message …\n", cols: 41, rows: 5)
        defer { run.stop() }
        // 41 columns less 11 characters leaves 15 to the left; counting the 13 bytes would leave 14
        let frame = "\(Self.esc)[15Ca message …"
        #expect(run.paints(frame))
    }

    // the two halves must count the same unit: `${#line}` counts CODE POINTS, `String.count` counts grapheme
    // clusters, and an accented word is where they part. macOS hands paths back decomposed, so `HudLayout`
    // precomposes and measures in `cellCount`; centering the bytes it actually wrote is what proves both.
    @Test func centersAnAccentedMessageOnTheCountTheAppMeasured() throws {
        let lines = HudLayout.bodyLines(for: HudSpec(message: "cafe\u{0301} au lait"))
        let run = try Run(lines.map { $0 + "\n" }.joined(), cols: 40, rows: 5)
        defer { run.stop() }

        // 40 columns less the 12 the app counted leaves 14 to the left; a decomposed 13 would leave 13
        let left = (40 - HudLayout.cellCount(lines[0])) / 2
        #expect(left == 14)
        let frame = "\(Self.esc)[\(left)C\(lines[0])"
        #expect(run.paints(frame))
    }

    // every write wakes the app's renderer, so a settled panel must go quiet rather than repaint at 2 Hz
    @Test func stopsWritingOnceASpinnerlessFrameIsSettled() throws {
        let run = try Run("settled\n", cols: 40, rows: 7)
        defer { run.stop() }
        run.wait { $0.contains("settled") }

        let after = run.painted
        Thread.sleep(forTimeInterval: Self.spinnerlessTick * 2)
        #expect(run.painted == after)
        #expect(run.running)

        try run.rewrite("moved on\n", cols: 40, rows: 7)
        #expect(run.paints("moved on"))
    }

    @Test func hidesTheCursorAndRestoresItOnExit() throws {
        let run = try Run("bye\n", cols: 40, rows: 7, spinner: .bar)
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
        // bounded: a regression that made this path loop would otherwise hang the suite instead of failing
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        defer { if proc.isRunning { proc.terminate() } }
        #expect(!proc.isRunning, "no body path must exit at once, not loop")
        #expect(proc.terminationStatus == 0)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
