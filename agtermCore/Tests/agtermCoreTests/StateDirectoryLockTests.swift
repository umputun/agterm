import Foundation
import Testing
@testable import agtermCore

struct StateDirectoryLockTests {
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agterm-state-lock-\(UUID().uuidString)")
    }

    private func ownedLock(_ outcome: StateDirectoryLock.Outcome) -> StateDirectoryLock? {
        if case .owned(let lock) = outcome { return lock }
        return nil
    }

    @Test func acquireCreatesAMissingDirectoryAndOwnsIt() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = ownedLock(StateDirectoryLock.acquire(directory: dir))
        #expect(lock != nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(StateDirectoryLock.filename).path))
    }

    @Test func aSecondAcquireWhileTheFirstIsHeldIsRefused() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(ownedLock(StateDirectoryLock.acquire(directory: dir)))
        guard case .heldByAnother = StateDirectoryLock.acquire(directory: dir) else {
            Issue.record("a second acquire must report the directory as held")
            return
        }
        withExtendedLifetime(first) {}
    }

    @Test func releasingTheLockLetsTheNextAcquireOwnItAndKeepsTheFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var first = ownedLock(StateDirectoryLock.acquire(directory: dir))
        #expect(first != nil)
        first = nil
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(StateDirectoryLock.filename).path))
        #expect(ownedLock(StateDirectoryLock.acquire(directory: dir)) != nil)
    }

    @Test func aDirectoryPathHeldByAFileIsUnavailableNotHeld() throws {
        let file = makeTempDir()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("x".utf8).write(to: file)
        guard case .unavailable(let reason) = StateDirectoryLock.acquire(directory: file) else {
            Issue.record("a state directory that cannot be created must be unavailable")
            return
        }
        #expect(reason.contains(file.path))
    }
}
