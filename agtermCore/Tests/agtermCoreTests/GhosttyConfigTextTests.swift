import Foundation
import Testing
@testable import agtermCore

struct GhosttyConfigTextTests {
    private static func pairs(_ text: String) -> [String] {
        GhosttyConfigText.keyValues(in: text).map { "\($0.key)=\($0.value)" }
    }

    private static func hex(_ value: String) -> String? {
        value.hasPrefix("#") && value.count == 7 ? value : nil
    }

    @Test func keyValuesSkipsBlankAndCommentLinesAndTrimsAroundEquals() {
        let text = "# comment\n\n  theme  =  My Light  \nselection-background=#112233\nno equals here\n"
        #expect(Self.pairs(text) == ["theme=My Light", "selection-background=#112233"])
    }

    @Test(arguments: [
        ("theme = \"/Users/me/My Light\"", "/Users/me/My Light"),
        ("theme = \"\"", ""),
        ("theme = \"a\\\"b\"", "a\\\"b"),
        ("theme = \"half", "\"half"),
        ("theme = \"", "\""),
        ("theme = say \"hi\"", "say \"hi\""),
    ])
    func keyValuesStripsOnlyOneSurroundingQuotePair(line: String, value: String) {
        #expect(GhosttyConfigText.keyValues(in: line).map { $0.value } == [value])
    }

    @Test func lastSettingTakesTheLastValidValue() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-background = #111111\nselection-background = #222222")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .value("#222222"))
    }

    @Test func lastSettingKeepsAValidValueAnInvalidOneFollows() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-background = #111111\nselection-background = bogus")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .value("#111111"))
    }

    @Test func lastSettingTreatsAnEmptyValueAsReset() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-background = #111111\nselection-background =")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .reset)
    }

    @Test func lastSettingKeepsAResetAnInvalidValueFollows() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-background =\nselection-background = bogus")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .reset)
    }

    @Test func lastSettingIsUnsetWithoutAValidOrEmptyOccurrence() {
        let pairs = GhosttyConfigText.keyValues(in: "selection-foreground = #111111\nselection-background = bogus")
        #expect(GhosttyConfigText.lastSetting(of: "selection-background", in: pairs, parse: Self.hex) == .unset)
    }

    @Test(arguments: [
        (GhosttyConfigText.Setting<String>.value("#explicit"), GhosttyConfigText.Setting<String>.value("#theme"), String?("#explicit")),
        (.reset, .value("#theme"), nil),
        (.unset, .value("#theme"), "#theme"),
        (.unset, .reset, nil),
        (.unset, .unset, nil),
    ])
    func explicitSettingTakesPrecedenceOverTheTheme(explicit: GhosttyConfigText.Setting<String>,
                                                    theme: GhosttyConfigText.Setting<String>, expected: String?) {
        #expect(explicit.over(theme) == expected)
    }

    private static func commands(loading paths: [String], files: [String: String]) -> [String] {
        GhosttyConfigText.keyValues(loading: paths, home: "/home/me") { files[$0] }
            .filter { $0.key == "command" }.map(\.value)
    }

    @Test func includesLoadAfterEverySourceInQueueOrder() {
        let files = [
            "/cfg/a.conf": "config-file = inc/one.conf\ncommand = a",
            "/cfg/b.conf": "command = b\nconfig-file = /abs/two.conf",
            "/cfg/inc/one.conf": "command = one\nconfig-file = nested.conf",
            "/abs/two.conf": "command = two",
            "/cfg/inc/nested.conf": "command = nested",
        ]
        #expect(Self.commands(loading: ["/cfg/a.conf", "/cfg/b.conf"], files: files) == ["a", "b", "one", "two", "nested"])
    }

    @Test func includePathsHonorOptionalMarkerQuotesAndHome() {
        let files = [
            "/cfg/main.conf": "config-file = ?\"spaced name.conf\"\nconfig-file = ~/extra.conf\nconfig-file = ?missing.conf",
            "/cfg/spaced name.conf": "command = spaced",
            "/home/me/extra.conf": "command = home",
        ]
        #expect(Self.commands(loading: ["/cfg/main.conf"], files: files) == ["spaced", "home"])
    }

    @Test func emptyConfigFileClearsTheQueuedIncludes() {
        let files = [
            "/cfg/a.conf": "config-file = dropped.conf",
            "/cfg/b.conf": "config-file =\nconfig-file = kept.conf",
            "/cfg/dropped.conf": "command = dropped",
            "/cfg/kept.conf": "command = kept",
        ]
        #expect(Self.commands(loading: ["/cfg/a.conf", "/cfg/b.conf"], files: files) == ["kept"])
    }

    @Test func anIncludeCycleLoadsEachIncludeOnce() {
        let files = [
            "/cfg/main.conf": "config-file = loop.conf",
            "/cfg/loop.conf": "command = loop\nconfig-file = loop.conf",
        ]
        #expect(Self.commands(loading: ["/cfg/main.conf"], files: files) == ["loop"])
    }

    @Test func keyValuesSplitsCRLFLines() {
        #expect(Self.pairs("# comment\r\ncommand = /bin/zsh\r\ntheme = x\r\n") == ["command=/bin/zsh", "theme=x"])
    }

    @Test func aNestedIncludeResolvesFromTheSymlinkTargetDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agterm-config-include-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scoped = root.appending(path: "scoped"), dotfiles = root.appending(path: "dotfiles")
        try FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try "config-file = shell.conf".write(to: scoped.appending(path: "ghostty.conf"), atomically: true, encoding: .utf8)
        try "config-file = fish.conf".write(to: dotfiles.appending(path: "shell.conf"), atomically: true, encoding: .utf8)
        try "command = target".write(to: dotfiles.appending(path: "fish.conf"), atomically: true, encoding: .utf8)
        try "command = alias".write(to: scoped.appending(path: "fish.conf"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: scoped.appending(path: "shell.conf"),
                                                   withDestinationURL: dotfiles.appending(path: "shell.conf"))

        let pairs = GhosttyConfigText.keyValues(loading: [scoped.appending(path: "ghostty.conf").path], home: "/home/me") {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }

        #expect(pairs.filter { $0.key == "command" }.map(\.value) == ["target"])
    }
}
