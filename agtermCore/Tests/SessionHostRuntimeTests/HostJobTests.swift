import Foundation
import Testing
@testable import SessionHostRuntime

struct HostJobTests {
    private let job = HostJob(bundleID: "com.example.app", key: "0123456789ab-100003", executable: "/A.app/Contents/MacOS/agterm-session-host",
                              socketDirectory: "/tmp/zmx", umask: 0o022, nonce: "deadbeef")

    @Test func labelNamesTheEndpointAndTheAttempt() {
        #expect(job.label == "com.example.app.session-host.0123456789ab-100003.deadbeef")
        #expect(job.label.hasPrefix(HostJob.labelPrefix(bundleID: "com.example.app", key: "0123456789ab-100003")))
    }

    @Test func eachAttemptGetsItsOwnLabel() {
        let first = HostJob(bundleID: "com.example.app", key: "0123456789ab-1", executable: "/x", socketDirectory: "/tmp/zmx", umask: 0o022)
        let second = HostJob(bundleID: "com.example.app", key: "0123456789ab-1", executable: "/x", socketDirectory: "/tmp/zmx", umask: 0o022)
        #expect(first.label != second.label)
        #expect(first.label.count == HostJob.labelPrefix(bundleID: "com.example.app", key: "0123456789ab-1").count + 8)
    }

    @Test func argumentsCarryTheKeyAndLabelTheHostChecks() {
        #expect(job.arguments == ["/A.app/Contents/MacOS/agterm-session-host", "host", "/tmp/zmx", "0123456789ab-100003", job.label])
    }

    @Test func plistDefinesAnInteractiveOneShotJobWithoutAnEnvironment() throws {
        let plist = try #require(try PropertyListSerialization.propertyList(from: job.plist(), format: nil) as? [String: Any])
        #expect(Set(plist.keys) == ["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "ProcessType", "AbandonProcessGroup", "Umask"])
        #expect(plist["Label"] as? String == job.label)
        #expect(plist["ProgramArguments"] as? [String] == job.arguments)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == false)
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["AbandonProcessGroup"] as? Bool == true)
        #expect(plist["Umask"] as? Int == 18)
    }

    @Test func unwritablePlistFailsWithoutLoadingAnything() {
        let directory = "/tmp/hostjob-missing-\(UUID().uuidString)"
        guard case .failed(let reason) = job.bootstrap(directory: directory, deadline: ProcessInfo.processInfo.systemUptime + 2) else {
            Issue.record("expected a failure")
            return
        }
        #expect(reason.hasPrefix("plist:"))
        #expect(!FileManager.default.fileExists(atPath: directory))
    }
}
