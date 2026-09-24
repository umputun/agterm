import Foundation

/// ZmxBuildRecord is when this state directory first launched the zmx build it names. Live sessions keep
/// their daemons through app updates, so a daemon created before `changedAt` predates that launch.
public struct ZmxBuildRecord: Codable, Equatable, Sendable {
    static let filename = "zmx-build.json"

    let id: String
    let changedAt: Date

    /// advanced floors `now` to whole seconds, the resolution of zmx's `created` time.
    static func advanced(from previous: ZmxBuildRecord?, bundledID: String, now: Date) -> ZmxBuildRecord {
        if let previous, previous.id == bundledID { return previous }
        return ZmxBuildRecord(id: bundledID, changedAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)))
    }

    /// launchCutoff is nil without a bundled id, which turns the outdated reset reason off. A record that
    /// cannot be saved still yields this launch's cutoff, and the next launch dates the change again.
    public static func launchCutoff(bundledID: String?, directory: URL, now: Date = Date()) -> Date? {
        guard let bundledID = bundledID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundledID.isEmpty else {
            return nil
        }
        let file = directory.appendingPathComponent(filename)
        let previous = load(from: file)
        let record = advanced(from: previous, bundledID: bundledID, now: now)
        if record != previous { try? record.save(to: file) }
        return record.changedAt
    }

    static func load(from file: URL) -> ZmxBuildRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ZmxBuildRecord.self, from: data)
    }

    func save(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
