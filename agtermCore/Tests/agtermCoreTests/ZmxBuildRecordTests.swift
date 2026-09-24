import Foundation
import Testing
@testable import agtermCore

struct ZmxBuildRecordTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-zmx-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func advancedStartsARecordFlooredToWholeSeconds() {
        let record = ZmxBuildRecord.advanced(from: nil, bundledID: "rev target digest", now: Date(timeIntervalSince1970: 1000.8))
        #expect(record == ZmxBuildRecord(id: "rev target digest", changedAt: Date(timeIntervalSince1970: 1000)))
    }

    @Test func advancedKeepsTheRecordForTheSameBuild() {
        let previous = ZmxBuildRecord(id: "a", changedAt: Date(timeIntervalSince1970: 500))
        #expect(ZmxBuildRecord.advanced(from: previous, bundledID: "a", now: Date(timeIntervalSince1970: 9000)) == previous)
    }

    @Test func advancedDatesANewBuild() {
        let previous = ZmxBuildRecord(id: "a", changedAt: Date(timeIntervalSince1970: 500))
        let record = ZmxBuildRecord.advanced(from: previous, bundledID: "b", now: Date(timeIntervalSince1970: 9000.4))
        #expect(record == ZmxBuildRecord(id: "b", changedAt: Date(timeIntervalSince1970: 9000)))
    }

    @Test func launchCutoffRecordsTheFirstLaunchAndKeepsItAcrossRelaunches() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = ZmxBuildRecord.launchCutoff(bundledID: "a\n", directory: dir, now: Date(timeIntervalSince1970: 1000.5))
        #expect(first == Date(timeIntervalSince1970: 1000))
        let again = ZmxBuildRecord.launchCutoff(bundledID: "a", directory: dir, now: Date(timeIntervalSince1970: 5000))
        #expect(again == Date(timeIntervalSince1970: 1000))
        let changed = ZmxBuildRecord.launchCutoff(bundledID: "b", directory: dir, now: Date(timeIntervalSince1970: 7000))
        #expect(changed == Date(timeIntervalSince1970: 7000))
        let saved = ZmxBuildRecord.load(from: dir.appendingPathComponent(ZmxBuildRecord.filename))
        #expect(saved == ZmxBuildRecord(id: "b", changedAt: Date(timeIntervalSince1970: 7000)))
    }

    @Test func launchCutoffTreatsAnUnreadableRecordAsAbsent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent(ZmxBuildRecord.filename))
        let cutoff = ZmxBuildRecord.launchCutoff(bundledID: "a", directory: dir, now: Date(timeIntervalSince1970: 3000))
        #expect(cutoff == Date(timeIntervalSince1970: 3000))
    }

    @Test(arguments: [nil, "", " \n"])
    func launchCutoffIsNilWithoutABundledID(_ bundledID: String?) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ZmxBuildRecord.launchCutoff(bundledID: bundledID, directory: dir) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(ZmxBuildRecord.filename).path))
    }
}
