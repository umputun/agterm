import Foundation
import Testing
@testable import agtermCore

struct WatermarkStorageTests {
    /// A fresh temp directory used as an injected `stateDir`, so these tests never touch process-global
    /// `AGTERM_STATE_DIR` (keeping them parallel-safe) and clean up after themselves.
    private func makeTempStateDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-wm-storage-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func directoryURLIsWatermarksSubdirOfStateDir() throws {
        let stateDir = try makeTempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        #expect(WatermarkStorage.directoryURL(stateDir: stateDir)
            == stateDir.appendingPathComponent("watermarks", isDirectory: true))
    }

    @Test func renderedTextURLNamesFileBySessionID() throws {
        let stateDir = try makeTempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let id = UUID()
        let url = WatermarkStorage.renderedTextURL(sessionID: id, stateDir: stateDir)
        #expect(url.lastPathComponent == "\(id.uuidString).png")
        #expect(url.deletingLastPathComponent() == stateDir.appendingPathComponent("watermarks", isDirectory: true))
    }

    @Test func directoryURLDoesNotCreateButEnsureDirectoryDoes() throws {
        let stateDir = try makeTempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let dir = WatermarkStorage.directoryURL(stateDir: stateDir)
        #expect(!FileManager.default.fileExists(atPath: dir.path)) // pure path resolution, no side effect
        let ensured = WatermarkStorage.ensureDirectory(stateDir: stateDir)
        #expect(ensured == dir)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func removeRenderedTextDeletesWhenPresentAndIsNoOpWhenAbsent() throws {
        let stateDir = try makeTempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let id = UUID()
        // no-op when absent (must not throw)
        WatermarkStorage.removeRenderedText(sessionID: id, stateDir: stateDir)

        WatermarkStorage.ensureDirectory(stateDir: stateDir)
        let url = WatermarkStorage.renderedTextURL(sessionID: id, stateDir: stateDir)
        try Data("png".utf8).write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        WatermarkStorage.removeRenderedText(sessionID: id, stateDir: stateDir)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
