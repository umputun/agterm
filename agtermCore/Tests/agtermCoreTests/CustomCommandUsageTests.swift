import Foundation
import Testing
@testable import agtermCore

struct CustomCommandUsageTests {
    private let finder = CustomCommand(name: "Finder", command: "open .", shortcut: "cmd+shift+f")
    private let lazygit = CustomCommand(name: "Lazygit", command: "lazygit", shortcut: "")
    private let cheatsheet = CustomCommand(name: "Cheatsheet", command: "less keys.md", shortcut: "ctrl+a>k")

    @Test func recordCountsRunsByName() {
        var usage = CustomCommandUsage()
        usage.record(finder)
        usage.record(finder)
        usage.record(lazygit)
        #expect(usage.counts == ["Finder": 2, "Lazygit": 1])
    }

    @Test func mostUsedOrdersByCountThenKeymapOrderAndSkipsNeverRun() {
        var usage = CustomCommandUsage()
        usage.record(cheatsheet)
        usage.record(lazygit)
        usage.record(finder)
        usage.record(cheatsheet)
        let commands = [finder, lazygit, cheatsheet]
        #expect(usage.mostUsed(of: commands, limit: 5).map(\.name) == ["Cheatsheet", "Finder", "Lazygit"])
        #expect(usage.mostUsed(of: commands, limit: 2).map(\.name) == ["Cheatsheet", "Finder"])
        #expect(usage.mostUsed(of: [lazygit, finder], limit: 5).map(\.name) == ["Lazygit", "Finder"])
        #expect(usage.mostUsed(of: commands, limit: 0).isEmpty)
        #expect(CustomCommandUsage().mostUsed(of: commands, limit: 5).isEmpty)
    }

    @Test func mostUsedIgnoresCountsForCommandsNoLongerInTheKeymap() {
        var usage = CustomCommandUsage(counts: ["Gone": 9, "Zero": 0])
        usage.record(finder)
        let zero = CustomCommand(name: "Zero", command: "true", shortcut: "")
        #expect(usage.mostUsed(of: [zero, finder], limit: 5).map(\.name) == ["Finder"])
    }

    @Test func storeRoundTripsAndReadsMissingOrForeignFilesAsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-command-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("custom-command-usage.json")
        let store = CustomCommandUsageStore(directory: directory)
        #expect(store.load() == CustomCommandUsage())

        store.record(finder)
        store.record(finder)
        #expect(store.load() == CustomCommandUsage(counts: ["Finder": 2]))

        let foreign = CustomCommandUsage(version: CustomCommandUsage.currentVersion + 1, counts: ["x": 3])
        try JSONEncoder().encode(foreign).write(to: file)
        #expect(store.load() == CustomCommandUsage())

        try Data("not json".utf8).write(to: file)
        #expect(store.load() == CustomCommandUsage())
    }
}
