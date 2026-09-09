import Darwin
import XCTest
@testable import AgtermResponsibility

final class ResponsibilitySPITests: XCTestCase {
    func testDisclaimedChildIsItsOwnRootWhilePlainChildKeepsTheHostsRoot() throws {
        let api = try systemSPI()
        let baseline = try XCTUnwrap(api.responsibleProcess(of: getpid()))
        let plain = try spawnPlainSleep()
        defer { terminateChild(plain) }
        let disclaimed = try api.spawnDisclaimed(executable: "/bin/sleep", argv: ["/bin/sleep", "30"], env: [:])
        defer { terminateChild(disclaimed) }

        XCTAssertEqual(api.responsibleProcess(of: plain), baseline)
        XCTAssertEqual(api.responsibleProcess(of: disclaimed), disclaimed)
    }

    func testEitherMissingSymbolPreventsSpawning() {
        for missing in ["responsibility_spawnattrs_setdisclaim", "responsibility_get_pid_responsible_for_pid"] {
            let api = Responsibility(resolveSymbol: { name in
                name == missing ? nil : dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            })
            XCTAssertFalse(api.isAvailable)
            var spawned: Int32?
            defer { if let spawned { terminateChild(spawned) } }
            XCTAssertThrowsError(try {
                spawned = try api.spawnDisclaimed(executable: "/bin/sleep", argv: ["/bin/sleep", "30"], env: [:])
            }()) { error in
                XCTAssertEqual(error as? Responsibility.SpawnError, .unavailable)
            }
        }
    }

    func testUnavailableReadAndInvalidPidsAreUnknown() {
        let absent = Responsibility(resolveSymbol: { _ in nil })
        XCTAssertNil(absent.responsibleProcess(of: getpid()))
        XCTAssertNil(Responsibility.system.responsibleProcess(of: 0))
        XCTAssertNil(Responsibility.system.responsibleProcess(of: -1))
    }

    func testMissingExecutableReturnsTheSpawnError() throws {
        let api = try systemSPI()
        XCTAssertThrowsError(try api.spawnDisclaimed(executable: "/no/such/session-host", argv: ["session-host"], env: [:])) { error in
            XCTAssertEqual(error as? Responsibility.SpawnError, .systemCall("posix_spawn", ENOENT))
        }
    }

    func testArgumentsAndEnvironmentReachTheChildUnchanged() throws {
        let api = try systemSPI()
        let child = try api.spawnDisclaimed(
            executable: "/bin/sh",
            argv: ["/bin/sh", "-c", "test \"$VALUE\" = \"$1\" && test \"$#\" -eq 1", "probe", "first line\nsecond line"],
            env: ["VALUE": "first line\nsecond line"])
        XCTAssertEqual(try waitForChild(child), 0)
    }

    func testInvalidCStringInputsDoNotSpawn() throws {
        let api = try systemSPI()
        let inputs: [(String, [String], [String: String])] = [
            ("/bin/sleep", [], [:]),
            ("/bin/sleep\0ignored", ["sleep", "30"], [:]),
            ("/bin/sleep", ["sleep", "30\0ignored"], [:]),
            ("/bin/sleep", ["sleep", "30"], ["BAD=KEY": "value"]),
            ("/bin/sleep", ["sleep", "30"], ["": "value"]),
            ("/bin/sleep", ["sleep", "30"], ["BAD\0KEY": "value"]),
            ("/bin/sleep", ["sleep", "30"], ["VALUE": "before\0after"]),
        ]
        for (executable, argv, env) in inputs {
            var spawned: Int32?
            defer { if let spawned { terminateChild(spawned) } }
            XCTAssertThrowsError(try {
                spawned = try api.spawnDisclaimed(executable: executable, argv: argv, env: env)
            }()) { error in
                XCTAssertEqual(error as? Responsibility.SpawnError, .invalidArguments)
            }
        }
    }

    private func systemSPI() throws -> Responsibility {
        let api = Responsibility.system
        try XCTSkipUnless(api.isAvailable, "Required responsibility symbols are absent")
        return api
    }

    private func spawnPlainSleep() throws -> Int32 {
        try "/bin/sleep".withCString { executable in
            try "30".withCString { duration in
                var argv: [UnsafeMutablePointer<CChar>?] = [
                    UnsafeMutablePointer(mutating: executable), UnsafeMutablePointer(mutating: duration), nil,
                ]
                var env: [UnsafeMutablePointer<CChar>?] = [nil]
                var pid: Int32 = 0
                let result = argv.withUnsafeMutableBufferPointer { arguments in
                    env.withUnsafeMutableBufferPointer { environment in
                        posix_spawn(&pid, executable, nil, nil, arguments.baseAddress, environment.baseAddress)
                    }
                }
                guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
                return pid
            }
        }
    }

    private func waitForChild(_ pid: Int32) throws -> Int32 {
        let deadline = Date().addingTimeInterval(5)
        var status: Int32 = 0
        while Date() < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result < 0 && errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        terminateChild(pid)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    private func terminateChild(_ pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}
