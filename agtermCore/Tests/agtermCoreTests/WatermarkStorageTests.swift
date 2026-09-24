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
        #expect(!FileManager.default.fileExists(atPath: dir.path))
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
        WatermarkStorage.removeRenderedText(sessionID: id, stateDir: stateDir)

        WatermarkStorage.ensureDirectory(stateDir: stateDir)
        let url = WatermarkStorage.renderedTextURL(sessionID: id, stateDir: stateDir)
        try Data("png".utf8).write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        WatermarkStorage.removeRenderedText(sessionID: id, stateDir: stateDir)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func paneKeyNamesItsOwnFileAndRemovalTakesOnlyThatFile() throws {
        let stateDir = try makeTempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let id = UUID()
        WatermarkStorage.ensureDirectory(stateDir: stateDir)
        let sessionFile = WatermarkStorage.renderedTextURL(sessionID: id, stateDir: stateDir)
        let paneFile = WatermarkStorage.renderedTextURL(sessionID: id, paneKey: "scratch", stateDir: stateDir)
        #expect(paneFile.lastPathComponent == "\(id.uuidString)-scratch.png")
        try Data("png".utf8).write(to: sessionFile)
        try Data("png".utf8).write(to: paneFile)

        WatermarkStorage.removeRenderedText(sessionID: id, paneKey: "scratch", stateDir: stateDir)
        #expect(!FileManager.default.fileExists(atPath: paneFile.path))
        #expect(FileManager.default.fileExists(atPath: sessionFile.path))

        try Data("png".utf8).write(to: paneFile)
        WatermarkStorage.removeRenderedText(sessionID: id, stateDir: stateDir)
        #expect(!FileManager.default.fileExists(atPath: sessionFile.path))
        #expect(FileManager.default.fileExists(atPath: paneFile.path))
    }

    @Test func removeAllRenderedTextSweepsOneSessionsFilesOnly() throws {
        let stateDir = try makeTempStateDir()
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let id = UUID()
        let other = UUID()
        WatermarkStorage.ensureDirectory(stateDir: stateDir)
        let doomed = [WatermarkStorage.renderedTextURL(sessionID: id, stateDir: stateDir),
                      WatermarkStorage.renderedTextURL(sessionID: id, paneKey: UUID().uuidString, stateDir: stateDir),
                      WatermarkStorage.renderedTextURL(sessionID: id, paneKey: "scratch", stateDir: stateDir)]
        let kept = [WatermarkStorage.renderedTextURL(sessionID: other, stateDir: stateDir),
                    WatermarkStorage.renderedTextURL(sessionID: other, paneKey: "scratch", stateDir: stateDir)]
        for url in doomed + kept { try Data("png".utf8).write(to: url) }

        WatermarkStorage.removeAllRenderedText(sessionID: id, stateDir: stateDir)
        #expect(doomed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        WatermarkStorage.removeAllRenderedText(sessionID: UUID(), stateDir: stateDir.appendingPathComponent("absent"))
    }
}
