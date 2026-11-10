import ArgumentParser
import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

struct DetachCommandsTests {
    @Test func sessionDetachSendsItsBatchAndWindow() throws {
        let parsed = try Agtermctl.parseAsRoot(["session", "detach", "--target", "s1", "--target", "s2", "--window", "w1"])
        let request = try #require(parsed as? any RequestCommand).makeRequest()

        #expect(request.cmd == .sessionDetach)
        #expect(request.target == "s1")
        #expect(request.args?.targets == ["s1", "s2"])
        #expect(request.args?.window == "w1")
    }

    @Test func sessionDetachDefaultsToTheActiveSession() throws {
        let request = try #require(try Agtermctl.parseAsRoot(["session", "detach"]) as? any RequestCommand).makeRequest()

        #expect(request == ControlRequest(cmd: .sessionDetach, target: "active"))
    }

    @Test(arguments: [(["session", "reattach", "--target", "ab12"], Command.sessionReattach),
                      (["workspace", "reattach", "--target", "ab12"], .workspaceReattach)])
    func aReattachNamesItsDetachedTarget(_ words: [String], _ cmd: Command) throws {
        let request = try #require(try Agtermctl.parseAsRoot(words) as? any RequestCommand).makeRequest()

        #expect(request == ControlRequest(cmd: cmd, target: "ab12"))
    }

    @Test(arguments: [["session", "reattach"], ["session", "reattach", "--target", "active"], ["workspace", "reattach", "--target", "ACTIVE"]])
    func aReattachNeedsAnIdThatIsNotActive(_ words: [String]) {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(words) }
    }

    @Test func workspaceDetachAndWindowRemoteDismissTakeTheirTargets() throws {
        let workspace = try #require(try Agtermctl.parseAsRoot(["workspace", "detach", "--target", "w9"]) as? any RequestCommand).makeRequest()
        let dismiss = try #require(try Agtermctl.parseAsRoot(["window", "remote", "dismiss", "w2"]) as? any RequestCommand).makeRequest()

        #expect(workspace == ControlRequest(cmd: .workspaceDetach, target: "w9"))
        #expect(dismiss == ControlRequest(cmd: .windowRemoteDismiss, target: "w2"))
    }
}
