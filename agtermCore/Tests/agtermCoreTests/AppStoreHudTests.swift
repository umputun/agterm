import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreHudTests {
    @Test func controlTreeReportsHudWithEveryField() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        let spec = HudSpec(message: "gathering options", detail: "scanning 400 files", spinner: true,
                           backgroundColor: "#2a1a3a", sizePercent: 35, position: .top)
        store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/hud", sizePercent: 35)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud == ControlHudNode(message: "gathering options", detail: "scanning 400 files",
                                           spinner: true, backgroundColor: "#2a1a3a", sizePercent: 35,
                                           position: "top"))
    }

    @Test func controlTreeReportsTheEffectiveHudPositionAndSize() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        // the caller set neither, so the read-back still names the default and the app's own measurement.
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      sizePercent: 22)

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud?.position == "center")
        #expect(node.hud?.sizePercent == 22)
        #expect(node.hud?.spinner == false)
        #expect(node.hud?.detail == nil)
        #expect(node.hud?.backgroundColor == nil)
    }

    @Test func controlTreeOmitsHudWithoutOne() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))

        #expect(try #require(store.controlTree().workspaces[0].sessions.first).hud == nil)

        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      sizePercent: 20)
        store.closeHud(session.id)

        #expect(try #require(store.controlTree().workspaces[0].sessions.first).hud == nil)
    }

    @Test func controlTreeNeverReportsAHudAsAProgramOverlay() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: ws.id, cwd: "/repo"))
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: "working"), file: "/tmp/hud",
                      sizePercent: 20)

        let withHud = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(!withHud.overlay)
        #expect(withHud.overlaySizePercent == nil)

        store.openOverlay(session.id, command: "htop", sizePercent: 70)
        let withProgram = try #require(store.controlTree().workspaces[0].sessions.first)
        #expect(withProgram.overlay)
        #expect(withProgram.overlaySizePercent == 70)
        #expect(withProgram.hud == nil)
    }
}
