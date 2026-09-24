import Foundation
import Testing
@testable import agtermCore

@MainActor
struct PaneBackgroundsTests {
    private let driver = BackgroundWatermark(kind: .text, text: "DRIVER")
    private let peer = BackgroundWatermark(kind: .text, text: "PEER")
    private let tint = BackgroundWatermark(kind: .color, colorHex: "#201414")

    @Test func subscriptReadsAndWritesEachPane() {
        var backgrounds = PaneBackgrounds()
        #expect(backgrounds.isEmpty)
        for pane in StatusPane.allCases {
            backgrounds[pane] = driver
            #expect(backgrounds[pane] == driver)
            backgrounds[pane] = nil
        }
        #expect(backgrounds.isEmpty)
    }

    @Test func persistedFormDropsScratchAndCollapsesToNil() {
        #expect(PaneBackgrounds(scratch: driver).persisted == nil)
        #expect(PaneBackgrounds().persisted == nil)
        #expect(PaneBackgrounds(left: driver, right: peer, scratch: tint).persisted == PaneBackgrounds(left: driver, right: peer))
    }

    @Test func decodeDropsOnlyTheUndecodablePane() throws {
        let json = #"{"left":{"kind":"text","text":"DRIVER"},"right":{"kind":"bogus"},"scratch":7}"#
        let decoded = try JSONDecoder().decode(PaneBackgrounds.self, from: Data(json.utf8))
        #expect(decoded == PaneBackgrounds(left: driver))
    }

    @Test func effectiveBackgroundPrefersTheOverrideAndElseInherits() throws {
        let session = try makeSplitSession().session
        session.backgroundWatermark = tint
        session.paneBackgrounds.right = peer
        #expect(session.effectiveBackground(for: .left) == tint)
        #expect(session.effectiveBackground(for: .right) == peer)
        #expect(session.effectiveBackground(for: .scratch) == tint)
    }

    @Test func fileKeyFollowsPaneIdentityAndNamesScratch() throws {
        let session = try makeSplitSession().session
        #expect(session.backgroundFileKey(for: .left) == session.paneIdentity.uuidString)
        #expect(session.backgroundFileKey(for: .right) == session.splitPaneIdentity?.uuidString)
        #expect(session.backgroundFileKey(for: .scratch) == "scratch")
        session.splitPaneIdentity = nil
        #expect(session.backgroundFileKey(for: .right) == nil)
    }

    @Test func settingTheDefaultLeavesOverridesAndAPaneClearReturnsToInherit() throws {
        let (store, session) = try makeSplitSession()
        #expect(store.setBackgroundWatermark(peer, forSession: session.id, pane: .right))
        #expect(!store.setBackgroundWatermark(peer, forSession: session.id, pane: .right))
        #expect(store.setBackgroundWatermark(tint, forSession: session.id))
        #expect(session.paneBackgrounds.right == peer)
        #expect(store.setBackgroundWatermark(nil, forSession: session.id))
        #expect(session.backgroundWatermark == nil)
        #expect(session.paneBackgrounds.right == peer)
        #expect(store.setBackgroundWatermark(tint, forSession: session.id))
        #expect(store.setBackgroundWatermark(nil, forSession: session.id, pane: .right))
        #expect(session.paneBackgrounds.right == nil)
        #expect(session.effectiveBackground(for: .right) == tint)
        #expect(!store.setBackgroundWatermark(nil, forSession: UUID(), pane: .left))
    }

    @Test func closeSplitDropsOnlyTheRightOverride() throws {
        let (store, session) = try makeSplitSession()
        session.paneBackgrounds = PaneBackgrounds(left: driver, right: peer, scratch: tint)
        store.closeSplit(session.id)
        #expect(session.paneBackgrounds == PaneBackgrounds(left: driver, scratch: tint))
    }

    @Test func promotionMovesTheSurvivorsOverrideLeft() throws {
        let (store, session) = try makeSplitSession()
        session.paneBackgrounds = PaneBackgrounds(left: driver, right: peer)
        store.closePrimaryPane(session.id)
        #expect(session.paneBackgrounds == PaneBackgrounds(left: peer))
        #expect(session.effectiveBackground(for: .left) == peer)
    }

    @Test func promotionOfAnUnlabelledSurvivorLeavesLeftInheriting() throws {
        let (store, session) = try makeSplitSession()
        session.paneBackgrounds = PaneBackgrounds(left: driver)
        store.closePrimaryPane(session.id)
        #expect(session.paneBackgrounds.isEmpty)
    }

    @Test func scratchOverrideSurvivesHideAndShowButNotClose() throws {
        let (store, session) = try makeSplitSession()
        session.scratchSurface = SpySurface()
        store.toggleScratch(session.id)
        #expect(store.setBackgroundWatermark(driver, forSession: session.id, pane: .scratch))
        store.toggleScratch(session.id)
        store.toggleScratch(session.id)
        #expect(session.paneBackgrounds.scratch == driver)
        #expect(store.closeScratch(session.id))
        #expect(session.paneBackgrounds.scratch == nil)
    }

    @Test func snapshotPersistsLeftAndRightButNeverScratch() throws {
        let (store, session) = try makeSplitSession()
        session.paneBackgrounds = PaneBackgrounds(left: driver, right: peer, scratch: tint)
        let persisted = try #require(store.snapshot().workspaces.first?.sessions.first)
        #expect(persisted.paneBackgrounds == PaneBackgrounds(left: driver, right: peer))
        let restored = store.session(from: persisted)
        #expect(restored.paneBackgrounds == PaneBackgrounds(left: driver, right: peer))
    }

    @Test func restoreDropsARightOverrideWithoutASplit() throws {
        var persisted = SessionSnapshot(id: UUID(), customName: nil, cwd: "/tmp")
        persisted.paneBackgrounds = PaneBackgrounds(left: driver, right: peer)
        let restored = makeStore().session(from: persisted)
        #expect(restored.paneBackgrounds == PaneBackgrounds(left: driver))
    }

    @Test func washColorIsTheEffectiveSolidColorOnly() throws {
        let session = try makeSplitSession().session
        session.backgroundWatermark = tint
        session.paneBackgrounds.right = peer
        #expect(session.washColorHex(for: .left) == "#201414")
        #expect(session.washColorHex(for: .right) == nil)
        session.paneBackgrounds.scratch = BackgroundWatermark(kind: .color, colorHex: "#102030")
        #expect(session.washColorHex(for: .scratch) == "#102030")
    }

    @Test func backdropRegionsLayerEachPaneOverTheSessionDefault() throws {
        let session = try makeSplitSession().session
        session.backgroundWatermark = tint
        session.paneBackgrounds.right = BackgroundWatermark(kind: .color, colorHex: "#102030")
        let left = HudPaneFrame(x: 0, y: 0, width: 400, height: 300)
        let right = HudPaneFrame(x: 401, y: 0, width: 399, height: 300)

        #expect(session.backdropWashRegions(paneFrames: HudPaneFrames(left: left, right: right)) == [
            BackdropWashRegion(frame: nil, colorHex: "#201414"),
            BackdropWashRegion(frame: left, colorHex: "#201414"),
            BackdropWashRegion(frame: right, colorHex: "#102030"),
        ])
    }

    @Test func backdropRegionsTakeAPaneOverlaysOwnBackground() throws {
        let session = try makeSplitSession().session
        session.paneBackgrounds.left = tint
        session.paneBackgrounds.right = tint
        session.setPaneOverlay(PaneOverlay(command: "top", backgroundColor: "#0a0b0c"), pane: .left)
        session.setPaneOverlay(PaneOverlay(command: "htop"), pane: .right)
        let left = HudPaneFrame(x: 0, y: 0, width: 400, height: 300)
        let right = HudPaneFrame(x: 401, y: 0, width: 399, height: 300)

        #expect(session.backdropWashRegions(paneFrames: HudPaneFrames(left: left, right: right)) == [
            BackdropWashRegion(frame: nil, colorHex: nil),
            BackdropWashRegion(frame: left, colorHex: "#0a0b0c"),
            BackdropWashRegion(frame: right, colorHex: nil),
        ])
    }

    @Test func backdropRegionsUseOnlyTheScratchWhileItIsShown() throws {
        let session = try makeSplitSession().session
        session.backgroundWatermark = tint
        session.paneBackgrounds.right = BackgroundWatermark(kind: .color, colorHex: "#102030")
        session.scratchActive = true
        let frames = HudPaneFrames(left: HudPaneFrame(x: 0, y: 0, width: 400, height: 300))

        #expect(session.backdropWashRegions(paneFrames: frames) == [BackdropWashRegion(frame: nil, colorHex: "#201414")])
        session.paneBackgrounds.scratch = peer
        #expect(session.backdropWashRegions(paneFrames: frames) == [BackdropWashRegion(frame: nil, colorHex: nil)])
    }

    private func makeSplitSession() throws -> (store: AppStore, session: Session) {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        session.surface = SpySurface()
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        return (store, session)
    }
}
