import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerRemoteOpenerTests: XCTestCase {
    private static let remoteLeft = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
    private var stateDir: URL!
    private var servers: [ControlServer] = []

    private final class Clock { var now = Date(timeIntervalSince1970: 1_789_000_000) }

    private final class Launches {
        var runs: [(rule: String, path: String, surface: GhosttySurfaceView, host: String)] = []
        var refusal: String?
    }

    private struct Fixture {
        let server: ControlServer
        let session: Session
        let transport: FakePresentationTransport
        let launcher: FakePageLauncher
        let launches: Launches
        let surface: GhosttySurfaceView
        let staging: URL
        let clock: Clock
    }

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-opener-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        for server in servers { server.stop() }
        servers.removeAll()
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testAnOfferedFileIsCopiedHereAndItsRuleRunsOnTheCopyWithTheOriginsHost() async throws {
        let body = Data(String(repeating: "# notes\n", count: 40).utf8)
        let fix = try connected(files: ["notes.md": body], chunkSize: 64)
        let click = try book(fix, "./notes.md")

        try offer(fix, click: click, name: "notes.md", size: body.count)
        try await waitUntil { !fix.launches.runs.isEmpty }

        let run = try XCTUnwrap(fix.launches.runs.first)
        XCTAssertEqual(run.rule, "*.md")
        XCTAssertEqual(run.host, "buildbox")
        XCTAssertTrue(run.surface === fix.surface)
        XCTAssertTrue(run.path.hasPrefix(fix.staging.path + "/"))
        XCTAssertEqual((run.path as NSString).lastPathComponent, "notes.md")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: run.path)), body)
        XCTAssertEqual(fix.launcher.launches.count, 1)
        XCTAssertTrue(fix.server.remoteOpeners.isIdle)
        XCTAssertFalse(fix.session.hudActive)
    }

    func testALaunchTheRunnerDeclinesLeavesNoCopy() async throws {
        let fix = try connected(files: ["notes.md": Data("# notes\n".utf8)])
        fix.launches.refusal = "the clicked pane is gone"
        let click = try book(fix, "./notes.md")

        try offer(fix, click: click, name: "notes.md", size: 8)
        try await waitUntil { !fix.launches.runs.isEmpty }

        XCTAssertEqual(try stagedCopies(fix), [])
        XCTAssertTrue(fix.server.remoteOpeners.isIdle)
    }

    func testUnderAHudARuleRunsOnTheCopyAndAHiddenRefusalLeavesTheHud() async throws {
        let fix = try connected(files: ["notes.md": Data("# notes\n".utf8)])
        XCTAssertTrue(fix.server.openHud(fix.session.id.uuidString, window: nil, spec: HudSpec(message: "agent")).ok)
        let shown = try book(fix, "./notes.md")
        let refused = try book(fix, "./other.md")
        XCTAssertEqual(fix.transport.clicks.map(\.snapshotOnly), [true, true])

        try offer(fix, click: shown, name: "notes.md", size: 8)
        try await waitUntil { !fix.launches.runs.isEmpty }
        try fix.transport.feed(.linkRefused(PresentationLinkRefusal(reason: .hidden, click: refused)))

        XCTAssertEqual(fix.launches.runs.count, 1)
        XCTAssertEqual(fix.session.hudSpec?.message, "agent")
        XCTAssertTrue(fix.server.remoteOpeners.isIdle)
    }

    func testTwoOutstandingClicksAreAnsweredEachWithItsOwnFile() async throws {
        let fix = try connected(files: ["a.md": Data("# a\n".utf8), "b.md": Data("# bee\n".utf8)])
        let first = try book(fix, "./a.md")
        let second = try book(fix, "./b.md")

        try offer(fix, click: second, name: "b.md", size: 6)
        try offer(fix, click: first, name: "a.md", size: 4)
        try await waitUntil { fix.launches.runs.count == 2 }

        let copies = try fix.launches.runs.map { try String(contentsOf: URL(fileURLWithPath: $0.path), encoding: .utf8) }
        XCTAssertEqual(Set(copies), ["# a\n", "# bee\n"])
        XCTAssertTrue(fix.server.remoteOpeners.isIdle)
    }

    func testAReadShorterOrLongerThanTheOfferFailsAndRunsNothing() async throws {
        for size in [12, 4] {
            let fix = try connected(files: ["notes.md": Data("# notes\n".utf8)])
            let click = try book(fix, "./notes.md")

            try offer(fix, click: click, name: "notes.md", size: size)
            try await waitUntil { fix.session.hudActive }

            XCTAssertEqual(fix.session.hudSpec?.message, RemoteLinkRefusal.snapshotFailed.message(host: "buildbox"))
            XCTAssertTrue(fix.launches.runs.isEmpty)
            XCTAssertEqual(try stagedCopies(fix), [])
            XCTAssertTrue(fix.server.remoteOpeners.isIdle)
        }
    }

    func testAnOfferForAnotherClickNameOrPastItsPagesCapOpensNoConnection() async throws {
        let fix = try connected(files: ["notes.md": Data("# notes\n".utf8)])
        let click = try book(fix, "./notes.md")

        try offer(fix, click: UUID(), name: "notes.md", size: 8)
        try offer(fix, click: click, name: "other.md", size: 8)
        try offer(fix, click: click, name: "notes.md", size: MarkdownPage.maxBytes + 1)
        try offer(fix, click: click, name: "../notes.md", size: 8)

        XCTAssertTrue(fix.launcher.launches.isEmpty)
        XCTAssertTrue(fix.launches.runs.isEmpty)
        XCTAssertFalse(fix.server.remoteOpeners.isIdle)
    }

    func testAStreamEndingMidTransferRunsNothingLeavesNoCopyAndReportsNothing() async throws {
        let fix = try connected(files: ["notes.md": Data("# notes\n".utf8)], held: ["notes.md"])
        let click = try book(fix, "./notes.md")
        try offer(fix, click: click, name: "notes.md", size: 8)
        try await waitUntil { fix.launcher.origins.first?.received.isEmpty == false }

        fix.server.stopRemotePresentation(fix.session.id)
        try await settle()

        XCTAssertTrue(fix.launches.runs.isEmpty)
        XCTAssertEqual(try stagedCopies(fix), [])
        XCTAssertTrue(fix.server.remoteOpeners.isIdle)
        XCTAssertFalse(fix.session.hudActive)
    }

    func testATransferPastTheReadDeadlineFailsOnceAndRunsNothing() async throws {
        let fix = try connected(files: ["notes.md": Data("# notes\n".utf8)], held: ["notes.md"])
        let click = try book(fix, "./notes.md")
        try offer(fix, click: click, name: "notes.md", size: 8)
        try await waitUntil { fix.launcher.origins.first?.received.isEmpty == false }

        fix.clock.now = fix.clock.now.addingTimeInterval(PendingOpenerClicks.readDeadline)
        fix.server.tickRemoteOpeners()
        XCTAssertFalse(fix.session.hudActive)
        fix.clock.now = fix.clock.now.addingTimeInterval(1)
        fix.server.tickRemoteOpeners()
        try await settle()

        XCTAssertEqual(fix.session.hudSpec?.message, RemoteLinkRefusal.snapshotFailed.message(host: "buildbox"))
        XCTAssertTrue(fix.launches.runs.isEmpty)
        XCTAssertTrue(fix.server.remoteOpeners.isIdle)
    }

    func testClicksNoSnapshotAnsweredExpireWithoutLeavingState() throws {
        let fix = try connected(files: [:])
        _ = try book(fix, "./a.md")
        _ = try book(fix, "./b.md")
        XCTAssertFalse(fix.server.remoteOpeners.isIdle)

        fix.clock.now = fix.clock.now.addingTimeInterval(PendingOpenerClicks.window + 1)
        fix.server.tickRemoteOpeners()

        XCTAssertTrue(fix.server.remoteOpeners.isIdle)
        XCTAssertFalse(fix.session.hudActive)
    }

    func testARefusalNamingABookedClickRetiresItAndShowsOnePanel() throws {
        let fix = try connected(files: [:])
        let click = try book(fix, "./notes.md")

        try fix.transport.feed(.linkRefused(PresentationLinkRefusal(reason: .notFound, click: click)))

        XCTAssertTrue(fix.server.remoteOpeners.isIdle)
        XCTAssertEqual(fix.session.hudSpec?.message, RemoteLinkRefusal.notFound.message(host: "buildbox"))
    }

    private func connected(files: [String: Data], chunkSize: Int = 1024, held: Set<String> = []) throws -> Fixture {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let library = WindowLibrary(directory: stateDir.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let server = ControlServer(
            library: library,
            actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "9.9.9"),
            socketPath: "/tmp/agterm-ro-\(UUID().uuidString.prefix(8)).sock"
        )
        servers.append(server)
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "s1",
                                       daemonsByLocalPane: [session.paneIdentity: ZmxSupport.daemonName(for: Self.remoteLeft)],
                                       presentationVersion: 1), forSession: session.id)
        let launcher = FakePageLauncher(files: files.mapValues { ("application/octet-stream", $0) })
        launcher.chunkSize = chunkSize
        launcher.held = held
        server.pageLauncher = launcher
        let clock = Clock()
        let staging = stateDir.appendingPathComponent("open-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let launches = Launches()
        let openers = server.remoteOpeners
        openers.now = { clock.now }
        openers.rules = { parseKeymap("open *.md mdview").0.openers }
        openers.staging = OpenerStaging(root: staging, now: { Date() })
        openers.launch = { rule, file, surface, host in
            launches.runs.append((rule.command.name, file.path, surface, host))
            return launches.refusal
        }
        let transport = FakePresentationTransport()
        server.remoteTransport = transport
        server.startRemotePresentation(for: session)
        try transport.feed(.hello(PresentationHello(version: 1, kinds: [PresentationHub.linkClickKind,
                                                                         PresentationHub.linkSnapshotKind], mode: .presenter)))
        try transport.feed(.presenterGranted)
        let surface = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat")
        return Fixture(server: server, session: session, transport: transport, launcher: launcher, launches: launches,
                       surface: surface, staging: staging, clock: clock)
    }

    private func book(_ fix: Fixture, _ raw: String) throws -> UUID {
        let click = RemoteLinkClick(raw: raw, session: fix.session.id, pane: fix.session.paneIdentity, mode: .overlay)
        XCTAssertNil(fix.server.forwardRemoteLinkClick(click, surface: fix.surface))
        return try XCTUnwrap(fix.transport.clicks.last?.click)
    }

    private func offer(_ fix: Fixture, click: UUID, name: String, size: Int) throws {
        try fix.transport.feed(.linkSnapshot(PresentationLinkSnapshot(click: click, token: "tok-\(name)", name: name, size: size)))
    }

    private func stagedCopies(_ fix: Fixture) throws -> [String] {
        guard FileManager.default.fileExists(atPath: fix.staging.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: fix.staging.path)
    }

    private func settle() async throws {
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not reached") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
