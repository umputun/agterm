import Darwin
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerMacCatalogTests: XCTestCase {
    private final class Client: @unchecked Sendable {
        let fd: Int32
        private var buffer = Data()

        init?(path: String) {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return nil }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = path.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf in
                    bytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
                }
            }
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(descriptor, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard connected else {
                close(descriptor)
                return nil
            }
            var wait = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            fd = descriptor
        }

        func send(_ line: String) {
            let payload = Array((line + "\n").utf8)
            _ = payload.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
        }

        func readLine() -> String? {
            while true {
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return line
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }

        func frame() -> CatalogFrame? {
            readLine().flatMap { try? CatalogCodec.decode(Data($0.utf8)) }
        }
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    private var stateDir: URL!
    private var socketPath: String!
    private var server: ControlServer!
    private var library: WindowLibrary!
    private var clients: [Client] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-mac-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        socketPath = "/tmp/agterm-cat-\(UUID().uuidString.prefix(8)).sock"
        library = WindowLibrary(directory: stateDir)
        server = ControlServer(library: library, actions: AppActions(library: library),
                               settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                               identity: AppIdentity(version: "9.9.9"), socketPath: socketPath)
        server.originLiveActive = { true }
        server.start()
        XCTAssertNotNil(server.boundSocketPath)
    }

    override func tearDown() async throws {
        for client in clients { close(client.fd) }
        clients.removeAll()
        server.stop()
        unlink(socketPath)
        unlink(socketPath + ".lock")
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let done = expectation(description: "client work finished")
        let box = Box<T>()
        Thread {
            box.value = body()
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 10)
        return box.value
    }

    private func window() throws -> UUID { try XCTUnwrap(library.activeWindowID) }

    private func session() throws -> Session {
        try XCTUnwrap(library.store(for: try window())?.workspaces.first?.sessions.first)
    }

    private func subscribe(window: String) throws -> (Client, [CatalogFrame]) {
        let client = try XCTUnwrap(Client(path: socketPath))
        clients.append(client)
        let hello = String(decoding: try CatalogCodec.encode(.hello(CatalogHello(version: 1, pageRows: true, window: window))), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let frames = offMain { () -> (String?, CatalogFrame?, CatalogFrame?) in
            client.send(#"{"cmd":"catalog.subscribe"}"#)
            let reply = client.readLine()
            client.send(hello)
            let first = client.frame()
            return (reply, first, first.flatMap { if case .hello = $0 { client.frame() } else { nil } })
        }
        let (reply, first, second) = try XCTUnwrap(frames)
        XCTAssertTrue(try XCTUnwrap(reply).contains(#""ok":true"#), reply ?? "")
        return (client, [first, second].compactMap { $0 })
    }

    private func request(_ line: String) throws -> ControlResponse {
        let client = try XCTUnwrap(Client(path: socketPath))
        clients.append(client)
        let reply = offMain { () -> String? in
            client.send(line)
            return client.readLine()
        }
        return try JSONDecoder().decode(ControlResponse.self, from: Data(try XCTUnwrap(reply ?? nil).utf8))
    }

    private func rename(_ session: Session, to name: String, opID: String, window: UUID) throws -> ControlResponse {
        try request(#"{"cmd":"session.rename","target":"\#(session.id.uuidString)","args":{"name":"\#(name)","opID":"\#(opID)","#
            + #""epoch":"\#(server.originEpoch)","window":"\#(window.uuidString)"}}"#)
    }

    private func rename(workspace: UUID, to name: String, opID: String, window: UUID) throws -> ControlResponse {
        try request(#"{"cmd":"workspace.rename","target":"\#(workspace.uuidString)","args":{"name":"\#(name)","opID":"\#(opID)","#
            + #""epoch":"\#(server.originEpoch)","window":"\#(window.uuidString)"}}"#)
    }

    private func workspace(in window: UUID) throws -> Workspace {
        try XCTUnwrap(library.store(for: window)?.workspaces.first)
    }

    func testAHelloForAWindowGetsItsCatalogAndARowOnceItsPaneRuns() throws {
        let window = try window()
        let session = try session()

        let (client, frames) = try subscribe(window: window.uuidString)

        guard frames.count == 2, case .hello = frames[0], case .snapshot(let snapshot) = frames[1] else {
            return XCTFail("expected hello then a snapshot, got \(frames)")
        }
        XCTAssertEqual(snapshot.catalogID, window)
        XCTAssertEqual(snapshot.workspaces.flatMap(\.sessions).count, 0, "a pane not running yet is not listed")
        XCTAssertEqual(server.buildWindowList().first { $0.id == window.uuidString }?.catalogViewers, 1)
        XCTAssertEqual(try server.buildTree(in: XCTUnwrap(library.store(for: window))).catalogViewers, 1)

        server.originCatalogs[window]?.projection.evidence = CatalogPaneEvidence(running: [session.paneIdentity])

        let delta = offMain { client.frame() } ?? nil
        guard case .delta(_, _, .sessionAdded(let added, _, _))? = delta else { return XCTFail("expected the row, got \(String(describing: delta))") }
        XCTAssertEqual(added.id, session.id)
    }

    func testWithoutLiveSessionsAHelloIsRefusedForGood() throws {
        server.originLiveActive = { false }

        let (_, frames) = try subscribe(window: try window().uuidString)

        guard case .refused(let reason, let final)? = frames.first else { return XCTFail("expected a refusal, got \(frames)") }
        XCTAssertTrue(final)
        XCTAssertTrue(reason.hasSuffix("does not run Live sessions, which a remote window needs"), reason)
    }

    func testAnOperationBeforeAnySubscribeRunsInItsWindowWithAReceipt() throws {
        let window = try window()
        let workspace = try workspace(in: window)

        let response = try rename(workspace: workspace.id, to: "renamed", opID: "op-1", window: window)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.receipt?.outcome, .applied)
        XCTAssertEqual(try self.workspace(in: window).name, "renamed")
    }

    func testAnOperationOnAnotherWindowsRowIsRefused() throws {
        let session = try session()
        let other = library.newWindow(name: "other")

        let response = try rename(session, to: "renamed", opID: "op-1", window: other.id)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no session \(session.id.uuidString) in this window")
        XCTAssertNotEqual(session.customName, "renamed")
    }

    func testClosingTheWindowEndsItsStreamAndReopeningKeepsItsReceipts() throws {
        let window = try window()
        let workspace = try workspace(in: window)
        _ = library.newWindow(name: "keeps the app open")
        let (client, _) = try subscribe(window: window.uuidString)
        XCTAssertTrue(try rename(workspace: workspace.id, to: "renamed", opID: "op-1", window: window).ok)

        library.closeWindow(window)

        let ended = offMain { () -> CatalogFrame? in
            while let frame = client.frame() {
                if case .refused = frame { return frame }
            }
            return nil
        } ?? nil
        guard case .refused(let reason, let final)? = ended else { return XCTFail("expected a refusal, got \(String(describing: ended))") }
        XCTAssertFalse(final)
        XCTAssertTrue(reason.hasPrefix("window "), reason)
        XCTAssertTrue(reason.contains(" is closed on "), reason)

        let reopened = try XCTUnwrap(library.loadStore(for: window))
        let repeated = try rename(workspace: workspace.id, to: "again", opID: "op-1", window: window)
        XCTAssertEqual(repeated.result?.receipt?.outcome, .applied)
        XCTAssertEqual(reopened.workspaces.first?.name, "renamed", "a repeated id answers without running again")
    }

    func testCatalogOpAnswersARecordedOperationForItsWindow() throws {
        let window = try window()
        XCTAssertTrue(try rename(workspace: try workspace(in: window).id, to: "renamed", opID: "op-1", window: window).ok)

        let asked = try request(#"{"cmd":"catalog.op","target":"op-1","args":{"window":"\#(window.uuidString)"}}"#)

        XCTAssertTrue(asked.ok, asked.error ?? "")
        XCTAssertEqual(asked.result?.receipt?.outcome, .applied)
    }

    func testANewSessionAnswersWithItsIdAndLeavesTheSelectionAlone() throws {
        let window = try window()
        let store = try XCTUnwrap(library.store(for: window))
        let selected = store.selectedSessionID
        let workspace = try workspace(in: window)

        let response = try request(#"{"cmd":"session.new","args":{"workspace":"\#(workspace.id.uuidString)","opID":"op-1","#
            + #""epoch":"\#(server.originEpoch)","window":"\#(window.uuidString)"}}"#)

        XCTAssertTrue(response.ok, response.error ?? "")
        let id = try XCTUnwrap(response.result?.id.flatMap(UUID.init(uuidString:)))
        XCTAssertNotNil(store.session(withID: id))
        XCTAssertEqual(store.selectedSessionID, selected)
    }

    func testANewWorkspaceIsAppliedAtOnce() throws {
        let window = try window()

        let response = try request(#"{"cmd":"workspace.new","args":{"name":"fresh","opID":"op-1","#
            + #""epoch":"\#(server.originEpoch)","window":"\#(window.uuidString)"}}"#)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.receipt?.outcome, .applied)
        XCTAssertEqual(library.store(for: window)?.workspaces.last?.name, "fresh")
    }

    private func operation(_ cmd: String, target: String? = nil, args: String = "", opID: String, window: UUID) throws -> ControlResponse {
        let targetField = target.map { #""target":"\#($0)","# } ?? ""
        return try request(#"{"cmd":"\#(cmd)",\#(targetField)"args":{\#(args)"opID":"\#(opID)","#
            + #""epoch":"\#(server.originEpoch)","window":"\#(window.uuidString)"}}"#)
    }

    func testUndoAndRecentClosedFromAnotherMacLeaveTheOriginSelectionAlone() throws {
        let window = try window()
        let store = try XCTUnwrap(library.store(for: window))
        let kept = try session()
        let workspace = try workspace(in: window)
        let undone = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let reopened = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.selectSession(kept.id)
        var selections: [String?] = []
        let hooks = library.onControlEvent
        defer { library.onControlEvent = hooks }
        library.onControlEvent = { event in
            hooks?(event)
            if event.kind == .sessionSelected { selections.append(event.session) }
        }

        let closed = try operation("session.close", target: undone.id.uuidString, args: #""undoable":true,"#, opID: "op-1", window: window)
        let undoID = try XCTUnwrap(closed.result?.undoID, closed.error ?? "")
        XCTAssertTrue(try operation("session.undo", target: undoID, opID: "op-2", window: window).ok)
        let hard = try operation("session.close", target: reopened.id.uuidString, opID: "op-3", window: window)
        let recentID = try XCTUnwrap(hard.result?.recentID, hard.error ?? "")
        XCTAssertTrue(try operation("recent.open", target: recentID, opID: "op-4", window: window).ok)

        XCTAssertNotNil(store.session(withID: undone.id))
        XCTAssertNotNil(store.session(withID: reopened.id))
        XCTAssertEqual(store.selectedSessionID, kept.id)
        XCTAssertEqual(selections, [])
    }

    func testReopeningACompanionFromAnotherMacNamesTheParentItBroughtBack() throws {
        let window = try window()
        let store = try XCTUnwrap(library.store(for: window))
        let parent = try XCTUnwrap(store.addSession(toWorkspace: workspace(in: window).id, cwd: "/tmp"))
        let companion = try store.addCompanion(to: parent.id).get()
        let closed = try operation("session.close", target: companion.id.uuidString, opID: "op-1", window: window)
        let recentID = try XCTUnwrap(closed.result?.recentID, closed.error ?? "")
        XCTAssertTrue(try operation("session.close", target: parent.id.uuidString, opID: "op-2", window: window).ok)

        let reopened = try operation("recent.open", target: recentID, opID: "op-3", window: window)

        XCTAssertTrue(reopened.ok, reopened.error ?? "")
        XCTAssertEqual(reopened.result?.recentOpen?.item.sessionIDs, [companion.id.uuidString])
        XCTAssertEqual(reopened.result?.recentOpen?.restored, [parent.id.uuidString, companion.id.uuidString])
    }

    func testConvertingFromAnotherMacLeavesTheOriginSelectionAlone() throws {
        let window = try window()
        let store = try XCTUnwrap(library.store(for: window))
        let kept = try session()
        let converted = try XCTUnwrap(store.addSession(toWorkspace: workspace(in: window).id, cwd: "/tmp"))
        store.selectSession(kept.id)
        var selections: [String?] = []
        let hooks = library.onControlEvent
        defer { library.onControlEvent = hooks }
        library.onControlEvent = { event in
            hooks?(event)
            if event.kind == .sessionSelected { selections.append(event.session) }
        }

        let response = try operation("session.companion.convert", target: converted.id.uuidString, opID: "op-1", window: window)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNotNil(converted.parentID)
        XCTAssertEqual(response.result?.parent, converted.parentID?.uuidString)
        XCTAssertEqual(store.selectedSessionID, kept.id)
        XCTAssertEqual(selections, [])
    }

    func testARecentClearFromAnotherMacEmptiesOnlyItsWindow() throws {
        let window = try window()
        let store = try XCTUnwrap(library.store(for: window))
        let closing = try XCTUnwrap(store.addSession(toWorkspace: workspace(in: window).id, cwd: "/tmp"))
        let other = library.newWindow(name: "other").id
        let otherStore = try XCTUnwrap(library.loadStore(for: other))
        let kept = try XCTUnwrap(otherStore.workspaces.first?.sessions.first)
        XCTAssertTrue(try operation("session.close", target: closing.id.uuidString, opID: "op-1", window: window).ok)
        XCTAssertTrue(try request(#"{"cmd":"session.close","target":"\#(kept.id.uuidString)","args":{"window":"\#(other.uuidString)"}}"#).ok)

        let cleared = try operation("recent.clear", opID: "op-2", window: window)

        XCTAssertTrue(cleared.ok, cleared.error ?? "")
        XCTAssertTrue(library.recentClosedItems(inWindow: window).isEmpty)
        XCTAssertEqual(library.recentClosedItems(inWindow: other).compactMap(\.session?.snapshot.id), [kept.id])
    }

    func testASplitFromAnotherMacLeavesTheOriginsPaneFocus() throws {
        let window = try window()
        let store = try XCTUnwrap(library.store(for: window))
        let session = try session()
        store.selectSession(session.id)

        let response = try operation("session.split", target: session.id.uuidString, args: #""mode":"on","#, opID: "op-1", window: window)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertTrue(session.isSplit)
        XCTAssertFalse(session.splitFocused)
    }

    func testClearFlaggedFromAnotherMacClearsTheWindowsFlags() throws {
        let window = try window()
        let session = try session()
        session.flagged = true

        let response = try operation("session.flag", target: "active", args: #""mode":"clear","#, opID: "op-1", window: window)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertFalse(session.flagged)
    }

    func testClosingTheOriginsSelectedRowFromAnotherMacReselects() throws {
        let window = try window()
        let store = try XCTUnwrap(library.store(for: window))
        let kept = try session()
        let workspace = try workspace(in: window)
        let closing = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.selectSession(closing.id)

        XCTAssertTrue(try operation("session.close", target: closing.id.uuidString, opID: "op-1", window: window).ok)

        XCTAssertNil(store.session(withID: closing.id))
        XCTAssertEqual(store.selectedSessionID, kept.id)
    }

    func testANewWorkspaceFromAnotherMacStaysOutOfTheOriginFocusSet() throws {
        let window = try window()
        let store = try XCTUnwrap(library.store(for: window))
        let member = try workspace(in: window)
        store.setFocusMembership(member.id, member: true)
        store.setFocusEnabled(true)

        XCTAssertTrue(try operation("workspace.new", args: #""name":"fresh","#, opID: "op-1", window: window).ok)

        XCTAssertEqual(store.focusedWorkspaceIDs, [member.id])
        XCTAssertTrue(store.focusEnabled)
    }

    func testAWorkspaceDeleteWithoutATargetIsRefused() throws {
        let window = try window()

        let response = try operation("workspace.delete", opID: "op-1", window: window)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "workspace.delete from a remote window names its target")
        XCTAssertNotNil(library.store(for: window)?.workspaces.first)
    }

    func testAnAcknowledgedMessageClearsItsCountInTheCatalog() throws {
        let window = try window()
        let session = try session()
        let pane = session.paneIdentity
        defer { MessageBus.shared.dispose(pane: pane) }
        let (client, _) = try subscribe(window: window.uuidString)
        let catalog = try XCTUnwrap(server.originCatalogs[window])
        catalog.projection.evidence = CatalogPaneEvidence(running: [pane])
        _ = offMain { client.frame() }
        let mail = { () -> Int?? in
            guard case .delta(_, _, .paneChanged(let changed, _))? = self.offMain({ client.frame() }) ?? nil else { return nil }
            return .some(changed.pendingMessages)
        }

        try MessageBus.shared.send("hi", from: nil, to: [MessageRecipient(pane: pane, address: "test")], now: 0)
        XCTAssertEqual(mail(), .some(1))

        _ = MessageBus.shared.readAndAck(pane: pane)
        XCTAssertEqual(mail(), .some(nil))
    }

    func testAWindowNobodyMirrorsReportsNoViewers() throws {
        let window = try window()
        XCTAssertNil(server.buildWindowList().first { $0.id == window.uuidString }?.catalogViewers)
        XCTAssertNil(try server.buildTree(in: XCTUnwrap(library.store(for: window))).catalogViewers)
    }

    func testVersionAdvertisesTheMacCatalog() throws {
        let response = try request(#"{"cmd":"version"}"#)

        XCTAssertNil(response.result?.versions)
        XCTAssertEqual(response.result?.macCatalog?.catalog, CatalogCodec.version)
        XCTAssertEqual(response.result?.macCatalog?.protocolVersion, PresentationCodec.version)
        XCTAssertEqual(response.result?.macCatalog?.live, true)
    }

    func testVersionSaysWhenLiveSessionsAreOff() throws {
        server.originLiveActive = { false }

        let response = try request(#"{"cmd":"version"}"#)

        XCTAssertEqual(response.result?.macCatalog?.live, false)
    }

    func testANewWindowCatalogStartsFromTheLastPaneRead() throws {
        let window = try window()
        let session = try session()
        server.originEvidence = CatalogPaneEvidence(running: [session.paneIdentity])

        let (_, frames) = try subscribe(window: window.uuidString)

        guard frames.count == 2, case .snapshot(let snapshot) = frames[1] else { return XCTFail("expected hello then a snapshot, got \(frames)") }
        XCTAssertEqual(snapshot.workspaces.flatMap(\.sessions).map(\.id), [session.id])
    }

    func testASubscribeWhosePaneReadFailsIsRefusedForARetry() async throws {
        let other = WindowLibrary(directory: stateDir.appendingPathComponent("other", isDirectory: true))
        let path = "/tmp/agterm-cat-\(UUID().uuidString.prefix(8)).sock"
        let failing = ControlServer(library: other, actions: AppActions(library: other),
                                    settingsModel: SettingsModel(library: other, settingsStore: SettingsStore(directory: stateDir)),
                                    identity: AppIdentity(version: "9.9.9"),
                                    zmxClient: ZmxClient(executablePath: stateDir.appendingPathComponent("no-zmx").path,
                                                         socketDirectory: stateDir.path),
                                    socketPath: path)
        failing.originLiveActive = { true }
        defer { unlink(path + ".lock") }

        let response = await failing.catalogSubscribe()

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "\(failing.originHostName) could not list its sessions")
        XCTAssertNil(failing.originEvidence)
    }
}
