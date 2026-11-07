import Foundation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryRemoteTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agts-remote-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: directory) }

    private var windowFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("windows").path)) ?? []
    }

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

    private func snapshot(_ catalogID: UUID) -> CatalogSnapshot {
        CatalogSnapshot(epoch: "e1", rev: 0, catalogID: catalogID,
                        versions: CatalogVersions(server: "1.2.3", protocolVersion: 1, catalog: 1), workspaces: [])
    }

    private func mirror(_ library: WindowLibrary, window id: UUID, host: String) throws -> (RemoteCatalogMirror, Binder) {
        let binder = Binder { catalogID in
            if case .duplicate = library.bindCatalog(catalogID, toWindow: id) { return false }
            return true
        }
        let store = try #require(library.store(for: id))
        return (RemoteCatalogMirror(host: host, store: store, effects: binder, viewState: RemoteWindowViewState()), binder)
    }

    @Test func theHooksBracketARemoteStoreAndALocalWindowFiresNeither() throws {
        let library = WindowLibrary(directory: directory)
        var opened: [UUID] = [], closed: [UUID] = []
        library.onRemoteStoreOpened = { id, _ in opened.append(id) }
        library.onRemoteStoreClosed = { closed.append($0) }

        let remote = library.newRemoteWindow(host: "buildbox")
        let local = library.newWindow()
        library.closeWindow(remote.id)
        library.closeWindow(local.id)
        library.loadStore(for: remote.id)

        #expect(opened == [remote.id, remote.id])
        #expect(closed == [remote.id])
        #expect(library.openRemoteStores.map(\.id) == [remote.id])
    }

    @Test func anAliasWhoseSnapshotArrivesAfterItOpenedSettlesToTheWindowShowingThatCatalog() throws {
        let library = WindowLibrary(directory: directory)
        let catalog = UUID()
        let first = library.newRemoteWindow(host: "buildbox")
        #expect(library.bindCatalog(catalog, toWindow: first.id) == .bound)
        let alias = library.newRemoteWindow(host: "buildbox.local")
        let (aliasMirror, binder) = try mirror(library, window: alias.id, host: "buildbox.local")

        let beforeSnapshot = library.settledRemoteWindowID(for: alias.id)
        _ = aliasMirror.receive(.snapshot(snapshot(catalog)))

        #expect(beforeSnapshot == nil)
        #expect(library.settledRemoteWindowID(for: alias.id) == first.id)
        #expect(withExtendedLifetime(binder) { aliasMirror.state } == .refused("another window already shows the catalog of buildbox.local"))
    }

    @Test func aClosedWindowShowingTheCatalogIsStillTheOneAnAliasSettlesTo() throws {
        let library = WindowLibrary(directory: directory)
        let catalog = UUID()
        let first = library.newRemoteWindow(host: "buildbox")
        #expect(library.bindCatalog(catalog, toWindow: first.id) == .bound)
        library.closeWindow(first.id)
        let alias = library.newRemoteWindow(host: "buildbox.local")
        let (aliasMirror, binder) = try mirror(library, window: alias.id, host: "buildbox.local")

        _ = aliasMirror.receive(.snapshot(snapshot(catalog)))

        #expect(withExtendedLifetime(binder) { library.settledRemoteWindowID(for: alias.id) } == first.id)
        #expect(!library.isOpen(first.id))
    }

    @Test func aWindowWhoseServerAnsweredSettlesToItself() throws {
        let library = WindowLibrary(directory: directory)
        let remote = library.newRemoteWindow(host: "buildbox")
        let (remoteMirror, binder) = try mirror(library, window: remote.id, host: "buildbox")

        _ = remoteMirror.receive(.snapshot(snapshot(UUID())))
        let connected = library.settledRemoteWindowID(for: remote.id)
        let unreachable = library.newRemoteWindow(host: "gone")
        let (goneMirror, goneBinder) = try mirror(library, window: unreachable.id, host: "gone")
        goneMirror.connectionLost("gone did not answer")

        #expect(withExtendedLifetime(binder) { connected } == remote.id)
        #expect(withExtendedLifetime(goneBinder) { library.settledRemoteWindowID(for: unreachable.id) } == unreachable.id)
    }

    @Test func treeAndWindowListReportTheServerItsCatalogAndTheConnection() throws {
        let library = WindowLibrary(directory: directory)
        let local = try #require(library.activeWindowID)
        let remote = library.newRemoteWindow(host: "buildbox")
        let catalog = UUID()
        let (remoteMirror, binder) = try mirror(library, window: remote.id, host: "buildbox")

        let connecting = library.remoteNode(for: remote.id)
        _ = remoteMirror.receive(.snapshot(snapshot(catalog)))
        remoteMirror.connectionLost("exit 255")
        let nodes = withExtendedLifetime(binder) { library.controlWindowNodes() }
        library.closeWindow(remote.id)

        #expect(library.remoteNode(for: local) == nil)
        #expect(connecting?.state == "connecting")
        #expect(connecting?.catalogID == nil)
        let listed = try #require(nodes.first { $0.id == remote.id.uuidString }?.remote)
        #expect(listed.host == "buildbox")
        #expect(listed.catalogID == catalog.uuidString)
        #expect(listed.state == "disconnected")
        #expect(listed.reason == "exit 255")
        #expect(nodes.first { $0.id == local.uuidString }?.remote == nil)
        #expect(library.remoteNode(for: remote.id)?.state == nil)
        let encoded = String(decoding: try JSONEncoder().encode(nodes.first { $0.id == local.uuidString }), as: UTF8.self)
        #expect(!encoded.contains("remote"))
    }

    @Test func aRemoteWindowIsNeverSeededAndKeepsItsSourceAcrossARelaunch() throws {
        let library = WindowLibrary(directory: directory)
        let local = try #require(library.activeWindowID)

        let remote = library.newRemoteWindow(host: "buildbox")
        let store = try #require(library.store(for: remote.id))
        let relaunched = WindowLibrary(directory: directory)

        #expect(store.workspaces.isEmpty)
        #expect(library.windows.map(\.id) == [local, remote.id])
        #expect(relaunched.windows.first { $0.id == remote.id }?.source == WindowSource(host: "buildbox"))
        #expect(relaunched.store(for: remote.id)?.workspaces.isEmpty == true)
        #expect(!windowFiles.contains("\(remote.id.uuidString).json"))
    }

    @Test func openingAHostAlreadyOpenReturnsItsWindow() {
        let library = WindowLibrary(directory: directory)
        let first = library.newRemoteWindow(host: "buildbox")

        let again = library.newRemoteWindow(host: "buildbox")
        let other = library.newRemoteWindow(host: "otherbox")

        #expect(again.id == first.id)
        #expect(other.id != first.id)
    }

    @Test func bindingACatalogRefusesOneAnotherWindowShowsAndNotesAReplacedOne() {
        let library = WindowLibrary(directory: directory)
        let first = library.newRemoteWindow(host: "a")
        let second = library.newRemoteWindow(host: "b")
        let catalog = UUID(), replacement = UUID()

        let bound = library.bindCatalog(catalog, toWindow: first.id)
        let duplicate = library.bindCatalog(catalog, toWindow: second.id)
        let rebound = library.bindCatalog(replacement, toWindow: first.id)

        #expect(bound == .bound)
        #expect(duplicate == .duplicate(first.id))
        #expect(rebound == .rebound(previous: catalog))
        #expect(WindowLibrary(directory: directory).windows.first { $0.id == first.id }?.source?.catalogID == replacement)
    }

    @Test func theViewStateIsSavedWithEveryStoreSaveAndReadBack() throws {
        let library = WindowLibrary(directory: directory)
        let remote = library.newRemoteWindow(host: "buildbox")
        let store = try #require(library.store(for: remote.id))
        let workspace = store.addWorkspace(name: "w")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/", remoteHost: "buildbox"))
        session.fontSize = 14
        store.catalogMirrored = true

        store.save()

        let state = WindowLibrary(directory: directory).remoteViewState(for: remote.id)
        #expect(state.selectedSessionID == session.id)
        #expect(state.sessions[session.id]?.fontSize == 14)
    }

    @Test func aColdReopenedWindowSavedBeforeItsCatalogKeepsTheSavedViewState() throws {
        let library = WindowLibrary(directory: directory)
        let remote = library.newRemoteWindow(host: "buildbox")
        let store = try #require(library.store(for: remote.id))
        let workspace = store.addWorkspace(name: "w")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/", remoteHost: "buildbox"))
        session.fontSize = 14
        store.catalogMirrored = true
        store.save()

        let relaunched = WindowLibrary(directory: directory)
        let cold = try #require(relaunched.store(for: remote.id))
        cold.save()

        #expect(WindowLibrary(directory: directory).remoteViewState(for: remote.id).sessions[session.id]?.fontSize == 14)
    }

    @Test func aClosedRemoteWindowLeavesTheClaimWalkComplete() {
        let library = WindowLibrary(directory: directory)
        let remote = library.newRemoteWindow(host: "buildbox")
        library.closeWindow(remote.id)

        let walk = library.paneClaims()

        #expect(walk.complete)
        #expect(!walk.claims.contains { $0.windowID == remote.id })
    }

    @Test func deletingARemoteWindowRemovesItsFiles() throws {
        let library = WindowLibrary(directory: directory)
        let remote = library.newRemoteWindow(host: "buildbox")
        let store = try #require(library.store(for: remote.id))
        _ = store.addWorkspace(name: "w")
        store.save()
        let remoteFiles = { (try? FileManager.default.contentsOfDirectory(atPath: self.directory.appendingPathComponent("remote").path)) ?? [] }
        let before = remoteFiles()

        library.removeWindow(remote.id)

        #expect(!before.isEmpty)
        #expect(remoteFiles().isEmpty)
    }

    @Test func aClosedLocalWorkspaceReopensInALocalWindowWhileARemoteOneIsFrontmost() throws {
        let library = WindowLibrary(directory: directory)
        let localStore = try #require(library.activeStore)
        let closing = localStore.addWorkspace(name: "closing")
        _ = localStore.addSession(toWorkspace: closing.id, cwd: "/")
        localStore.removeWorkspace(closing.id)
        let remote = library.newRemoteWindow(host: "buildbox")
        let remoteStore = try #require(library.store(for: remote.id))

        let reopened = library.reopenLatestRecentClosed(into: remoteStore)

        #expect(reopened)
        #expect(library.frontmostWindowID == remote.id)
        #expect(localStore.workspaces.contains { $0.id == closing.id })
        #expect(remoteStore.workspaces.isEmpty)
    }
}
