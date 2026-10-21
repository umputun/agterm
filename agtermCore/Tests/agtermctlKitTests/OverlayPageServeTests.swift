import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct OverlayPageServeTests {
    @Test func pageServeNamesTheTokenAsItsTarget() throws {
        let command = try Session.Overlay.PageServe.parse(["tok-1", "--socket", "/tmp/x.sock"])

        #expect(command.makeRequest() == ControlRequest(cmd: .sessionOverlayPageServe, target: "tok-1"))
        #expect(command.options.socketPath() == "/tmp/x.sock")
    }

    @Test func pageServeRequiresAToken() {
        #expect(throws: (any Error).self) { try Session.Overlay.PageServe.parse([]) }
    }

    @Test func aRefusedClaimExitsNonzero() throws {
        let server = StubServer(response: ControlResponse(ok: false, error: "page not claimable"))
        try server.start()
        defer { server.stop() }

        let command = try Session.Overlay.PageServe.parse([UUID().uuidString, "--socket", server.path])
        #expect(throws: ExitCode.failure) { try command.run() }
    }
}
