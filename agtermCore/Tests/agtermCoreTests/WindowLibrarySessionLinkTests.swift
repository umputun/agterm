import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibrarySessionLinkTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-links-\(UUID().uuidString)")
    private let endpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/run/zmx")

    deinit { try? FileManager.default.removeItem(at: directory) }

    private final class Binder: RemoteCatalogEffects {
        let bind: (UUID) -> Bool
        init(bind: @escaping (UUID) -> Bool) { self.bind = bind }
        func attachCommand(host _: String, pane _: CatalogPane) -> String { "attach" }
        func catalogRowAdded(_: Session) {}
        func catalogRowRemoved(_: UUID) {}
        func catalogRowEnded(_: UUID) {}
        func catalogPaneNeedsAttach(_: UUID, session _: UUID) {}
        func catalogBound(_ catalogID: UUID) -> Bool { bind(catalogID) }
        func catalogStateChanged(_: RemoteCatalogMirror.State) {}
    }

    private func row(_ store: AppStore, host: String? = nil) throws -> Session {
        try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp", remoteHost: host))
    }

    private func bind(_ row: Session, in store: AppStore, id: UUID, endpoint: ControlZmxEndpoint? = nil, origin: Bool = true) {
        store.bindRemote(RemoteBinding(remoteSessionID: id.uuidString,
                                       daemonsByLocalPane: [row.paneIdentity: ZmxSupport.daemonName(for: UUID())],
                                       presentationVersion: 1,
                                       origin: origin ? .init(host: "buildbox", endpoint: endpoint ?? self.endpoint,
                                                              sessionName: id.uuidString) : nil), forSession: row.id)
    }

    @Test func localLinksCrossWindowsButRejectMissingClosingAndNonShellOrigins() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let store = try #require(library.store(for: first))
        let clicked = try row(store)
        let second = library.newWindow()
        let other = try #require(library.store(for: second.id))
        let target = try row(other)
        for origin in [LinkPolicy.ClickOrigin.pane(clicked.id), .remotePane(clicked.id), .scratch(clicked.id)] {
            #expect(library.sessionLinkTarget(target.id, from: origin, pane: clicked.paneIdentity)
                    == SessionLinkTarget(windowID: second.id, sessionID: target.id))
            #expect(library.sessionLinkTarget(UUID(), from: origin, pane: clicked.paneIdentity) == nil)
        }
        for origin in [LinkPolicy.ClickOrigin.hud, .programOverlay, .quick, .pane(UUID()), .scratch(UUID()), .remotePane(UUID())] {
            #expect(library.sessionLinkTarget(target.id, from: origin, pane: clicked.paneIdentity) == nil)
        }
        #expect(other.softCloseSession(target.id))
        #expect(library.sessionLinkTarget(target.id, from: .pane(clicked.id), pane: clicked.paneIdentity) == nil)
        let closed = try row(other)
        library.closeWindow(second.id)
        #expect(library.sessionLinkTarget(closed.id, from: .pane(clicked.id), pane: clicked.paneIdentity) == nil)
    }

    @Test func attachedPanesUseOriginIDsWhileLocalSplitsAndScratchUseLocalIDs() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let store = try #require(library.store(for: first))
        let clicked = try row(store, host: "buildbox")
        let originID = UUID()
        bind(clicked, in: store, id: UUID())
        let second = library.newWindow()
        let other = try #require(library.store(for: second.id))
        let target = try row(other, host: "buildbox")
        bind(target, in: other, id: originID)
        for printed in [originID.uuidString, originID.uuidString.lowercased()] {
            let parsed = try #require(LinkPolicy.sessionLink("agterm://session/" + printed))
            #expect(library.sessionLinkTarget(parsed, from: .remotePane(clicked.id), pane: clicked.paneIdentity)
                    == SessionLinkTarget(windowID: second.id, sessionID: target.id))
        }
        #expect(library.sessionLinkTarget(target.id, from: .remotePane(clicked.id), pane: clicked.paneIdentity) == nil)
        let local = try row(other)
        #expect(library.sessionLinkTarget(local.id, from: .remotePane(clicked.id), pane: clicked.paneIdentity) == nil)
        let split = UUID()
        for origin in [LinkPolicy.ClickOrigin.pane(clicked.id), .remotePane(clicked.id)] {
            #expect(library.sessionLinkTarget(local.id, from: origin, pane: split)
                    == SessionLinkTarget(windowID: second.id, sessionID: local.id))
            #expect(library.sessionLinkTarget(originID, from: origin, pane: split) == nil)
        }
        #expect(library.sessionLinkTarget(local.id, from: .scratch(clicked.id), pane: nil)
                == SessionLinkTarget(windowID: second.id, sessionID: local.id))
        #expect(library.sessionLinkTarget(originID, from: .scratch(clicked.id), pane: nil) == nil)
        #expect(library.sessionLinkTarget(originID, from: .pane(clicked.id), pane: nil) == nil)
        let unbound = try row(store, host: "buildbox")
        #expect(library.sessionLinkTarget(local.id, from: .pane(unbound.id), pane: unbound.paneIdentity) == nil)
        bind(clicked, in: store, id: UUID(), origin: false)
        #expect(library.sessionLinkTarget(originID, from: .pane(clicked.id), pane: clicked.paneIdentity) == nil)
    }

    @Test func originMatchingRequiresOneLiveRowWithTheSameHostAndEndpoint() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let store = try #require(library.store(for: first))
        let clicked = try row(store, host: "buildbox")
        bind(clicked, in: store, id: UUID())
        let id = UUID()
        let other = try #require(library.store(for: library.newWindow().id))
        let wrongHost = try row(other, host: "otherbox")
        bind(wrongHost, in: other, id: id)
        let wrongEndpoint = try row(other, host: "buildbox")
        bind(wrongEndpoint, in: other, id: id, endpoint: .init(executable: "/other/zmx", socketDirectory: "/other"))
        let noOrigin = try row(other, host: "buildbox")
        bind(noOrigin, in: other, id: id, origin: false)
        let unbound = try row(other, host: "buildbox")
        #expect(!wrongHost.showsOriginSession(id.uuidString, host: "buildbox", endpoint: endpoint))
        #expect(!wrongEndpoint.showsOriginSession(id.uuidString, host: "buildbox", endpoint: endpoint))
        #expect(!noOrigin.showsOriginSession(id.uuidString, host: "buildbox", endpoint: endpoint))
        #expect(!unbound.showsOriginSession(id.uuidString, host: "buildbox", endpoint: endpoint))
        #expect(library.sessionLinkTarget(id, from: .pane(clicked.id), pane: clicked.paneIdentity) == nil)
        let target = try row(other, host: "buildbox")
        bind(target, in: other, id: id)
        #expect(target.showsOriginSession(id.uuidString, host: "buildbox", endpoint: endpoint))
        #expect(!target.showsOriginSession(UUID().uuidString, host: "buildbox", endpoint: endpoint))
        #expect(library.sessionLinkTarget(id, from: .pane(clicked.id), pane: clicked.paneIdentity) != nil)
        let duplicate = try row(store, host: "buildbox")
        bind(duplicate, in: store, id: id)
        #expect(library.sessionLinkTarget(id, from: .pane(clicked.id), pane: clicked.paneIdentity) == nil)
        #expect(store.softCloseSession(duplicate.id))
        #expect(library.sessionLinkTarget(id, from: .pane(clicked.id), pane: clicked.paneIdentity) != nil)
    }

    private func entry(ended: Bool = false, scratch: Bool = false) -> CatalogSession {
        let id = UUID(), identity = UUID()
        let pane = CatalogPane(identity: identity, daemon: ZmxSupport.daemonName(for: identity), endpoint: endpoint)
        var fields = CatalogSessionFields(id: id, name: "s", parent: nil, cwd: "/srv", primary: identity, axis: nil,
                                          shown: true, lifecycle: ended ? .ended : .live)
        if scratch {
            let identity = UUID()
            fields.scratch = CatalogScratch(pane: CatalogPane(identity: identity, daemon: ZmxSupport.scratchDaemonName(for: identity),
                                                             endpoint: endpoint), shown: true)
        }
        return CatalogSession(fields: fields, panes: ended ? [] : [pane])
    }

    @Test func anEndedRowWhoseScratchArrivesLaterResolvesBothWays() throws {
        let library = WindowLibrary(directory: directory)
        let window = library.newRemoteWindow(host: "buildbox")
        let store = try #require(library.store(for: window.id))
        let binder = Binder { library.bindCatalog($0, toWindow: window.id) == .bound }
        let mirror = RemoteCatalogMirror(host: "buildbox", store: store, effects: binder, viewState: RemoteWindowViewState())
        let a = entry(), b = entry(), late = entry(ended: true)
        let versions = CatalogVersions(server: "1", protocolVersion: 1, catalog: 1)
        _ = mirror.receive(.hello(CatalogHello(version: 1, epoch: "e1", versions: versions)))
        _ = mirror.receive(.snapshot(CatalogSnapshot(epoch: "e1", rev: 0, catalogID: UUID(), versions: versions,
                                                     workspaces: [CatalogWorkspace(id: UUID(), name: "w", sessions: [a, b, late])])))
        let aRow = try #require(store.session(withID: a.id))
        #expect(library.sessionLinkTarget(b.id, from: .scratch(late.id), pane: nil) == nil)
        #expect(library.sessionLinkTarget(late.id, from: .pane(a.id), pane: aRow.paneIdentity)
                == SessionLinkTarget(windowID: window.id, sessionID: late.id))
        var fields = late.fields
        let id = UUID()
        fields.scratch = CatalogScratch(pane: CatalogPane(identity: id, daemon: ZmxSupport.scratchDaemonName(for: id),
                                                         endpoint: endpoint), shown: true)
        fields.lifecycle = .ended

        _ = mirror.receive(.delta(epoch: "e1", rev: 1, change: .sessionChanged(fields)))

        #expect(library.sessionLinkTarget(b.id, from: .scratch(late.id), pane: nil)
                == SessionLinkTarget(windowID: window.id, sessionID: b.id))
        #expect(library.sessionLinkTarget(late.id, from: .pane(a.id), pane: aRow.paneIdentity)
                == SessionLinkTarget(windowID: window.id, sessionID: late.id))
        withExtendedLifetime((binder, mirror)) {}
    }

    @Test func catalogPanesAndScratchResolveIncludingAnEndedScratchOnlyRow() throws {
        let library = WindowLibrary(directory: directory)
        let localWindow = library.newWindow()
        let localRow = try row(try #require(library.store(for: localWindow.id)))
        let window = library.newRemoteWindow(host: "buildbox")
        let store = try #require(library.store(for: window.id))
        let binder = Binder { library.bindCatalog($0, toWindow: window.id) == .bound }
        let mirror = RemoteCatalogMirror(host: "buildbox", store: store, effects: binder, viewState: RemoteWindowViewState())
        let a = entry(scratch: true), b = entry(), ended = entry(ended: true, scratch: true), empty = entry(ended: true)
        _ = mirror.receive(.snapshot(CatalogSnapshot(epoch: "e1", rev: 0, catalogID: UUID(),
                                                     versions: CatalogVersions(server: "1", protocolVersion: 1, catalog: 1),
                                                     workspaces: [CatalogWorkspace(id: UUID(), name: "w", sessions: [a, b, ended, empty])])))
        let clicked = try #require(store.session(withID: a.id))
        let scratchOnly = try #require(store.session(withID: ended.id))
        #expect(scratchOnly.remotePresentation?.binding.origin?.endpoint == endpoint)
        for origin in [LinkPolicy.ClickOrigin.pane(clicked.id), .remotePane(clicked.id)] {
            #expect(library.sessionLinkTarget(b.id, from: origin, pane: clicked.paneIdentity)
                    == SessionLinkTarget(windowID: window.id, sessionID: b.id))
        }
        #expect(library.sessionLinkTarget(b.id, from: .scratch(clicked.id), pane: nil)
                == SessionLinkTarget(windowID: window.id, sessionID: b.id))
        #expect(library.sessionLinkTarget(b.id, from: .scratch(scratchOnly.id), pane: nil)
                == SessionLinkTarget(windowID: window.id, sessionID: b.id))
        #expect(library.sessionLinkTarget(localRow.id, from: .scratch(clicked.id), pane: nil) == nil)
        #expect(library.sessionLinkTarget(ended.id, from: .pane(clicked.id), pane: clicked.paneIdentity)
                == SessionLinkTarget(windowID: window.id, sessionID: ended.id))
        #expect(library.sessionLinkTarget(empty.id, from: .pane(clicked.id), pane: clicked.paneIdentity)
                == SessionLinkTarget(windowID: window.id, sessionID: empty.id))
        #expect(library.sessionLinkTarget(b.id, from: .scratch(empty.id), pane: nil) == nil)
        withExtendedLifetime((binder, mirror)) {}
    }
}
