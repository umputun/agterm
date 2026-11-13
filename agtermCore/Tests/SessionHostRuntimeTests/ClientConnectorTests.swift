import AgtermResponsibility
import Darwin
import Foundation
import Testing
import agtermCore
@testable import SessionHostRuntime

@Suite(.enabled(if: Responsibility.system.isAvailable, "needs the responsibility SPI"))
struct ClientConnectorTests {
    private static let key = "0123456789ab-100003"

    @Test(arguments: [HostJob.Outcome.succeeded, .uncertain])
    func submittedJobIsNeverStartedTwice(_ outcome: HostJob.Outcome) throws {
        let fixture = try Fixture(launchdSupported: true, outcome: outcome)
        defer { fixture.cleanup() }
        let error = #expect(throws: HostFailure.self) { try fixture.connector(startupTimeout: 0.3).ensureRunning() }
        guard case .timeout? = error else { Issue.record("expected a timeout, got \(String(describing: error))"); return }
        #expect(fixture.starter.jobs.count == 1)
        #expect(fixture.starter.spawns.isEmpty)
    }

    @Test func failedJobFallsBackToTheDisclaimedSpawn() throws {
        let fixture = try Fixture(launchdSupported: true, outcome: .failed("launchctl bootstrap status 5"))
        defer { fixture.cleanup() }
        #expect(throws: SpawnRefused.self) { try fixture.connector(startupTimeout: 10).ensureRunning() }
        #expect(fixture.starter.jobs.count == 1)
        #expect(fixture.starter.spawns == [fixture.disclaimedArgv])
    }

    @Test func unsupportedSystemSpawnsAsBeforeWithoutAJob() throws {
        let fixture = try Fixture(launchdSupported: false, outcome: .succeeded)
        defer { fixture.cleanup() }
        #expect(throws: SpawnRefused.self) { try fixture.connector(startupTimeout: 10).ensureRunning() }
        #expect(fixture.starter.jobs.isEmpty)
        #expect(fixture.starter.spawns == [fixture.disclaimedArgv])
    }

    @Test func connectorWithoutAKeyNeverSubmitsAJob() throws {
        let fixture = try Fixture(launchdSupported: true, outcome: .succeeded)
        defer { fixture.cleanup() }
        #expect(throws: SpawnRefused.self) { try fixture.connector(startupTimeout: 10, key: nil).ensureRunning() }
        #expect(fixture.starter.jobs.isEmpty)
        #expect(fixture.starter.spawns == [fixture.disclaimedArgv])
    }

    @Test func jobRunsThisHelperForThisEndpoint() throws {
        let fixture = try Fixture(launchdSupported: true, outcome: .failed("x"))
        defer { fixture.cleanup() }
        _ = try? fixture.connector(startupTimeout: 10).ensureRunning()
        let job = try #require(fixture.starter.jobs.first)
        #expect(job.job.label.hasPrefix(HostJob.labelPrefix(bundleID: "com.example.connector", key: Self.key)))
        #expect(job.job.arguments == [fixture.executable, "host", fixture.socketDirectory, Self.key, job.job.label])
        #expect(job.directory == URL(fileURLWithPath: fixture.paths.socket).deletingLastPathComponent().path)
    }

    @Test(arguments: [(TimeInterval(10), TimeInterval(2)), (0.3, 0.3)])
    func launchctlBudgetIsCappedByTheStartupDeadline(startupTimeout: TimeInterval, budget: TimeInterval) throws {
        let fixture = try Fixture(launchdSupported: true, outcome: .failed("x"))
        defer { fixture.cleanup() }
        let start = ProcessInfo.processInfo.systemUptime
        _ = try? fixture.connector(startupTimeout: startupTimeout).ensureRunning()
        let deadline = try #require(fixture.starter.jobs.first?.deadline)
        #expect(deadline - start >= budget)
        #expect(deadline - start < budget + 1)
    }

    struct SpawnRefused: Error {}

    final class Starter: HostStarter {
        let launchdSupported: Bool
        let outcome: HostJob.Outcome
        var jobs: [(job: HostJob, directory: String, deadline: TimeInterval)] = []
        var spawns: [[String]] = []

        init(launchdSupported: Bool, outcome: HostJob.Outcome) {
            self.launchdSupported = launchdSupported
            self.outcome = outcome
        }

        func bootstrap(_ job: HostJob, directory: String, deadline: TimeInterval) -> HostJob.Outcome {
            jobs.append((job, directory, deadline))
            return outcome
        }

        func spawnDisclaimed(executable: String, argv: [String], env: [String: String]) throws -> Int32 {
            spawns.append(argv)
            throw SpawnRefused()
        }
    }

    final class Fixture {
        let socketDirectory = "/tmp/ccn-\(UUID().uuidString.prefix(8))"
        let paths: SessionHost.Paths
        let starter: Starter
        let executable: String

        init(launchdSupported: Bool, outcome: HostJob.Outcome) throws {
            paths = try SessionHost.paths(socketDirectory: socketDirectory, key: ClientConnectorTests.key)
            starter = Starter(launchdSupported: launchdSupported, outcome: outcome)
            executable = try HostIdentity.executablePath(pid: getpid())
        }

        var disclaimedArgv: [String] { [executable, "host", socketDirectory] }

        func connector(startupTimeout: TimeInterval, key: String? = ClientConnectorTests.key) throws -> ClientConnector {
            try ClientConnector(paths: paths, key: key, socketDirectory: socketDirectory, environment: ["ZMX_DIR": socketDirectory],
                                startupTimeout: startupTimeout, queueTimeout: 1,
                                identity: .init(bundleID: "com.example.connector", bundlePath: "/tmp/connector.app", pid: getpid()),
                                starter: starter)
        }

        func cleanup() { try? FileManager.default.removeItem(atPath: socketDirectory) }
    }
}
