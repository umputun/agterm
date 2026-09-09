import AgtermResponsibility
import XCTest
import agtermCore
@testable import agterm

@MainActor
final class SessionHostAcceptanceTests: XCTestCase {
    func testPrimaryDaemonLostAfterInventoryIsRecreatedByHost() throws {
        try assertRecreation(pane: .left)
    }

    func testSplitDaemonLostAfterInventoryIsRecreatedByHost() throws {
        try assertRecreation(pane: .right)
    }

    private func assertRecreation(pane: StatusPane) throws {
        try XCTSkipUnless(Responsibility.system.isAvailable, "Required responsibility symbols are absent")
        let fixture = try SessionHostClientTests.Fixture()
        defer { fixture.cleanup() }
        let id = try XCTUnwrap(UUID(uuidString: pane == .left ? "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" : "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        let name = ZmxSupport.daemonName(for: id)
        try fixture.startClient(name: name, terminal: true)
        _ = try fixture.waitForLeaders(count: 1)
        let client = ZmxClient(executablePath: fixture.zmx.path, socketDirectory: try XCTUnwrap(fixture.environment["ZMX_DIR"]))
        let inventory = try XCTUnwrap(client.sessionLeaderPIDs())
        let oldLeader = try XCTUnwrap(inventory[name])
        let host = try fixture.hostPID()
        let initialClient = try XCTUnwrap(fixture.clients.first)
        let attachDeadline = Date().addingTimeInterval(5)
        var attached = false
        repeat {
            var bytes = [UInt8](repeating: 0, count: 4096)
            if proc_pidpath(initialClient, &bytes, UInt32(bytes.count)) > 0 {
                attached = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).hasSuffix("/Contents/MacOS/zmx")
            }
            if attached { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while Date() < attachDeadline
        XCTAssertTrue(attached)
        XCTAssertEqual(kill(initialClient, SIGTERM), 0)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(initialClient, &status, 0), initialClient)
        fixture.clients.removeAll { $0 == initialClient }
        let session = Session(initialCwd: fixture.directory.path)
        session.wasRestored = true
        if pane == .left { session.paneIdentity = id } else {
            session.hasSplit = true
            session.isSplit = true
            session.splitPaneIdentity = id
        }
        let zdotdir = fixture.directory.appendingPathComponent("zsh")
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        try Data().write(to: zdotdir.appendingPathComponent(".zshenv"))
        try "HISTFILE=/dev/null\nSAVEHIST=0\n".write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var environment = fixture.environment
        environment["SHELL"] = "/bin/zsh"
        environment["ZDOTDIR"] = zdotdir.path
        let configuration = ZmxSupport.Configuration(executablePath: fixture.zmx.path, environment: environment,
                                                     daemonName: name, socketDirectory: try XCTUnwrap(fixture.environment["ZMX_DIR"]),
                                                     paneID: id.uuidString, sessionHostExecutablePath: fixture.executable.path)
        let surface = GhosttySurfaceView(workingDirectory: fixture.directory.path, env: configuration.environment, backedByZmx: true)
        defer { surface.teardown() }
        if pane == .right { surface.isSplitPane = true }
        surface.launchSeed = .pane(session: session, pane: pane, disposition: .wrapped(configuration),
                                   policy: .init(restoreEnabled: true, denylist: [], runningNames: Set(inventory.keys)))
        surface.createSurface()
        XCTAssertNil(surface.surface)
        XCTAssertNotNil(surface.launchSeed)
        XCTAssertTrue(client.kill(paneIdentities: [id]))
        XCTAssertNil(client.sessionLeaderPIDs()?[name])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(surface)
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        surface.createSurface()
        XCTAssertNotNil(surface.surface)
        var newLeader: Int32?
        let deadline = Date().addingTimeInterval(10)
        repeat {
            newLeader = client.sessionLeaderPIDs()?[name]
            if let newLeader, newLeader != oldLeader { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        let leader = try XCTUnwrap(newLeader)
        XCTAssertNotEqual(leader, oldLeader)
        XCTAssertEqual(Responsibility.system.responsibleProcess(of: leader), host)
        print("acceptance race pane=\(pane.rawValue) state=\(fixture.directory.path) host=\(host) initialClient=\(initialClient) oldLeader=\(oldLeader) newLeader=\(leader)")
    }
}
