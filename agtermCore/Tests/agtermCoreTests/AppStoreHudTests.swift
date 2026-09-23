import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreHudTests {
    @Test func controlTreeReportsHudWithEveryField() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        let spec = HudSpec(message: "gathering options", detail: "scanning 400 files", spinner: .braille,
                           backgroundColor: "#2a1a3a", textColor: "#e0e0e0", sizePercent: 35,
                           position: .topCenter)
        store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 35, heightPercent: 12),
                      paneIdentity: session.paneIdentity)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud == ControlHudNode(message: "gathering options", detail: "scanning 400 files",
                                           spinner: "braille", backgroundColor: "#2a1a3a",
                                           textColor: "#e0e0e0", sizePercent: 35,
                                           heightPercent: 12, position: "top-center", pane: "left"))
    }

    @Test func paneReadBackFollowsTheStableIdentityAcrossRoleChanges() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        let target = UUID()
        session.splitPaneIdentity = target
        session.hasSplit = true
        session.isSplit = true
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 30, heightPercent: 8), paneIdentity: target)

        #expect(store.controlTree().workspaces[0].sessions[0].hud?.pane == "right")

        session.paneIdentity = target
        session.splitPaneIdentity = UUID()
        #expect(store.controlTree().workspaces[0].sessions[0].hud?.pane == "left")
    }

    @Test func closingTheTargetPaneClosesItsHudButPreservesAnotherPanesHud() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        let splitIdentity = UUID()
        session.splitPaneIdentity = splitIdentity
        session.hasSplit = true
        session.isSplit = true
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "split"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 30, heightPercent: 8), paneIdentity: splitIdentity)

        store.closeSplit(session.id)
        #expect(!session.hudActive)

        session.splitPaneIdentity = UUID()
        session.hasSplit = true
        session.isSplit = true
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "primary"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 30, heightPercent: 8), paneIdentity: session.paneIdentity)
        store.closeSplit(session.id)
        #expect(session.hudActive)
        #expect(session.hudTargetPane == .left)
    }

    @Test func closingAnAbsentSplitDoesNotCloseASessionWideHud() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 30, heightPercent: 8))

        store.closeSplit(session.id)

        #expect(session.hudActive)
        #expect(session.hudPaneIdentity == nil)
    }

    @Test func hidingTheTargetPaneKeepsTheHudForItsReturn() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        let target = UUID()
        session.splitPaneIdentity = target
        session.hasSplit = true
        session.isSplit = true
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 30, heightPercent: 8), paneIdentity: target)

        store.toggleSplit(session.id)
        #expect(session.hudActive)
        #expect(session.hudTargetPane == .right)
        #expect(!session.rendersPane(.right))

        store.toggleSplit(session.id)
        #expect(session.hudActive)
        #expect(session.rendersPane(.right))
    }

    @Test func primaryExitClosesItsHudAndPreservesASurvivorHud() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        session.hasSplit = true
        session.isSplit = true
        let splitIdentity = UUID()
        session.splitPaneIdentity = splitIdentity

        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "primary"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 30, heightPercent: 8),
                      paneIdentity: session.paneIdentity)
        store.closePrimaryPane(session.id)
        #expect(!session.hudActive)

        session.splitSurface = SpySurface()
        session.hasSplit = true
        session.isSplit = true
        let nextSplitIdentity = UUID()
        session.splitPaneIdentity = nextSplitIdentity
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "survivor"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 30, heightPercent: 8), paneIdentity: nextSplitIdentity)
        store.closePrimaryPane(session.id)
        #expect(session.hudActive)
        #expect(session.hudPaneIdentity == nextSplitIdentity)
        #expect(session.hudTargetPane == .left)
    }

    /// A caller who sent an alias reads the canonical anchor back, which is what makes it an alias rather
    /// than a second spelling the read-back has to carry.
    @Test func theReadBackReportsTheCanonicalAnchorForAnAlias() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        let position = try #require(HudPosition.parse("bottom"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working", position: position),
                      file: "/tmp/hud", size: HudPanelSize(widthPercent: 22, heightPercent: 9))

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud?.position == "bottom-center")
    }

    @Test func theReadBackReportsMarkdownAndTheRequestedFontSize() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "**ok**", markdown: true, fontSize: 18),
                      file: "/tmp/hud", size: HudPanelSize(widthPercent: 22, heightPercent: 9))

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud?.markdown == true)
        #expect(node.hud?.fontSize == 18)
    }

    @Test func thePlainReadBackReportsMarkdownOffAndNoFontSize() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 22, heightPercent: 9))

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud?.markdown == false)
        #expect(node.hud?.fontSize == nil)
    }

    @Test func theReadBackOmitsTextColorWhenTheCallerSetNone() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 22, heightPercent: 9))

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud?.textColor == nil)
    }

    @Test func controlTreeReportsTheEffectiveHudPositionAndSize() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        // the caller set neither, so the read-back still names the default and the app's own measurement.
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 22, heightPercent: 9))

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud?.position == "center")
        #expect(node.hud?.sizePercent == 22)
        #expect(node.hud?.heightPercent == 9)
        #expect(node.hud?.spinner == HudSpinner.noneName)
        #expect(node.hud?.detail == nil)
        #expect(node.hud?.backgroundColor == nil)
    }

    @Test func controlTreeKeepsTheHudColorAcrossAnUpdate() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "one", backgroundColor: "#2a1a3a"),
                      file: "/tmp/hud", size: HudPanelSize(widthPercent: 30, heightPercent: 9))

        store.updateHud(session.id, spec: HudSpec(message: "two"), size: HudPanelSize(widthPercent: 30, heightPercent: 9))
        var node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.hud?.backgroundColor == "#2a1a3a", "the color the panel still paints must survive")

        store.updateHud(session.id, spec: HudSpec(message: "three", backgroundColor: "#ff0000"),
                        size: HudPanelSize(widthPercent: 30, heightPercent: 9))
        node = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(node.hud?.backgroundColor == "#2a1a3a", "a color the surface will never read must not be reported")
        #expect(node.hud?.message == "three")
    }

    @Test func controlTreeOmitsHudWithoutOne() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))

        #expect(try #require(store.controlTree().workspaces[0].sessions.first).hud == nil)

        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
        store.closeHud(session.id)

        #expect(try #require(store.controlTree().workspaces[0].sessions.first).hud == nil)
    }

    @Test func controlTreeNeverReportsAHudAsAProgramOverlay() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))

        let withHud = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(!withHud.overlay)
        #expect(withHud.overlaySizePercent == nil)

        store.openOverlay(session.id, command: "htop", sizePercent: 70)
        let withProgram = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(withProgram.overlay)
        #expect(withProgram.overlaySizePercent == 70)
        #expect(withProgram.hud == nil)
    }

    @MainActor
    private final class HudSink: PresentationSink {
        var frames: [PresentationFrame] = []
        func offer(_ frame: PresentationFrame) -> Bool {
            frames.append(frame)
            return true
        }
        func close(_ reason: PresentationHub.CloseReason) {}

        var huds: [PresentationHud?] {
            frames.compactMap { if case .hud(let hud) = $0.body { return .some(hud) } else { return nil } }
        }
        var snapshot: PresentationSnapshot? {
            frames.lazy.compactMap { if case .snapshot(let snapshot) = $0.body { snapshot } else { nil } }.first
        }
    }

    private static let start = Date(timeIntervalSince1970: 1_789_000_000)
    private static let size = HudPanelSize(widthPercent: 30, heightPercent: 8)

    private struct Mirrored {
        let store: AppStore
        let session: Session
        let hub: PresentationHub
        let sink: HudSink
    }

    private func mirroredStore() throws -> Mirrored {
        let store = makeStore()
        let hub = PresentationHub(staleTimeout: 30)
        store.presentationHub = hub
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        let sink = HudSink()
        try subscribe(sink, to: session, in: store, hub: hub, now: Self.start)
        return Mirrored(store: store, session: session, hub: hub, sink: sink)
    }

    private func subscribe(_ sink: HudSink, to session: Session, in store: AppStore, hub: PresentationHub,
                           now: Date) throws {
        try hub.subscribe(session: session.id, hello: PresentationHello(version: 1, kinds: ["hud"], mode: .mirror),
                          sink: sink) { store.presentationSnapshot(forSession: session.id, now: now) }
    }

    private func openAndPublish(_ message: String, hideAfter: Double? = nil, in store: AppStore,
                                session: Session, paneIdentity: UUID? = nil) {
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: message, hideAfter: hideAfter),
                      file: "/tmp/agterm-test-hud-\(session.id)", size: Self.size, paneIdentity: paneIdentity)
        store.publishHud(forSession: session.id, expiresAt: hideAfter.map { Self.start.addingTimeInterval($0) },
                         now: Self.start)
    }

    @Test func aPublishedHudTravelsWithItsPaneIdentityAndRemainingLifetime() throws {
        let fix = try mirroredStore()
        let (store, session, sink) = (fix.store, fix.session, fix.sink)

        openAndPublish("deploying", hideAfter: 10, in: store, session: session,
                       paneIdentity: session.paneIdentity)

        let hud = try #require(sink.huds.last ?? nil)
        #expect(hud.spec.message == "deploying")
        #expect(hud.pane == .identity(session.paneIdentity))
        #expect(hud.remaining == 10)
    }

    @Test func aSessionWideHudWithNoAutoHideTravelsWithNeither() throws {
        let fix = try mirroredStore()
        let (store, session, sink) = (fix.store, fix.session, fix.sink)

        openAndPublish("waiting", in: store, session: session)

        let hud = try #require(sink.huds.last ?? nil)
        #expect(hud.pane == nil)
        #expect(hud.remaining == nil)
    }

    @Test func everyPublicationCarriesALargerGeneration() throws {
        let fix = try mirroredStore()
        let (store, session, sink) = (fix.store, fix.session, fix.sink)
        openAndPublish("one", in: store, session: session)

        store.updateHud(session.id, spec: HudSpec(message: "two"), size: Self.size)
        store.publishHud(forSession: session.id, expiresAt: nil, now: Self.start)
        openAndPublish("three", in: store, session: session)

        let generations = sink.huds.compactMap { $0?.generation }
        #expect(generations.count == 3)
        #expect(generations == generations.sorted())
        #expect(Set(generations).count == 3)
    }

    @Test func aLateSubscriberGetsTheRemainingLifetimeNotTheConfiguredOne() throws {
        let fix = try mirroredStore()
        let (store, session, hub) = (fix.store, fix.session, fix.hub)
        openAndPublish("deploying", hideAfter: 10, in: store, session: session)
        let late = HudSink()

        try subscribe(late, to: session, in: store, hub: hub, now: Self.start.addingTimeInterval(7))

        #expect(late.snapshot?.hud?.remaining == 3)
        #expect(late.snapshot?.hud?.spec.hideAfter == 10)
    }

    @Test func remainingLifetimeNeverGoesNegative() throws {
        let fix = try mirroredStore()
        let (store, session, hub) = (fix.store, fix.session, fix.hub)
        openAndPublish("deploying", hideAfter: 10, in: store, session: session)
        let late = HudSink()

        try subscribe(late, to: session, in: store, hub: hub, now: Self.start.addingTimeInterval(11))

        #expect(late.snapshot?.hud?.remaining == 0)
    }

    @Test func closingTheHudPublishesAbsence() throws {
        let fix = try mirroredStore()
        let (store, session, sink) = (fix.store, fix.session, fix.sink)
        openAndPublish("deploying", in: store, session: session)

        store.closeHud(session.id)

        #expect(sink.huds.count == 2)
        #expect(sink.huds.last == .some(nil))
        #expect(store.presentationSnapshot(forSession: session.id, now: Self.start).hud == nil)
    }

    @Test func aProgramOverlayReplacingTheHudPublishesAbsence() throws {
        let fix = try mirroredStore()
        let (store, session, sink) = (fix.store, fix.session, fix.sink)
        openAndPublish("deploying", in: store, session: session)

        #expect(store.openOverlay(session.id, command: "htop"))

        #expect(sink.huds.last == .some(nil))
    }

    @Test func aHudThatWasNeverPublishedIsAbsentFromTheSnapshotAndPublishesNothingOnDiscard() throws {
        let fix = try mirroredStore()
        let (store, session, sink) = (fix.store, fix.session, fix.sink)

        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "unwritten"), file: "/tmp/agterm-x",
                      size: Self.size)
        #expect(store.presentationSnapshot(forSession: session.id, now: Self.start).hud == nil)
        store.closeHud(session.id)

        #expect(sink.huds.isEmpty)
    }

    @Test func aFailedReplacementPublishesAbsenceOnceAndNeverTheRejectedSpec() throws {
        let fix = try mirroredStore()
        let (store, session, sink) = (fix.store, fix.session, fix.sink)
        openAndPublish("first", in: store, session: session)

        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "rejected"), file: "/tmp/agterm-x",
                      size: Self.size)
        store.closeHud(session.id)

        #expect(sink.huds.map { $0?.spec.message } == ["first", nil])
    }

    @Test func aResizeRepublishesTheForcedWidthAndKeepsTheDeadline() throws {
        let fix = try mirroredStore()
        let (store, session, hub) = (fix.store, fix.session, fix.hub)
        openAndPublish("deploying", hideAfter: 10, in: store, session: session)

        #expect(store.resizeOverlay(session.id, sizePercent: 60))
        store.publishHudResize(forSession: session.id, now: Self.start.addingTimeInterval(4))

        let resized = try #require(fix.sink.huds.last ?? nil)
        #expect(resized.spec.sizePercent == 60)
        #expect(resized.remaining == 6)
        let late = HudSink()
        try subscribe(late, to: session, in: store, hub: hub, now: Self.start.addingTimeInterval(4))
        #expect(late.snapshot?.hud?.spec.sizePercent == 60)
    }

    @Test func theNextPublicationDropsAForcedWidthItsSpecDoesNotAsk() throws {
        let fix = try mirroredStore()
        let (store, session) = (fix.store, fix.session)
        openAndPublish("deploying", in: store, session: session)
        store.resizeOverlay(session.id, sizePercent: 60)
        store.publishHudResize(forSession: session.id, now: Self.start)

        store.updateHud(session.id, spec: HudSpec(message: "done"), size: Self.size)
        store.publishHud(forSession: session.id, expiresAt: nil, now: Self.start)

        #expect((fix.sink.huds.last ?? nil)?.spec.sizePercent == nil)
    }
}
