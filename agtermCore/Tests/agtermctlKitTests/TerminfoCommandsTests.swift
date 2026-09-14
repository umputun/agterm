import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct TerminfoCommandsTests {
    @Test func installMapsItsTypedOptionsOntoTheConnection() throws {
        let install = try Terminfo.Install.parse(["me@buildbox", "-p", "2222", "-i", "/k1", "-i", "/k2", "-J", "bastion", "-F", "/cfg"])

        #expect(install.connection == TerminfoInstall.Connection(destination: "me@buildbox", port: 2222, identities: ["/k1", "/k2"],
                                                                 jump: "bastion", config: "/cfg"))
    }

    @Test func installTakesABareDestination() throws {
        #expect(try Terminfo.Install.parse(["buildbox"]).connection == TerminfoInstall.Connection(destination: "buildbox"))
    }

    // the ssh argument bag is not forwarded: a remote command or an ssh mode flag has no way in
    @Test(arguments: [[], ["buildbox", "uptime"], ["--", "-G"], ["-N", "buildbox"], ["buildbox", "--socket", "/tmp/s"]])
    func installRefusesAnythingBeyondTheDestinationAndItsOptions(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try Terminfo.Install.parse(arguments) }
    }

    @Test func installIsNotAControlCommand() throws {
        #expect(!(try Agtermctl.parseAsRoot(["terminfo", "install", "buildbox"]) is any RequestCommand))
    }
}
