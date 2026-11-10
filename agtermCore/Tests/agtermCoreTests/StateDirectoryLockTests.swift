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

    private func descriptor(openOn path: String) -> Int32? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        for fd in entries.compactMap({ Int32($0) }) {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &buffer) == 0, String(cString: buffer) == path { return fd }
        }
        return nil
    }

    // regression: a child spawned while the lock was held kept it locked after release
    @Test func releasingTheLockFreesItWhileAChildHoldsACopyOfItsDescriptor() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var first = ownedLock(StateDirectoryLock.acquire(directory: dir))
        #expect(first != nil)
        let resolved = try #require(realpath(dir.appendingPathComponent(StateDirectoryLock.filename).path, nil))
        let lockPath = String(cString: resolved)
        free(resolved)
        let fd = try #require(descriptor(openOn: lockPath))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fd, 3)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        try #require(posix_spawn(&pid, "/bin/sleep", &actions, nil, argv, environ) == 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
        first = nil
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
