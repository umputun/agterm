import AgtermResponsibility
import Darwin
import Foundation
import Testing

struct ResponsibilityTests {
    // regression: a descriptor another thread had not yet marked close-on-exec reached the disclaimed host
    @Test(.enabled(if: Responsibility.system.isAvailable))
    func aDisclaimedChildGetsNoInheritableDescriptor() throws {
        let original = open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(original >= 0)
        defer { close(original) }
        let inheritable = fcntl(original, F_DUPFD, 203)
        try #require(inheritable >= 0)
        defer { close(inheritable) }
        let report = NSTemporaryDirectory() + "agterm-disclaimed-\(UUID().uuidString)"
        defer { unlink(report) }

        let child = try Responsibility.system.spawnDisclaimed(
            executable: "/bin/sh",
            argv: ["/bin/sh", "-c", "if [ -e /dev/fd/\(inheritable) ]; then echo open; else echo closed; fi > '\(report)'"],
            env: [:])
        var status: Int32 = 0
        #expect(waitpid(child, &status, 0) == child)

        #expect(try String(contentsOfFile: report, encoding: .utf8) == "closed\n")
    }
}
