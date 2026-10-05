import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct MiscCommandsTests {
    @Test func keymapRunSendsTheNameWithItsTargetAndWindow() throws {
        let plain = try Keymap.Run.parse(["lazy git"]).makeRequest()
        #expect(plain.cmd == .keymapRun)
        #expect(plain.args?.name == "lazy git")

        let targeted = try Keymap.Run.parse(["Zed", "--target", "s1", "--window", "w1"]).makeRequest()
        #expect(targeted.target == "s1")
        #expect(targeted.args?.window == "w1")
        #expect(throws: (any Error).self) { try Keymap.Run.parse([]) }
    }

    @Test func browserLinksSendsItsModeOrNoneAndTakesNoWindow() throws {
        #expect(try Browser.Links.parse([]).makeRequest() == ControlRequest(cmd: .browserLinks))
        for mode in ["browser", "overlay"] {
            #expect(try Browser.Links.parse([mode]).makeRequest()
                == ControlRequest(cmd: .browserLinks, args: ControlArgs(mode: mode)))
        }
        #expect(throws: (any Error).self) { try Browser.Links.parse(["tab"]) }
        #expect(throws: (any Error).self) { try Browser.Links.parse(["overlay", "--window", "w1"]) }
    }

    @Test func surfaceCursorAndSessionTypeTakeAPaneID() throws {
        let cursor = try Surface.Cursor.parse(["--target", "s1", "--pane-id", "tok"]).makeRequest()
        #expect(cursor == ControlRequest(cmd: .surfaceCursor, target: "s1", args: ControlArgs(paneID: "tok")))
        let typed = try agtermctlKit.Session.TypeText.parse(["hi", "--target", "s1", "--pane-id", "tok"]).makeRequest()
        #expect(typed == ControlRequest(cmd: .sessionType, target: "s1",
                                        args: ControlArgs(text: "hi", select: false, paneID: "tok")))
    }
}
