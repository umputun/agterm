import Foundation
import agtermCore

/// this Mac serves its own windows as remote windows: one catalog per window, kept until quit, fed by the window's
/// store and by zmx inventory reads taken only when the window's panes may have changed.
extension ControlServer: CatalogStreamHost {
    var catalogHelloDeadline: TimeInterval { presentationHelloDeadline }
    var catalogHubs: [CatalogHub] { originCatalogs.values.map(\.hub) }

    func catalogViewersChanged() { refreshWindowCache() }

    func catalogSubscription(for hello: CatalogHello) -> CatalogSubscription {
        switch originStore(hello.window) {
        case .failure(let refusal): return .refuse(reason: refusal.message(host: originHostName), final: refusal.final)
        case .success(let origin): return .serve(originCatalog(origin.id, store: origin.store).hub, macCatalogVersions)
        }
    }
}

extension ControlServer {
    static let originCreationBound: Duration = .seconds(3)
    static let originInventoryTimeout: TimeInterval = 2
    static let originCreations: Set<Command> = [.sessionNew, .sessionCompanionNew, .sessionCompanionDuplicate]

    var macCatalogVersions: CatalogVersions {
        CatalogVersions(server: identity.version, protocolVersion: PresentationCodec.version, catalog: CatalogCodec.version,
                        live: originLiveActive())
    }

    var originHostName: String { Host.current().localizedName ?? "this Mac" }

    /// catalogSubscribe reads the panes before the stream opens, so the hello's snapshot lists every running row; a
    /// failed read is refused for the viewer to retry. Without Live sessions the hello refuses for good instead.
    func catalogSubscribe() async -> ControlResponse {
        guard originLiveActive(), zmxClient != nil else { return ControlResponse(ok: true) }
        guard await readOriginEvidence(always: true) else {
            return ControlResponse(ok: false, error: "\(originHostName) could not list its sessions")
        }
        return ControlResponse(ok: true)
    }

    func catalogOperation(_ opID: String, sent: CatalogPosition?, window: String?) -> ControlResponse {
        switch originStore(window) {
        case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message(host: originHostName))
        case .success(let origin):
            let catalog = originCatalog(origin.id, store: origin.store)
            return catalog.book.lookup(opID, sent: sent, host: catalog.operation(in: library) { [weak self] in
                await self?.runOriginOperation($0, catalog: catalog) ?? Self.stopping
            })
        }
    }

    /// originOperation serves an operation-bearing request against the window its `--window` names, nil for a
    /// request without an operation id. It never reaches the remote route: the window is this Mac's own.
    func originOperation(_ request: ControlRequest) async -> ControlResponse? {
        guard let opID = request.args?.opID else { return nil }
        switch originStore(request.args?.window) {
        case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message(host: originHostName))
        case .success(let origin):
            let catalog = originCatalog(origin.id, store: origin.store)
            await readOriginEvidence()
            let host = catalog.operation(in: library) { [weak self] in
                await self?.runOriginOperation($0, catalog: catalog) ?? Self.stopping
            }
            let response = await catalog.book.serve(request, opID: opID, host: host)
            await readOriginEvidence()
            catalog.publisher.publish()
            return response
        }
    }

    /// originViewers is how many Macs mirror `window`, nil at none.
    func originViewers(_ window: UUID) -> Int? {
        originCatalogs[window].map(\.hub.subscriberCount).flatMap { $0 > 0 ? $0 : nil }
    }

    /// originEvent republishes the window an event came from, rereads the inventory when the window's panes or
    /// their attachments changed, and ends the window's streams once its store is gone.
    func originEvent(_ event: ControlEvent) {
        guard let id = event.window.flatMap(UUID.init(uuidString:)), let catalog = originCatalogs[id],
              let store = catalog.store else { return }
        guard library.store(for: id) === store else {
            endOriginCatalog(catalog)
            return
        }
        catalog.publisher.markDirty()
        let signature = Self.paneSignature(store)
        guard originSignatures[id] != signature else { return }
        originSignatures[id] = signature
        refreshOriginEvidence()
    }

    /// wireOriginEvents taps the library's event hook once, after the hook controller set it at launch.
    func wireOriginEvents() {
        guard !originEventsWired else { return }
        originEventsWired = true
        let hooks = library.onControlEvent
        library.onControlEvent = { [weak self] event in
            hooks?(event)
            self?.originEvent(event)
        }
    }

    /// holdOriginRestart keeps `pane` listed as running while a `session restart` replaces its shell.
    func holdOriginRestart(_ pane: UUID) {
        restartHolds[pane, default: 0] += 1
        publishRestarting()
    }

    /// releaseOriginRestart drops one restart's hold on `pane`; the last release rereads which panes run.
    func releaseOriginRestart(_ pane: UUID) {
        guard let count = restartHolds[pane] else { return }
        restartHolds[pane] = count > 1 ? count - 1 : nil
        publishRestarting()
        if restartHolds[pane] == nil { refreshOriginEvidence() }
    }

    /// originPaneConfirmed lists `pane` as running once a restart saw its new shell, ahead of the inventory, so
    /// releasing the restart's hold cannot show it held in between.
    func originPaneConfirmed(_ pane: UUID) {
        originConfirmations.confirm(pane, at: .now)
        originEvidence?.running.insert(pane)
        for catalog in originCatalogs.values { catalog.projection.evidence.running.insert(pane) }
    }

    private func publishRestarting() {
        let restarting = Set(restartHolds.keys)
        for catalog in originCatalogs.values { catalog.projection.evidence.restarting = restarting }
    }

    /// refreshOriginEvidence rereads the inventory once, coalescing requests made while a read runs.
    func refreshOriginEvidence() {
        Task { await readOriginEvidence() }
    }

    /// readOriginEvidence reads which panes run, for every window catalog and the next one made, answering whether
    /// the read succeeded. `always` reads with no catalog yet, for a viewer about to subscribe.
    @discardableResult
    func readOriginEvidence(always: Bool = false) async -> Bool {
        guard always || !originCatalogs.isEmpty, let client = zmxClient else { return false }
        if let running = originRead {
            originRereads = true
            return await running.value
        }
        let read = Task { @MainActor in
            repeat {
                originRereads = false
                let began = ContinuousClock.now
                guard let observed = await client.backgroundSessionRecords(timeout: Self.originInventoryTimeout) else { return false }
                let walk = library.paneClaims()
                let inventory = ZmxInventory.join(observed: observed, claims: walk.claims, inventoryComplete: walk.complete)
                var evidence = CatalogPaneEvidence(inventory: inventory, restarting: Set(restartHolds.keys))
                evidence.running.formUnion(originConfirmations.applied(readBegan: began))
                originEvidence = evidence
                for catalog in originCatalogs.values where catalog.projection.evidence != evidence {
                    catalog.projection.evidence = evidence
                }
            } while originRereads
            return true
        }
        originRead = read
        defer { originRead = nil }
        return await read.value
    }

    private static let stopping = ControlResponse(ok: false, error: "agterm is stopping")

    private func originStore(_ window: String?) -> Result<(id: UUID, store: AppStore), OriginCatalogRefusal> {
        library.originCatalogStore(window: window, liveActive: originLiveActive())
    }

    private func originCatalog(_ id: UUID, store: AppStore) -> OriginCatalog {
        let catalog = originCatalogs[id] ?? {
            let shape = CatalogProjection(endpoint: zmxClient?.endpoint ?? ControlZmxEndpoint(executable: "", socketDirectory: "")) { pane in
                let count = MessageBus.shared.pending(for: pane)
                return count > 0 ? count : nil
            }
            let options = OriginCatalog.Options(epoch: originEpoch, staleTimeout: 30, shape: shape,
                                                versions: macCatalogVersions) { [weak self] window in
                (self?.library.recentClosedItems(inWindow: window) ?? []).map(ControlRecentItem.init)
            }
            let created = OriginCatalog(window: id, options: options)
            if let originEvidence { created.projection.evidence = originEvidence }
            // the bus is not observable; the relay is what republishes a count an ack changed
            mailRelay.start()
            originCatalogs[id] = created
            return created
        }()
        if catalog.store !== store {
            catalog.bind(store)
            originSignatures[id] = Self.paneSignature(store)
            refreshOriginEvidence()
        }
        return catalog
    }

    private func endOriginCatalog(_ catalog: OriginCatalog) {
        catalog.bind(nil)
        originSignatures[catalog.window] = nil
        let name = library.windows.first { $0.id == catalog.window }?.name ?? catalog.window.uuidString
        let reason = OriginCatalogRefusal.closed(name).message(host: originHostName)
        for stream in catalogStreams where stream.serves(catalog.hub) { stream.refuse(reason: reason, final: false) }
    }

    /// runOriginOperation runs one operation's command in its window: creation without selecting and with a bounded
    /// wait for the new row's panes, undo and Recent Closed limited to that window's own entries.
    private func runOriginOperation(_ request: ControlRequest, catalog: OriginCatalog) async -> ControlResponse {
        guard let store = catalog.store else { return ControlResponse(ok: false, error: "the window closed") }
        // these would select or reveal on the origin; none of them waits, so the person there cannot act in between
        switch request.cmd {
        case .sessionUndo:
            let id = request.target.flatMap(UUID.init(uuidString:))
            guard let id, await store.preservingSelection({ store.undoPendingClose(id) }) else {
                return ControlResponse(ok: false, error: AppStore.closeNoLongerUndoable)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        case .recentOpen:
            return await store.preservingSelection { reopenOriginRecent(request.target, window: catalog.window) }
        case .workspaceNew:
            return await store.preservingSelection { await dispatch(request) }
        case .sessionCompanionConvert:
            return await store.preservingSelection {
                convertToCompanion(request.target, window: request.args?.window, focus: false)
            }
        case .sessionSplit:
            let raw = request.args?.axis, axis = raw.flatMap(SplitAxis.init(rawValue:))
            // an unknown axis goes on to the dispatcher, which names it
            guard raw == nil || axis != nil else { break }
            return splitSession(request.target, window: request.args?.window, mode: request.args?.mode, axis: axis, focus: false)
        case .recentClear:
            library.clearRecentClosedItems(inWindow: catalog.window)
            guard library.recentClosedItems(inWindow: catalog.window).isEmpty else {
                return ControlResponse(ok: false, error: "could not clear recent items")
            }
            return ControlResponse(ok: true)
        default:
            break
        }
        var plain = request
        if Self.originCreations.contains(request.cmd) {
            var args = plain.args ?? ControlArgs()
            args.noSelect = true
            plain.args = args
        }
        let response = await dispatch(plain)
        if Self.originCreations.contains(request.cmd), response.ok, let id = response.result?.id.flatMap(UUID.init(uuidString:)) {
            await waitOriginEligible(id, catalog: catalog)
        }
        return response
    }

    private func reopenOriginRecent(_ target: String?, window: UUID) -> ControlResponse {
        let items = library.recentClosedItems(inWindow: window)
        let id: UUID
        switch RecentClosedTarget.resolve(target, in: items) {
        case .failure(let error): return ControlResponse(ok: false, error: error.message)
        case .success(let resolved): id = resolved
        }
        let rows = { (self.library.store(for: window)?.workspaces ?? []).flatMap(\.sessions).map(\.id) }
        let before = Set(rows())
        switch library.reopenRecentClosed(id, inWindow: window) {
        case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message)
        case .success(let outcome):
            guard let item = items.first(where: { $0.id == id }) else { return ControlResponse(ok: false, error: "could not reopen \(id)") }
            // a lone companion's closed parent reopens first, and the viewer claims the lead of every row it brought back
            let restored = rows().filter { !before.contains($0) }.map(\.uuidString)
            let open = ControlRecentOpen(item: ControlRecentItem(item), window: outcome.window.uuidString, complete: outcome.complete,
                                         restored: restored)
            return ControlResponse(ok: true, result: ControlResult(recentOpen: open))
        }
    }

    /// waitOriginEligible rereads the inventory until the new row's primary runs, the row is gone, or the bound
    /// passes. A row still starting moves no revision, so its receipt is noop with the created id, and the row
    /// appears in a later revision.
    private func waitOriginEligible(_ session: UUID, catalog: OriginCatalog) async {
        let deadline = ContinuousClock.now + Self.originCreationBound
        while ContinuousClock.now < deadline {
            guard let row = catalog.store?.session(withID: session), row.content == .terminal else { return }
            await readOriginEvidence()
            if catalog.projection.evidence.runs(row.paneIdentity) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// paneSignature is the window's panes with whether each holds an attachment, which changes when a pane opens,
    /// closes, is restarted or reattached, or stops at a held exit.
    private static func paneSignature(_ store: AppStore) -> Set<String> {
        Set(store.workspaces.flatMap(\.sessions).filter { $0.remoteHost == nil && $0.content == .terminal }.flatMap { session in
            (CatalogProjection.identities(of: session) + [session.localScratchIdentity].compactMap { $0 }).map {
                "\($0.uuidString):\(ZmxLeadBook.shared.role(pane: $0) != nil)"
            }
        })
    }
}
