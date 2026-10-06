import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RemoteAttachTests: XCTestCase {
    private var stateDir: URL!
    private var configDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var attacher: FakeAttacher!
    private var controller: PickController!
    private var windowID: WindowInfo.ID!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-remote-attach-\(UUID().uuidString)", isDirectory: true)
        configDir = stateDir.appendingPathComponent("cfg", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try SettingsStore(directory: stateDir).save(AppSettings(configDirectory: configDir.path))
        library = WindowLibrary(directory: stateDir)
        attacher = FakeAttacher()
        actions = AppActions(library: library)
        actions.settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        actions.remoteAttacher = attacher
        windowID = try XCTUnwrap(library.activeWindowID)
        controller = PickController()
        PickRegistry.shared.register(windowID, controller: controller)
    }

    override func tearDown() async throws {
        PickRegistry.shared.unregister(windowID)
        actions = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private var remotesFile: URL { configDir.appendingPathComponent("remotes.conf") }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), what)
    }

    private func listing(_ sessions: [ControlRemoteSession]) -> ControlResponse {
        let endpoint = ControlZmxEndpoint(executable: "/zmx", socketDirectory: "/tmp/zmx")
        return ControlResponse(ok: true, result: ControlResult(
            remote: ControlRemoteTree(host: "studio", endpoint: endpoint, sessions: sessions)))
    }

    private let build = ControlRemoteSession(
        id: "s1", name: "build", windowID: "w1", windowName: "main", workspaceID: "ws1", workspaceName: "work",
        context: "release prep", cwd: "/repo", splitAxis: nil,
        panes: [ControlRemotePane(pane: "left", daemon: "d1", foreground: ["/usr/bin/vim", "a.txt"])])

    private func waitForRemotes(_ expected: [String], _ what: String) async {
        let deadline = Date().addingTimeInterval(5)
        while actions.configuredRemotes.map(\.destination) != expected, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(actions.configuredRemotes.map(\.destination), expected, what)
    }

    func testConfiguredRemotesFollowEveryKindOfEditWithoutAReload() async throws {
        XCTAssertTrue(actions.configuredRemotes.isEmpty, "no file lists nothing")

        try "studio Mac Studio\n-bad\n".write(to: remotesFile, atomically: true, encoding: .utf8)
        await waitForRemotes(["studio"], "a created file")
        XCTAssertEqual(actions.configuredRemotes.map(\.label), ["Mac Studio"])

        let handle = try FileHandle(forWritingTo: remotesFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("mini\n".utf8))
        try handle.close()
        await waitForRemotes(["studio", "mini"], "an in-place append")

        try "mini\n".write(to: remotesFile, atomically: true, encoding: .utf8)
        await waitForRemotes(["mini"], "an atomic replace")

        try "mini\nstudio\n".write(to: remotesFile, atomically: true, encoding: .utf8)
        await waitForRemotes(["mini", "studio"], "a second replace, on the re-armed descriptor")

        try FileManager.default.removeItem(at: remotesFile)
        await waitForRemotes([], "a deleted file")
    }

    func testConfiguredRemotesFollowAConfigDirectoryCreatedLaterAndAChangedOne() async throws {
        let later = stateDir.appendingPathComponent("later/nested", isDirectory: true)
        actions.settingsModel?.setConfigDirectory(later.path)
        XCTAssertTrue(actions.configuredRemotes.isEmpty)

        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        try "studio\n".write(to: later.appendingPathComponent("remotes.conf"), atomically: true, encoding: .utf8)
        await waitForRemotes(["studio"], "a file in a directory that did not exist")

        try "mini\n".write(to: remotesFile, atomically: true, encoding: .utf8)
        actions.settingsModel?.setConfigDirectory(configDir.path)
        await waitForRemotes(["mini"], "the file of the directory switched to")
    }

    private func writeRemotes(_ text: String, expecting destinations: [String]) async throws {
        try text.write(to: remotesFile, atomically: true, encoding: .utf8)
        await waitForRemotes(destinations, "the watcher picks the file up")
    }

    func testSeveralRemotesAskWhichMacInThePickerThenListIt() async throws {
        try await writeRemotes("studio Mac Studio\nmini\n", expecting: ["studio", "mini"])

        actions.attachRemote()
        await waitUntil("the machine picker opens") { controller.pending != nil }

        let pick = try XCTUnwrap(controller.pending)
        XCTAssertEqual(pick.prompt, "Attach from which Mac?")
        XCTAssertEqual(pick.items, [ControlPickItem(id: "studio", label: "Mac Studio", subtitle: "studio"),
                                    ControlPickItem(id: "mini", label: "mini")])
        XCTAssertTrue(attacher.treeHosts.isEmpty, "nothing is contacted before a machine is chosen")
        controller.resolve(ControlPickResult(result: .picked, id: "mini", label: "mini", index: 1))
        await waitUntil("the chosen machine is listed") { attacher.treeHosts == ["mini"] }
        await finishListing()
    }

    func testAWindowSwitchWhileChoosingTheMacKeepsTheAttachInTheStartingWindow() async throws {
        try await writeRemotes("studio\nmini\n", expecting: ["studio", "mini"])
        let session = try XCTUnwrap(library.activeStore?.selectedSessionID?.uuidString)
        let other = library.newWindow(name: "other").id
        _ = library.loadStore(for: other)
        library.frontmostWindowID = windowID

        actions.attachRemote()
        await waitUntil("the machine picker opens") { controller.pending != nil }
        library.frontmostWindowID = other
        controller.resolve(ControlPickResult(result: .picked, id: "studio", label: "studio", index: 0))
        await waitUntil("the listing starts") { attacher.treeHosts == ["studio"] }

        guard case let .opened(hudSession, hudWindow, _) = attacher.huds.first else { return XCTFail("expected a progress panel") }
        XCTAssertEqual(hudSession, session)
        XCTAssertEqual(hudWindow, windowID.uuidString)
        attacher.answerTree(listing([build]))
        await waitUntil("the session picker opens in the starting window") { controller.pending?.items.first?.id == "s1" }
        controller.resolve(ControlPickResult(result: .picked, id: "s1", label: "build", index: 0))
        await waitUntil("the attach is requested") { attacher.attaches.count == 1 }
        XCTAssertEqual(attacher.attaches.first?.window, windowID.uuidString)
    }

    private func finishListing() async {
        attacher.answerTree(listing([]))
        await waitUntil("the flow ends") { attacher.huds.count >= 2 }
    }

    func testDismissingTheMachinePickerContactsNothing() async throws {
        try await writeRemotes("studio\nmini\n", expecting: ["studio", "mini"])

        actions.attachRemote()
        await waitUntil("the machine picker opens") { controller.pending != nil }
        controller.cancel()
        for _ in 0..<200 { await Task.yield() }

        XCTAssertFalse(controller.modalPending)
        XCTAssertTrue(attacher.treeHosts.isEmpty)
        XCTAssertTrue(attacher.huds.isEmpty)
    }

    func testASingleRemoteIsListedWithoutAsking() async throws {
        try await writeRemotes("studio Mac Studio\n", expecting: ["studio"])

        actions.attachRemote()

        await waitUntil("the listing starts") { attacher.treeHosts == ["studio"] }
        XCTAssertNil(controller.pending)
        await finishListing()
    }

    func testNoRemotesDoesNothing() async {
        actions.attachRemote()
        for _ in 0..<200 { await Task.yield() }

        XCTAssertFalse(controller.modalPending)
        XCTAssertTrue(attacher.treeHosts.isEmpty)
    }

    func testAttachListsTheMachineAndAttachesThePickedSessionInTheStartingWindow() async throws {
        let other = library.newWindow(name: "other").id
        _ = library.loadStore(for: other)
        library.frontmostWindowID = windowID

        let session = try XCTUnwrap(library.activeStore?.selectedSessionID?.uuidString)

        actions.attachRemote("studio", in: windowID)
        await waitUntil("the listing starts") { attacher.treeHosts == ["studio"] }
        XCTAssertEqual(attacher.huds, [.opened(session: session, window: windowID.uuidString,
                                               spec: HudSpec(message: "Attach Remote: listing sessions on studio…",
                                                             spinner: .bar, hideAfter: 30))])
        library.frontmostWindowID = other
        attacher.answerTree(listing([build]))
        await waitUntil("the session picker opens") { controller.pending != nil }

        XCTAssertEqual(attacher.huds.last, .closed(session: session, window: windowID.uuidString),
                       "the progress panel is gone before the picker shows")
        let pick = try XCTUnwrap(controller.pending)
        XCTAssertEqual(pick.prompt, "Attach from studio")
        XCTAssertEqual(pick.items, [ControlPickItem(id: "s1", label: "build",
                                                    subtitle: "main/work  ·  release prep  ·  /repo  ·  vim")])
        controller.resolve(ControlPickResult(result: .picked, id: "s1", label: "build", index: 0))
        await waitUntil("the attach is requested") { attacher.attaches.count == 1 }

        XCTAssertEqual(attacher.attaches.first, FakeAttacher.Attach(host: "studio", session: "s1", window: windowID.uuidString))
        XCTAssertFalse(controller.modalPending)
        await waitUntil("the attach panel closes") { attacher.huds.count == 4 }
        XCTAssertEqual(Array(attacher.huds.suffix(2)), [
            .opened(session: session, window: windowID.uuidString,
                    spec: HudSpec(message: "Attach Remote: attaching build…", spinner: .bar, hideAfter: 30)),
            .closed(session: session, window: windowID.uuidString),
        ])
    }

    func testAFailedOrEmptyListingShowsATimedErrorPanelAndNoPicker() async throws {
        let session = try XCTUnwrap(library.activeStore?.selectedSessionID?.uuidString)
        let answers = [(ControlResponse(ok: false, error: "ssh: \u{1b}[31mconnection refused\u{1b}[0m"),
                        "Attach Remote: studio: ssh: connection refused"),
                       (listing([]), "Attach Remote: nothing to attach on studio")]
        for (index, answer) in answers.enumerated() {
            actions.attachRemote("studio", in: windowID)
            await waitUntil("listing \(index) starts") { attacher.treeHosts.count == index + 1 }
            attacher.answerTree(answer.0, call: index)
            await waitUntil("the error panel shows") { attacher.huds.count == 2 * (index + 1) }

            XCTAssertEqual(attacher.huds.last, .opened(session: session, window: windowID.uuidString,
                                                       spec: HudSpec(message: answer.1, hideAfter: 5)))
            XCTAssertFalse(controller.modalPending)
            XCTAssertTrue(attacher.attaches.isEmpty)
        }
    }

    func testARefusedAttachShowsATimedErrorPanel() async throws {
        attacher.attachResponse = ControlResponse(ok: false, error: "no attachable session s1 on studio")

        actions.attachRemote("studio", in: windowID)
        await waitUntil("the listing starts") { attacher.treeHosts.count == 1 }
        attacher.answerTree(listing([build]))
        await waitUntil("the session picker opens") { controller.pending != nil }
        controller.resolve(ControlPickResult(result: .picked, id: "s1", label: "build", index: 0))
        await waitUntil("the error panel shows") { attacher.huds.count == 4 }

        guard case let .opened(_, _, spec) = attacher.huds.last else { return XCTFail("expected an error panel") }
        XCTAssertEqual(spec, HudSpec(message: "Attach Remote: no attachable session s1 on studio", hideAfter: 5))
    }

    func testAnAttachLeavesAHudAnotherCallerPostedDuringItsWaitAlone() async throws {
        let session = try XCTUnwrap(library.activeStore?.selectedSessionID?.uuidString)

        actions.attachRemote("studio", in: windowID)
        await waitUntil("the listing starts") { attacher.treeHosts.count == 1 }
        let foreign = HudSpec(message: "an agent's own panel")
        _ = attacher.openHud(session, window: nil, spec: foreign)
        attacher.answerTree(listing([build]))
        await waitUntil("the session picker opens") { controller.pending != nil }

        XCTAssertEqual(attacher.huds.last, .opened(session: session, window: nil, spec: foreign),
                       "the finished listing closed nothing")
        controller.cancel()
    }

    func testAnOverlongErrorIsCutToWhatAHudAccepts() async throws {
        actions.attachRemote("studio", in: windowID)
        await waitUntil("the listing starts") { attacher.treeHosts.count == 1 }
        attacher.answerTree(ControlResponse(ok: false, error: String(repeating: "q\u{301}", count: 400)))
        await waitUntil("the error panel shows") { attacher.huds.count == 2 }

        guard case let .opened(_, _, spec) = attacher.huds.last else { return XCTFail("expected an error panel") }
        XCTAssertLessThanOrEqual(spec.message.precomposedStringWithCanonicalMapping.unicodeScalars.count, HudSpec.maxTextLength)
    }

    func testDismissingThePickerAttachesNothing() async {
        actions.attachRemote("studio", in: windowID)
        await waitUntil("the listing starts") { attacher.treeHosts.count == 1 }
        attacher.answerTree(listing([build]))
        await waitUntil("the session picker opens") { controller.pending != nil }
        controller.cancel()
        for _ in 0..<200 { await Task.yield() }

        XCTAssertFalse(controller.modalPending)
        XCTAssertTrue(attacher.attaches.isEmpty)
    }

    func testAWindowClosedDuringTheListingGetsNoPicker() async {
        actions.attachRemote("studio", in: windowID)
        await waitUntil("the listing starts") { attacher.treeHosts.count == 1 }
        PickRegistry.shared.unregister(windowID)
        attacher.answerTree(listing([build]))
        for _ in 0..<200 { await Task.yield() }

        XCTAssertNil(controller.pending)
        XCTAssertTrue(attacher.attaches.isEmpty)
    }

    func testAttachDoesNothingWhileAModalHoldsTheWindow() async {
        XCTAssertTrue(controller.open(PendingPick(id: "busy", items: [ControlPickItem(id: "a", label: "A")])))

        actions.attachRemote("studio", in: windowID)
        for _ in 0..<200 { await Task.yield() }

        XCTAssertTrue(attacher.treeHosts.isEmpty)
        controller.cancel()
    }
}

@MainActor
private final class FakeAttacher: RemoteAttaching {
    struct Attach: Equatable {
        let host: String
        let session: String
        let window: String?
    }

    enum Hud: Equatable {
        case opened(session: String?, window: String?, spec: HudSpec)
        case closed(session: String?, window: String?)
    }

    private(set) var treeHosts: [String?] = []
    private(set) var attaches: [Attach] = []
    private(set) var huds: [Hud] = []
    private var generation: Int?
    private var opens = 0
    var attachResponse = ControlResponse(ok: true)
    private var trees: [CheckedContinuation<ControlResponse, Never>] = []

    func remoteTree(host: String?) async -> ControlResponse {
        treeHosts.append(host)
        return await withCheckedContinuation { trees.append($0) }
    }

    func attachRemoteSession(host: String, session: String, window: String?) async -> ControlResponse {
        attaches.append(Attach(host: host, session: session, window: window))
        return attachResponse
    }

    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        huds.append(.opened(session: target, window: window, spec: spec))
        opens += 1
        generation = opens
        return ControlResponse(ok: true)
    }

    func closeHud(_ target: String?, window: String?) -> ControlResponse {
        huds.append(.closed(session: target, window: window))
        generation = nil
        return ControlResponse(ok: true)
    }

    func hudGeneration(session: String) -> Int? { generation }

    func answerTree(_ response: ControlResponse, call: Int = 0) {
        trees[call].resume(returning: response)
    }
}
