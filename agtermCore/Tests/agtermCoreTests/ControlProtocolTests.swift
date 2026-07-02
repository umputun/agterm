import Foundation
import Testing
@testable import agtermCore

struct ControlProtocolTests {
    // round-trip a request through JSON and back, asserting equality with the original.
    private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(ControlRequest.self, from: data)
    }

    private func roundTrip(_ response: ControlResponse) throws -> ControlResponse {
        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(ControlResponse.self, from: data)
    }

    @Test func treeRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .tree)
        #expect(try roundTrip(request) == request)
    }

    @Test func workspaceCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "work")),
            ControlRequest(cmd: .workspaceRename, target: "active", args: ControlArgs(name: "renamed")),
            ControlRequest(cmd: .workspaceDelete, target: "9f3c"),
            ControlRequest(cmd: .workspaceSelect, target: "9f3c"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .sessionNew, args: ControlArgs(cwd: "/tmp", workspace: "active")),
            ControlRequest(cmd: .sessionNew, args: ControlArgs(cwd: "/tmp", command: "ssh host -p 22")),
            ControlRequest(cmd: .sessionNew, args: ControlArgs(name: "myhost", command: "ssh host")),
            ControlRequest(cmd: .sessionNew, args: ControlArgs(workspaceName: "servers", createWorkspace: true)),
            ControlRequest(cmd: .sessionClose, target: "9f3c"),
            ControlRequest(cmd: .sessionSelect, target: "9f3c"),
            ControlRequest(cmd: .sessionRename, target: "active", args: ControlArgs(name: "build")),
            ControlRequest(cmd: .sessionMove, target: "9f3c", args: ControlArgs(workspace: "other")),
            ControlRequest(cmd: .sessionCopy, target: "9f3c"),
            ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(cwd: "/b", command: "revdiff")),
            ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(command: "htop", sizePercent: 70)),
            ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(command: "revdiff", color: "#2a1a3a")),
            ControlRequest(cmd: .sessionOverlayClose, target: "9f3c"),
            ControlRequest(cmd: .sessionOverlayResult, target: "9f3c"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionTextRoundTripsWithAllLinesAndPane() throws {
        let request = ControlRequest(cmd: .sessionText, target: "9f3c",
                                     args: ControlArgs(pane: "left", all: true, lines: 50))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionText)
        #expect(decoded.args?.all == true)
        #expect(decoded.args?.lines == 50)
        #expect(decoded.args?.pane == "left")
    }

    @Test func sessionTextBareRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionText)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.all == nil)
        #expect(decoded.args?.lines == nil)
        #expect(decoded.args?.pane == nil)
    }

    @Test func sessionTypeWithSelectRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionType, target: "9f3c", args: ControlArgs(text: "ls\n", select: true))
        #expect(try roundTrip(request) == request)
    }

    @Test func sessionTypeWithoutSelectRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionType, target: "active", args: ControlArgs(text: "pwd\n"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.select == nil)
    }

    @Test func sessionStatusRoundTripsWithStateAndBlink() throws {
        let request = ControlRequest(cmd: .sessionStatus, target: "9f3c",
                                     args: ControlArgs(status: "active", blink: true, autoReset: true))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionStatus)
        #expect(decoded.args?.status == "active")
        #expect(decoded.args?.blink == true)
        #expect(decoded.args?.autoReset == true)
    }

    @Test func sessionStatusRoundTripsWithSound() throws {
        let request = ControlRequest(cmd: .sessionStatus, target: "9f3c",
                                     args: ControlArgs(status: "blocked", sound: "Glass"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.sound == "Glass")
    }

    @Test func sessionStatusOmitsSoundWhenNil() throws {
        let request = ControlRequest(cmd: .sessionStatus, target: "9f3c", args: ControlArgs(status: "active"))
        let decoded = try roundTrip(request)
        #expect(decoded.args?.sound == nil)
    }

    @Test func sessionStatusDecodesSound() throws {
        let json = #"{"cmd":"session.status","args":{"status":"blocked","sound":"default"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .sessionStatus)
        #expect(decoded.args?.status == "blocked")
        #expect(decoded.args?.sound == "default")
    }

    @Test func sessionStatusRawStringMapsToCommandAndArgs() throws {
        let json = #"{"cmd":"session.status","args":{"status":"blocked"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .sessionStatus)
        #expect(decoded.args?.status == "blocked")
        #expect(decoded.args?.blink == nil)
        #expect(decoded.args?.autoReset == nil)
    }

    @Test func sessionStatusDecodesAutoReset() throws {
        let json = #"{"cmd":"session.status","args":{"status":"completed","autoReset":true}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .sessionStatus)
        #expect(decoded.args?.status == "completed")
        #expect(decoded.args?.autoReset == true)
    }

    @Test func sessionStatusUnknownStateDecodesForServerToReject() throws {
        // an unknown status string decodes fine; the server rejects it via AgentStatus(rawValue:) -> nil.
        let json = #"{"cmd":"session.status","args":{"status":"bogus"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .sessionStatus)
        #expect(decoded.args?.status == "bogus")
        #expect(AgentStatus(rawValue: decoded.args?.status ?? "") == nil)
    }

    @Test func modeBearingCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .sessionSplit, target: "active", args: ControlArgs(mode: "toggle")),
            ControlRequest(cmd: .sessionScratch, target: "active", args: ControlArgs(mode: "toggle")),
            ControlRequest(cmd: .sessionScratch, target: "9f3c", args: ControlArgs(mode: "on")),
            ControlRequest(cmd: .sessionScratch, target: "active", args: ControlArgs(mode: "on", command: "htop")),
            ControlRequest(cmd: .quick, args: ControlArgs(mode: "show")),
            ControlRequest(cmd: .sidebar, args: ControlArgs(mode: "hide")),
            ControlRequest(cmd: .sessionFlag, target: "active", args: ControlArgs(mode: "toggle")),
            ControlRequest(cmd: .sessionFlag, target: "9f3c", args: ControlArgs(mode: "on")),
            ControlRequest(cmd: .sessionFlag, args: ControlArgs(mode: "clear")),
            ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "flagged")),
            ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: "toggle")),
            ControlRequest(cmd: .workspaceFocus, target: "active", args: ControlArgs(mode: "on")),
            ControlRequest(cmd: .workspaceFocus, target: "9f3c", args: ControlArgs(mode: "off")),
            ControlRequest(cmd: .workspaceFocus, target: "active", args: ControlArgs(mode: "toggle")),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionScratchRoundTripsWithCommand() throws {
        let request = ControlRequest(cmd: .sessionScratch, target: "active", args: ControlArgs(mode: "on", command: "htop"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.mode == "on")
        #expect(decoded.args?.command == "htop")
    }

    @Test func sessionResizeRoundTrips() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .sessionResize, target: "active", args: ControlArgs(ratio: 0.7)),
            ControlRequest(cmd: .sessionResize, target: "9f3c", args: ControlArgs(ratioDelta: 0.05)),
            ControlRequest(cmd: .sessionResize, args: ControlArgs(ratioDelta: -0.05)),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionResizeRawStringMapsToCommandAndArgs() throws {
        let raw = #"{"cmd":"session.resize","target":"active","args":{"ratio":0.7}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(raw.utf8))
        #expect(decoded.cmd == .sessionResize)
        #expect(decoded.args?.ratio == 0.7)
        #expect(decoded.args?.ratioDelta == nil)
    }

    @Test func sessionResizeResultRoundTripsRatio() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c", ratio: 0.85))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.ratio == 0.85)
    }

    @Test func sessionFlagRawStringMapsToCommandAndMode() throws {
        let raw = #"{"cmd":"session.flag","target":"active","args":{"mode":"on"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(raw.utf8))
        #expect(decoded.cmd == .sessionFlag)
        #expect(decoded.args?.mode == "on")
    }

    @Test func sidebarModeRawStringMapsToCommand() throws {
        let raw = #"{"cmd":"sidebar.mode","args":{"mode":"flagged"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(raw.utf8))
        #expect(decoded.cmd == .sidebarMode)
        #expect(decoded.args?.mode == "flagged")
    }

    @Test func workspaceFocusRawStringMapsToCommandAndMode() throws {
        let raw = #"{"cmd":"workspace.focus","target":"active","args":{"mode":"on"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(raw.utf8))
        #expect(decoded.cmd == .workspaceFocus)
        #expect(decoded.args?.mode == "on")
        #expect(decoded.target == "active")
    }

    @Test func sessionBackgroundRoundTrips() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .sessionBackground, target: "active",
                           args: ControlArgs(mode: "image", path: "/tmp/bg.png", opacity: 0.2,
                                             fit: "cover", position: "top-left", repeats: true)),
            ControlRequest(cmd: .sessionBackground, target: "9f3c",
                           args: ControlArgs(text: "DRAFT", mode: "text", color: "#ff0000",
                                             opacity: 0.15, fit: "contain", position: "center")),
            ControlRequest(cmd: .sessionBackground, target: "active", args: ControlArgs(mode: "color", color: "#112233")),
            ControlRequest(cmd: .sessionBackground, target: "active", args: ControlArgs(mode: "clear")),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionBackgroundRawStringMapsToCommandAndArgs() throws {
        let raw = ##"{"cmd":"session.background","target":"active","args":{"mode":"text","text":"DRAFT","color":"#ff0000","opacity":0.15}}"##
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(raw.utf8))
        #expect(decoded.cmd == .sessionBackground)
        #expect(decoded.args?.mode == "text")
        #expect(decoded.args?.text == "DRAFT")
        #expect(decoded.args?.color == "#ff0000")
        #expect(decoded.args?.opacity == 0.15)
    }

    @Test func treeSessionNodeRoundTripsWithFlagged() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false, flagged: true)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.flagged == true)
    }

    @Test func treeSessionNodeRoundTripsWithTitle() throws {
        let session = ControlSessionNode(id: "s1", name: "build", cwd: "/tmp", title: "user@web1: ~",
                                         active: true, split: false)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.title == "user@web1: ~")
    }

    @Test func treeSessionNodeOmitsTitleWhenNil() throws {
        // a session with no reported title must omit the key entirely (backward-compatible), not emit null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("title"), "a nil title must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.title == nil)
    }

    @Test func treeSessionNodeRoundTripsWithForeground() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: true,
                                         foreground: ["ssh", "gate"], splitForeground: ["tail", "-f", "/x"])
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        let node = decoded.result?.tree?.workspaces.first?.sessions.first
        #expect(node?.foreground == ["ssh", "gate"])
        #expect(node?.splitForeground == ["tail", "-f", "/x"])
    }

    @Test func treeSessionNodeOmitsForegroundWhenNil() throws {
        // a pane at its prompt has no foreground command — the keys must be omitted, not emitted as null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("foreground"), "a nil foreground must be omitted from the JSON; got \(json)")
    }

    @Test func treeSessionNodeRoundTripsWithStatus() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false, status: "blocked")
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.status == "blocked")
    }

    @Test func treeSessionNodeOmitsStatusWhenNil() throws {
        // an idle session has no agent status — the key must be omitted, not emitted as null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("status"), "a nil status must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.status == nil)
    }

    @Test func treeSessionNodeRoundTripsWithBackground() throws {
        // the read side of session.background: the watermark spec rides the tree node so a script can query it.
        let watermark = BackgroundWatermark(kind: .text, text: "PROD", colorHex: "#ff0000",
                                            opacity: 0.2, fit: .cover, position: .topRight)
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         background: watermark)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        let node = decoded.result?.tree?.workspaces.first?.sessions.first
        #expect(node?.background == watermark)
        #expect(node?.background?.fit == .cover)          // the typed enum survives the wire round-trip
        #expect(node?.background?.position == .topRight)
    }

    @Test func treeSessionNodeOmitsBackgroundWhenNil() throws {
        // a session with no watermark — the key must be omitted, not emitted as null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("background"), "a nil background must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.background == nil)
    }

    @Test func backgroundWatermarkFitPositionSerializeAsRawStrings() throws {
        // the Fit/Position enums must serialize to ghostty's exact key strings (identical to the former
        // String), so the wire + persisted JSON are unchanged by the enum migration.
        let watermark = BackgroundWatermark(kind: .image, imagePath: "/a.png", fit: .stretch, position: .bottomCenter)
        let json = String(data: try JSONEncoder().encode(watermark), encoding: .utf8) ?? ""
        #expect(json.contains("\"fit\":\"stretch\""))
        #expect(json.contains("\"position\":\"bottom-center\""))
        // a decoded-back value equals the original (rawValue mapping is lossless).
        let decoded = try JSONDecoder().decode(BackgroundWatermark.self, from: Data(json.utf8))
        #expect(decoded == watermark)
    }

    @Test func backgroundWatermarkColorKindSerializes() throws {
        // the `.color` kind serializes as "color" and carries only the hex (no opacity — a solid color
        // honors the Settings window translucency at render time). Round-trip through ControlSessionNode too,
        // so the actual `tree` wire path (not just the struct in isolation) covers the color read-back.
        let watermark = BackgroundWatermark(kind: .color, colorHex: "#112233")
        let json = String(decoding: try JSONEncoder().encode(watermark), as: UTF8.self)
        #expect(json.contains("\"kind\":\"color\""))
        #expect(try JSONDecoder().decode(BackgroundWatermark.self, from: Data(json.utf8)) == watermark)

        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         background: watermark)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let node = try roundTrip(response).result?.tree?.workspaces.first?.sessions.first
        #expect(node?.background == watermark)
        #expect(node?.background?.kind == .color)
        #expect(node?.background?.colorHex == "#112233")
    }

    @Test func restoreClearRoundTrips() throws {
        let request = ControlRequest(cmd: .restoreClear)
        #expect(try roundTrip(request) == request)
    }

    @Test func sessionFocusRoundTripsWithPane() throws {
        let request = ControlRequest(cmd: .sessionFocus, target: "active", args: ControlArgs(pane: "right"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.pane == "right")
    }

    @Test func sessionGoRoundTripsWithDirection() throws {
        let request = ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "next"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionGo)
        #expect(decoded.args?.to == "next")
    }

    @Test func sessionGoRoundTripsWithAttentionDirection() throws {
        let request = ControlRequest(cmd: .sessionGo, args: ControlArgs(to: "next-attention"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.to == "next-attention")
        #expect(SessionNavigation(wire: decoded.args!.to!) == .nextAttention)
    }

    @Test func sessionMoveReorderRoundTripsWithDirection() throws {
        let request = ControlRequest(cmd: .sessionMove, target: "9f3c", args: ControlArgs(to: "up"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionMove)
        #expect(decoded.args?.to == "up")
        #expect(decoded.args?.workspace == nil)
    }

    @Test func workspaceMoveRoundTripsWithDirection() throws {
        let request = ControlRequest(cmd: .workspaceMove, target: "active", args: ControlArgs(to: "top"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .workspaceMove)
        #expect(decoded.args?.to == "top")
    }

    @Test func workspaceMoveRawStringMapsToCommand() throws {
        let json = #"{"cmd":"workspace.move","target":"active","args":{"to":"bottom"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .workspaceMove)
        #expect(decoded.args?.to == "bottom")
    }

    @Test func sessionSearchRoundTripsWithNeedleAndDirection() throws {
        let request = ControlRequest(cmd: .sessionSearch, target: "active", args: ControlArgs(text: "foo", to: "next"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionSearch)
        #expect(decoded.args?.text == "foo")
        #expect(decoded.args?.to == "next")
    }

    @Test(arguments: ["next", "prev", "close"]) func sessionSearchRoundTripsEachDirection(_ to: String) throws {
        let request = ControlRequest(cmd: .sessionSearch, target: "active", args: ControlArgs(to: to))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionSearch)
        #expect(decoded.args?.to == to)
    }

    @Test func sessionSearchResultRoundTripsWithCountAndText() throws {
        let response = ControlResponse(ok: true, result: ControlResult(text: "3 of 12", count: 12))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.count == 12)
        #expect(decoded.result?.text == "3 of 12")
    }

    @Test func sessionSearchRawStringMapsToCommand() throws {
        let json = #"{"cmd":"session.search"}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .sessionSearch)
    }

    @Test func notifyRoundTripsWithTitleAndBody() throws {
        let request = ControlRequest(cmd: .notify, target: "active", args: ControlArgs(title: "Build", body: "done"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.title == "Build")
        #expect(decoded.args?.body == "done")
    }

    @Test func fontCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .fontInc, target: "active"),
            ControlRequest(cmd: .fontDec, target: "active"),
            ControlRequest(cmd: .fontReset, target: "active"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func windowCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .windowNew, args: ControlArgs(name: "work")),
            ControlRequest(cmd: .windowList),
            ControlRequest(cmd: .windowSelect, target: "9f3c"),
            ControlRequest(cmd: .windowClose, target: "9f3c"),
            ControlRequest(cmd: .windowRename, target: "active", args: ControlArgs(name: "renamed")),
            ControlRequest(cmd: .windowDelete, target: "9f3c"),
            ControlRequest(cmd: .windowZoom, target: "9f3c"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func keymapReloadRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .keymapReload)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .keymapReload)
    }

    @Test func keymapReloadRawStringMapsToCommand() throws {
        let json = #"{"cmd":"keymap.reload"}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .keymapReload)
    }

    @Test func configReloadRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .configReload)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .configReload)
    }

    @Test func configReloadRawStringMapsToCommand() throws {
        let json = #"{"cmd":"config.reload"}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .configReload)
    }

    @Test func sidebarExpandCollapseRequestsRoundTrip() throws {
        let cases = [
            ControlRequest(cmd: .sidebarExpand),
            ControlRequest(cmd: .sidebarCollapse),
            ControlRequest(cmd: .sidebarExpand, args: ControlArgs(window: "abc")),
            ControlRequest(cmd: .sidebarCollapse, args: ControlArgs(window: "abc")),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sidebarExpandRawStringMapsToCommand() throws {
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"cmd":"sidebar.expand"}"#.utf8))
        #expect(decoded.cmd == .sidebarExpand)
    }

    @Test func sidebarCollapseRawStringMapsToCommand() throws {
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(#"{"cmd":"sidebar.collapse"}"#.utf8))
        #expect(decoded.cmd == .sidebarCollapse)
    }

    @Test func responseOkWithCountRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(count: 3))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.count == 3)
    }

    @Test func themeSetRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .themeSet, args: ControlArgs(name: "Dracula"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .themeSet)
        #expect(decoded.args?.name == "Dracula")
    }

    @Test func themeSetRawStringMapsToCommand() throws {
        let json = #"{"cmd":"theme.set","args":{"name":"Nord"}}"#
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        #expect(decoded.cmd == .themeSet)
        #expect(decoded.args?.name == "Nord")
    }

    @Test func themeListRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .themeList)
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .themeList)
    }

    @Test func themeListResponseRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(theme: "Nord", themes: ["Dracula", "Nord"]))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.theme == "Nord")
        #expect(decoded.result?.themes == ["Dracula", "Nord"])
    }

    @Test func themeSetResponseEchoesAppliedTheme() throws {
        let response = ControlResponse(ok: true, result: ControlResult(theme: "Dracula"))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.theme == "Dracula")
        #expect(decoded.result?.themes == nil)
    }

    @Test func sessionCommandWithWindowArgRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionSelect, target: "9f3c", args: ControlArgs(window: "main"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.window == "main")
    }

    @Test func requestUsesExpectedWireFieldNames() throws {
        let request = ControlRequest(cmd: .sessionType, target: "9f3c", args: ControlArgs(text: "ls\n", select: true))
        let json = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
        #expect(json.contains("\"cmd\":\"session.type\""))
        #expect(json.contains("\"target\":\"9f3c\""))
        #expect(json.contains("\"args\":"))
        #expect(json.contains("\"text\":\"ls\\n\""))
        #expect(json.contains("\"select\":true"))
    }

    @Test func responseOkWithIDRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.id == "9f3c")
    }

    @Test func responseOkWithTreeRoundTrips() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let workspace = ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(workspaces: [workspace])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.name == "shell")
    }

    @Test func responseOkWithTextRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(text: "selected\nlines"))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.text == "selected\nlines")
    }

    @Test func responseOkWithExitCodeRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c", exitCode: 10))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.exitCode == 10)
    }

    @Test func responseOkWithWindowsRoundTrips() throws {
        let windows = [
            ControlWindowNode(id: "w1", name: "work", open: true, active: true),
            ControlWindowNode(id: "w2", name: "personal", open: false, active: false),
        ]
        let response = ControlResponse(ok: true, result: ControlResult(windows: windows))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.windows?.count == 2)
        #expect(decoded.result?.windows?.first?.name == "work")
        #expect(decoded.result?.windows?.first?.open == true)
        #expect(decoded.result?.windows?.first?.active == true)
        #expect(decoded.result?.windows?.last?.open == false)
    }

    @Test func windowsResultUsesExpectedWireFieldNames() throws {
        let windows = [ControlWindowNode(id: "w1", name: "work", open: true, active: false)]
        let response = ControlResponse(ok: true, result: ControlResult(windows: windows))
        let json = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))
        #expect(json.contains("\"windows\":"))
        #expect(json.contains("\"id\":\"w1\""))
        #expect(json.contains("\"name\":\"work\""))
        #expect(json.contains("\"open\":true"))
        #expect(json.contains("\"active\":false"))
    }

    @Test func responseErrorRoundTrips() throws {
        let response = ControlResponse(ok: false, error: "ambiguous prefix '9f'")
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.ok == false)
        #expect(decoded.error == "ambiguous prefix '9f'")
    }

    @Test func responseUsesExpectedWireFieldNames() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let json = try #require(String(data: JSONEncoder().encode(response), encoding: .utf8))
        #expect(json.contains("\"ok\":true"))
        #expect(json.contains("\"result\":"))
        #expect(json.contains("\"id\":\"9f3c\""))
    }

    @Test func unknownCommandFailsToDecode() {
        let json = #"{"cmd":"bogus.command"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
        }
    }
}
