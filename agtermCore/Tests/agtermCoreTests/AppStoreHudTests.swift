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
        store.openHud(session.id, command: "hud.sh", spec: spec, file: "/tmp/hud", size: HudPanelSize(widthPercent: 35, heightPercent: 12))

        let node = try #require(store.controlTree().workspaces[0].sessions.first)

        #expect(node.hud == ControlHudNode(message: "gathering options", detail: "scanning 400 files",
                                           spinner: "braille", backgroundColor: "#2a1a3a",
                                           textColor: "#e0e0e0", sizePercent: 35,
                                           heightPercent: 12, position: "top-center"))
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
}
