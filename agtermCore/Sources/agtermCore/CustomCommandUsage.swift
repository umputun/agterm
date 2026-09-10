import Foundation

/// Run counts for `keymap.conf` commands, keyed by name, backing the most-used section of the title-bar
/// custom-commands popover. The name is the durable key: `CustomCommand.id` is minted on every parse, and
/// the parser rejects a second `command` line with a name already taken.
public struct CustomCommandUsage: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var counts: [String: Int]

    public init(version: Int = CustomCommandUsage.currentVersion, counts: [String: Int] = [:]) {
        self.version = version
        self.counts = counts
    }

    /// Count one run of `command`.
    public mutating func record(_ command: CustomCommand) {
        counts[command.name, default: 0] += 1
    }

    /// The most-run of `commands`, at most `limit`, in descending count with ties kept in `commands` order.
    /// A command never run is left out, and a count whose command is no longer in the keymap takes no slot.
    public func mostUsed(of commands: [CustomCommand], limit: Int) -> [CustomCommand] {
        commands.enumerated()
            .compactMap { index, command -> (count: Int, index: Int, command: CustomCommand)? in
                guard let count = counts[command.name], count > 0 else { return nil }
                return (count, index, command)
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index }
            .prefix(max(0, limit))
            .map(\.command)
    }
}

/// On-disk home of `CustomCommandUsage`: `<stateDir>/custom-command-usage.json`, read tolerantly (a missing,
/// corrupt or foreign-version file counts as empty) and written atomically, like `RecentClosedStore`.
public struct CustomCommandUsageStore: Sendable {
    private let directory: URL
    private let fileName: String

    private var fileURL: URL { directory.appendingPathComponent(fileName) }

    public init(directory: URL, fileName: String = "custom-command-usage.json") {
        self.directory = directory
        self.fileName = fileName
    }

    public func load() -> CustomCommandUsage {
        guard let data = try? Data(contentsOf: fileURL),
              let usage = try? JSONDecoder().decode(CustomCommandUsage.self, from: data),
              usage.version == CustomCommandUsage.currentVersion else { return CustomCommandUsage() }
        return usage
    }

    /// Count one run of `command` and persist the result.
    public func record(_ command: CustomCommand) {
        var usage = load()
        usage.record(command)
        save(usage)
    }

    private func save(_ usage: CustomCommandUsage) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(usage).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("agterm: save custom command usage failed: %@", String(describing: error))
        }
    }
}
