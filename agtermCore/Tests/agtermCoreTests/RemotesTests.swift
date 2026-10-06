import Foundation
import Testing
@testable import agtermCore

struct RemotesTests {
    @Test func aBareDestinationLabelsItself() {
        let (remotes, diagnostics) = parseRemotesConf("studio.local\n")
        #expect(diagnostics.isEmpty)
        #expect(remotes.entries == [RemoteEntry(destination: "studio.local", label: "studio.local", line: 1)])
    }

    @Test func theRestOfTheLineIsTheLabelVerbatim() {
        let (remotes, diagnostics) = parseRemotesConf("me@192.168.1.33 \t  Mac Studio  #2 \n")
        #expect(diagnostics.isEmpty)
        #expect(remotes.entries == [RemoteEntry(destination: "me@192.168.1.33", label: "Mac Studio  #2", line: 1)])
    }

    @Test func blankAndWholeLineCommentsAreIgnoredAndCRLFIsNormalized() {
        let text = "# header\r\n\r\n   # indented comment\r\nstudio.local\r\n\r\nmini office mini\r\n"
        let (remotes, diagnostics) = parseRemotesConf(text)
        #expect(diagnostics.isEmpty)
        #expect(remotes.entries.map(\.destination) == ["studio.local", "mini"])
        #expect(remotes.entries.map(\.label) == ["studio.local", "office mini"])
        #expect(remotes.entries.map(\.line) == [4, 6])
    }

    @Test(arguments: ["-oProxyCommand=evil host", "bad\u{1b}[31mhost", "ho\u{7f}st label"])
    func aDestinationSshWouldMisreadIsSkippedWithItsLine(line: String) {
        let (remotes, diagnostics) = parseRemotesConf("good\n\(line)\nalso-good\n")
        #expect(remotes.entries.map(\.destination) == ["good", "also-good"])
        #expect(diagnostics == [KeymapDiagnostic(line: 2, message: "invalid destination; remote skipped")])
    }

    @Test func aLabelWithControlCharactersIsSkipped() {
        let (remotes, diagnostics) = parseRemotesConf("studio \u{1b}[31mred\nmini\ttabbed\tlabel\n")
        #expect(remotes.entries == [RemoteEntry(destination: "mini", label: "tabbed\tlabel", line: 2)])
        #expect(diagnostics.map(\.line) == [1])
        #expect(diagnostics.first?.message.contains("control characters") == true)
    }

    @Test func aRepeatedDestinationKeepsTheFirstAndLabelsMayRepeat() {
        let (remotes, diagnostics) = parseRemotesConf("""
        studio first
        mini first
        studio second
        """)
        #expect(remotes.entries.map(\.destination) == ["studio", "mini"])
        #expect(remotes.entries.map(\.label) == ["first", "first"])
        #expect(diagnostics == [KeymapDiagnostic(line: 3, message: "remote 'studio' is already defined; remote skipped")])
    }

    @Test func aMissingFileLoadsAsNoRemotes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remotes-\(UUID().uuidString).conf")
        let loaded = try RemotesFile.load(at: url)
        #expect(loaded.remotes.entries.isEmpty)
        #expect(loaded.diagnostics.isEmpty)
    }

    @Test func anExistingFileLoadsItsEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remotes-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: url) }
        try "studio\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(try RemotesFile.load(at: url).remotes.entries.map(\.destination) == ["studio"])
    }

    @Test func aFileThatExistsButCannotBeReadThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remotes-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try RemotesFile.load(at: url) }
    }

    @Test func emptyTextParsesToNothing() {
        let (remotes, diagnostics) = parseRemotesConf("")
        #expect(remotes.entries.isEmpty)
        #expect(diagnostics.isEmpty)
    }
}
