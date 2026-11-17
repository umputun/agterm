import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerPasteTransferTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var runner: StubInputRunner!
    private var saved: PasteTransfer!
    private var covered: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = URL(fileURLWithPath: "/private/tmp/agterm-paste-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        library = WindowLibrary(directory: stateDir)
        server = ControlServer(library: library, actions: AppActions(library: library),
                               settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                               identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                               socketPath: stateDir.appendingPathComponent("control.sock").path)
        runner = StubInputRunner()
        saved = PasteTransfer.shared
        PasteTransfer.shared.staging = PasteStaging(root: stateDir.appendingPathComponent("paste"))
        PasteTransfer.shared.runner = runner
        PasteTransfer.shared.text = { [unowned self] offer, surface in await server.pasteText(offer, for: surface) }
    }

    override func tearDown() async throws {
        PasteTransfer.shared = saved
        covered.forEach(ZmxLeadBook.shared.forget)
        server = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    func testAnImagePastedIntoALocalPaneIsSavedAndItsPathInserted() async throws {
        let view = try pane(remoteHost: nil)

        let reason = await view.paste(PasteOffer(image: Self.png), drop: false).reason

        XCTAssertNil(reason)
        let staged = try XCTUnwrap(stagedFiles().first)
        XCTAssertEqual(try Data(contentsOf: staged), Self.png)
        XCTAssertTrue(staged.lastPathComponent.hasPrefix("clipboard-"))
        await waitFor("the staged path reaches the pane") { view.readScreenText(all: false, lines: nil)?.contains(staged.path) == true }
        XCTAssertTrue(runner.calls.isEmpty, "an image for a local program never leaves this Mac")
    }

    func testFilesPastedIntoARemotePaneInsertTheOriginPathsInOfferOrder() async throws {
        let view = try pane(remoteHost: "studio")
        let first = try file("a.txt"), second = try file("b c.txt")
        let web = try XCTUnwrap(URL(string: "https://example.com/x"))
        runner.reply = RemoteCommandResult(status: 0, stdout: #"{"paths":["/o/p/0/a.txt","/o/p/1/b c.txt"]}"#, stderr: "")

        let reason = await view.paste(PasteOffer(urls: [first, web, second]), drop: true).reason

        XCTAssertNil(reason)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertTrue(call.argv.contains("studio"))
        XCTAssertTrue(call.argv.last?.contains("exec agtermctl paste receive") == true)
        XCTAssertTrue(call.bundle.contains("b c.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: call.input.deletingLastPathComponent().path),
                       "the bundle's temporary folder goes once the copy answered")
        await waitFor("the origin paths reach the pane") {
            view.readScreenText(all: false, lines: nil)?.contains("/o/p/0/a.txt https://example.com/x /o/p/1/b\\ c.txt") == true
        }
    }

    func testARemoteImageInsertsTheOriginPath() async throws {
        let view = try pane(remoteHost: "studio")
        runner.reply = RemoteCommandResult(status: 0, stdout: #"{"paths":["/o/p/0/clipboard-1.png"]}"#, stderr: "")

        let text = await server.pasteText(PasteOffer(image: Self.png), for: view)

        XCTAssertEqual(text, .success("/o/p/0/clipboard-1.png"))
        XCTAssertTrue(stagedFiles().isEmpty, "an image for a remote program is saved on its origin only")
    }

    func testARunnerFailureInsertsNothingAndSaysWhy() async throws {
        let view = try pane(remoteHost: "studio")
        let shown = view.readScreenText(all: false, lines: nil)
        runner.reply = RemoteCommandResult(status: 255, stdout: "", stderr: "")

        let reason = await view.paste(PasteOffer(urls: [try file("a.txt")]), drop: false).reason

        XCTAssertEqual(reason, "the paste could not be copied (exit 255)")
        XCTAssertEqual(view.readScreenText(all: false, lines: nil), shown)
    }

    func testAShortReplyIsAFailureRatherThanAViewerPath() async throws {
        let view = try pane(remoteHost: "studio")
        runner.reply = RemoteCommandResult(status: 0, stdout: #"{"paths":["/o/p/0/a.txt"]}"#, stderr: "")

        let text = await server.pasteText(PasteOffer(urls: [try file("a.txt"), try file("b.txt")]), for: view)

        XCTAssertEqual(text, .failure(PasteFailure("the origin answered for a different paste")))
    }

    func testAPasteWhileACopyRunsIsRefusedBeforeTheClipboardIsRead() async throws {
        let view = try pane(remoteHost: "studio")
        runner.hold = true
        runner.reply = RemoteCommandResult(status: 0, stdout: #"{"paths":["/o/p/0/a.txt"]}"#, stderr: "")

        guard case .copying(let copy) = view.paste(PasteOffer(urls: [try file("a.txt")]), drop: false) else {
            return XCTFail("the first paste should be copying")
        }
        await waitFor("the copy reaches the runner") { runner.waiting }
        guard case .finished(let refusal) = view.pasteClipboard() else { return XCTFail("a second paste must not start") }
        XCTAssertEqual(refusal, PasteTransfer.stillCopying)
        runner.release()

        let reason = await copy.value
        XCTAssertNil(reason)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertFalse(view.pasteCopying)
    }

    func testAPaneAnotherMacLeadsCopiesNothingAndSaysWhy() async throws {
        let session = try remoteSession().session
        let view = realizedView(session: session, paneToken: session.paneIdentity)
        session.surface = view
        cover(session.paneIdentity)
        var refusals: [String] = []
        PasteTransfer.shared.refuse = { _, reason in refusals.append(reason) }
        preserveGeneralPasteboard()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([try file("a.txt") as NSURL])

        view.paste(nil)

        XCTAssertEqual(refusals, [PaneLead.coveredRefusal])
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    func testAPaneCoveredDuringTheCopyInsertsNothing() async throws {
        let session = try remoteSession().session
        let view = realizedView(session: session, paneToken: session.paneIdentity)
        session.surface = view
        let shown = view.readScreenText(all: false, lines: nil)
        runner.hold = true
        runner.reply = RemoteCommandResult(status: 0, stdout: #"{"paths":["/o/p/0/a.txt"]}"#, stderr: "")
        var refusals: [String] = []
        PasteTransfer.shared.refuse = { _, reason in refusals.append(reason) }

        guard case .copying(let copy) = view.paste(PasteOffer(urls: [try file("a.txt")]), drop: false) else {
            return XCTFail("the paste should be copying")
        }
        await waitFor("the copy reaches the runner") { runner.waiting }
        cover(session.paneIdentity)
        runner.release()

        let reason = await copy.value
        XCTAssertEqual(reason, PaneLead.coveredRefusal)
        XCTAssertEqual(refusals, [PaneLead.coveredRefusal])
        XCTAssertEqual(view.readScreenText(all: false, lines: nil), shown)
    }

    func testARefusedPasteIsShownOverItsRow() async throws {
        let session = try remoteSession().session
        let view = realizedView(session: session, paneToken: session.paneIdentity)
        session.surface = view
        cover(session.paneIdentity)
        PasteTransfer.shared.refuse = { [unowned self] surface, reason in server.reportPasteRefusal(reason, for: surface) }

        view.userPaste()

        XCTAssertEqual(session.hudSpec?.message, "Paste: \(PaneLead.coveredRefusal)")
    }

    func testSessionPasteAnswersTheCopysFailure() async throws {
        let (store, session) = try remoteSession()
        session.surface = realizedView(session: session)
        preserveGeneralPasteboard()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([try file("a.txt") as NSURL])
        runner.reply = RemoteCommandResult(status: 1, stdout: #"{"error":"too large to paste (limit 100 MB)"}"#, stderr: "")

        let response = await server.pasteSession(session.id.uuidString, window: nil, pane: nil)

        XCTAssertEqual(response.error, "too large to paste (limit 100 MB)")
        XCTAssertNotNil(store.session(withID: session.id))
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    private func pane(remoteHost: String?) throws -> GhosttySurfaceView {
        let session: Session
        if let remoteHost {
            session = try remoteSession(host: remoteHost).session
        } else {
            let store = try XCTUnwrap(library.activeStore)
            session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSTemporaryDirectory()))
        }
        let view = realizedView(session: session)
        session.surface = view
        return view
    }

    private func remoteSession(host: String = "studio") throws -> (store: AppStore, session: Session) {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSTemporaryDirectory(),
                                                     remoteHost: host))
        return (store, session)
    }

    private func cover(_ pane: UUID) {
        covered.append(pane)
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: pane)
        _ = ZmxLeadBook.shared.apply(ZmxLeadNotice(title: "zmx-role;n:follower:1")!, pane: pane)
    }

    private func realizedView(session: Session, paneToken: UUID? = nil) -> GhosttySurfaceView {
        let env = paneToken.map { ["AGTERM_PANE_ID": $0.uuidString] } ?? [:]
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: 12, command: "/bin/cat", env: env)
        view.session = session
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1800, height: 320), styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(view.isRealized)
        return view
    }

    private func file(_ name: String) throws -> URL {
        let url = stateDir.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func stagedFiles() -> [URL] {
        let root = stateDir.appendingPathComponent("paste")
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return (walk?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private func preserveGeneralPasteboard() {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        addTeardownBlock {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }
}

private final class StubInputRunner: RemoteInputCommandRunner, @unchecked Sendable {
    struct Call {
        let argv: [String]
        let input: URL
        let bundle: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holding = false
    private var answer = RemoteCommandResult(status: 0, stdout: "", stderr: "")

    var reply: RemoteCommandResult {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }
    var hold: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }
    var calls: [Call] { lock.withLock { recorded } }
    var waiting: Bool { lock.withLock { held != nil } }

    func run(_ argv: [String], deadline: TimeInterval, input: URL) async -> RemoteCommandResult {
        let bundle = String(decoding: (try? Data(contentsOf: input)) ?? Data(), as: UTF8.self)
        lock.withLock { recorded.append(Call(argv: argv, input: input, bundle: bundle)) }
        if hold { await withCheckedContinuation { continuation in lock.withLock { held = continuation } } }
        return reply
    }

    func release() {
        lock.withLock {
            held?.resume()
            held = nil
        }
    }
}
