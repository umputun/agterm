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
            ControlRequest(cmd: .sessionNew, args: ControlArgs(noSelect: true)),
            ControlRequest(cmd: .sessionDuplicate, target: "9f3c"),
            ControlRequest(cmd: .sessionDuplicate, target: "active", args: ControlArgs(window: "win")),
            ControlRequest(cmd: .sessionClose, target: "9f3c"),
            ControlRequest(cmd: .sessionClose, args: ControlArgs(targets: ["9f3c", "abcd"])),
            ControlRequest(cmd: .sessionSelect, target: "9f3c"),
            ControlRequest(cmd: .sessionRename, target: "active", args: ControlArgs(name: "build")),
            ControlRequest(cmd: .sessionReveal, target: "active"),
            ControlRequest(cmd: .sessionMove, target: "9f3c", args: ControlArgs(workspace: "other")),
            ControlRequest(cmd: .sessionMove, args: ControlArgs(targets: ["9f3c", "abcd"], workspace: "other")),
            ControlRequest(cmd: .sessionMove, args: ControlArgs(targets: ["9f3c", "abcd"], after: "anchor")),
            ControlRequest(cmd: .sessionCopy, target: "9f3c"),
            ControlRequest(cmd: .sessionPaste, target: "9f3c"),
            ControlRequest(cmd: .sessionSelectAll, target: "9f3c"),
            ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(cwd: "/b", command: "revdiff")),
            ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(command: "htop", sizePercent: 70)),
            ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(command: "revdiff", color: "#2a1a3a")),
            ControlRequest(cmd: .sessionOverlayClose, target: "9f3c"),
            ControlRequest(cmd: .sessionOverlayResize, target: "9f3c", args: ControlArgs(sizePercent: 60)),
            ControlRequest(cmd: .sessionOverlayResize, target: "9f3c", args: ControlArgs(full: true)),
            ControlRequest(cmd: .sessionOverlayResult, target: "9f3c"),
            ControlRequest(cmd: .surfaceZoom, target: "surface:5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9:right",
                           args: ControlArgs(mode: "show", window: "win")),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionBatchTargetsOmitWhenNilAndRoundTripWhenSet() throws {
        let single = ControlRequest(cmd: .sessionClose, target: "9f3c")
        let singleJSON = String(data: try JSONEncoder().encode(single), encoding: .utf8) ?? ""
        #expect(!singleJSON.contains("targets"), "nil targets must be omitted from single-target JSON; got \(singleJSON)")

        let batch = ControlRequest(cmd: .sessionClose, args: ControlArgs(targets: ["a", "b"]))
        let decoded = try roundTrip(batch)
        #expect(decoded == batch)
        #expect(decoded.args?.targets == ["a", "b"])
    }

    @Test func sessionOverlayResizeOmitsFullWhenNil() throws {
        let request = ControlRequest(cmd: .sessionOverlayResize, target: "9f3c", args: ControlArgs(sizePercent: 60))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.full == nil)
        // omit-when-nil WIRE contract for the new `full` field: a percent resize must not emit `full` at all.
        let json = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
        #expect(!json.contains("full"), "a nil full must be omitted from the JSON; got \(json)")
    }

    @Test func sessionOverlayOpenRoundTripsWithFollow() throws {
        let follow = ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c",
                                    args: ControlArgs(command: "revdiff", follow: true))
        let decodedFollow = try roundTrip(follow)
        #expect(decodedFollow == follow)
        #expect(decodedFollow.args?.follow == true)

        let noFollow = ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c",
                                      args: ControlArgs(command: "revdiff", follow: false))
        let decodedNoFollow = try roundTrip(noFollow)
        #expect(decodedNoFollow == noFollow)
        #expect(decodedNoFollow.args?.follow == false)
    }

    @Test func sessionOverlayOpenOmitsFollowWhenNil() throws {
        let request = ControlRequest(cmd: .sessionOverlayOpen, target: "9f3c", args: ControlArgs(command: "revdiff"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.follow == nil)
        // verify the omit-when-nil WIRE contract (the reason follow is Bool?): a nil follow must not be
        // encoded at all, not emitted as null.
        let json = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
        #expect(!json.contains("follow"), "a nil follow must be omitted from the JSON; got \(json)")
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

    @Test func sessionTypeWithPaneRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionType, target: "9f3c",
                                     args: ControlArgs(text: "ls\n", pane: "right"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.pane == "right")
    }

    @Test func sessionSeenRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionSeen, target: "9f3c", args: ControlArgs(window: "win"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.cmd == .sessionSeen)
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

    @Test func sessionStatusRoundTripsWithColor() throws {
        let request = ControlRequest(cmd: .sessionStatus, target: "9f3c",
                                     args: ControlArgs(status: "blocked", color: "#ff0000"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.color == "#ff0000")
    }

    @Test func sessionStatusOmitsColorWhenNil() throws {
        let request = ControlRequest(cmd: .sessionStatus, target: "9f3c", args: ControlArgs(status: "active"))
        let decoded = try roundTrip(request)
        #expect(decoded.args?.color == nil)
    }

    @Test func sessionStatusRoundTripsWithPaneID() throws {
        let request = ControlRequest(cmd: .sessionStatus, target: "9f3c",
                                     args: ControlArgs(paneID: "surface-token-abc", status: "blocked"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.paneID == "surface-token-abc")
    }

    @Test func sessionStatusOmitsPaneIDWhenNil() throws {
        let request = ControlRequest(cmd: .sessionStatus, target: "9f3c", args: ControlArgs(status: "active"))
        let decoded = try roundTrip(request)
        #expect(decoded.args?.paneID == nil)
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

    @Test func quickTypeAndTextCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .quickType, args: ControlArgs(text: "hello\n")),
            ControlRequest(cmd: .quickText),
            ControlRequest(cmd: .quickText, args: ControlArgs(all: true)),
            ControlRequest(cmd: .quickText, args: ControlArgs(lines: 50)),
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

    @Test func treeSessionNodeRoundTripsWithFontSizes() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: true,
                                         fontSize: 13, splitFontSize: 9.5, scratchFontSize: 11)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        let node = decoded.result?.tree?.workspaces.first?.sessions.first
        #expect(node?.fontSize == 13)
        #expect(node?.splitFontSize == 9.5)
        #expect(node?.scratchFontSize == 11)
    }

    @Test func treeSessionNodeOmitsFontSizesWhenNil() throws {
        // an unrealized pane has no live font size — the keys must be omitted, not emitted as null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        // contains is case-sensitive: "fontSize" catches only the main key, "FontSize" catches the
        // suffixed splitFontSize/scratchFontSize keys — assert both so all three omissions are covered.
        #expect(!json.contains("fontSize"), "the main fontSize key must be omitted when nil; got \(json)")
        #expect(!json.contains("FontSize"), "splitFontSize/scratchFontSize must be omitted when nil; got \(json)")
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

    @Test func treeSessionNodeRoundTripsWithStatusPane() throws {
        // the read side of session.status --pane: which pane set the status rides the tree node.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: true,
                                         status: "blocked", statusPane: "right")
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.statusPane == "right")
    }

    @Test func treeSessionNodeOmitsStatusPaneWhenNil() throws {
        // a session with no pane tag — the key must be omitted, not emitted as null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("statusPane"), "a nil statusPane must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.statusPane == nil)
    }

    @Test func treeSessionNodeRoundTripsWithStatusBlinkAndColor() throws {
        // the read side of session.status --blink/--color: the status modifiers ride the tree node.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         status: "blocked", statusBlink: true, statusColor: "#ff8800")
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        let node = decoded.result?.tree?.workspaces.first?.sessions.first
        #expect(node?.statusBlink == true)
        #expect(node?.statusColor == "#ff8800")
    }

    @Test func treeSessionNodeOmitsStatusBlinkAndColorWhenNil() throws {
        // an idle / non-blinking / default-color status — both keys must be omitted, not emitted as null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false, status: "blocked")
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("statusBlink"), "a nil statusBlink must be omitted; got \(json)")
        #expect(!json.contains("statusColor"), "a nil statusColor must be omitted; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.statusBlink == nil)
        #expect(decoded.statusColor == nil)
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

    @Test func treeSessionNodeRoundTripsWithUnseen() throws {
        // the read side of the notification badge: the unseen count rides the tree node so a script can
        // query it (and pair it with session.seen to clear).
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: false, split: false, unseen: 3)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.unseen == 3)
    }

    @Test func treeSessionNodeOmitsUnseenWhenNil() throws {
        // a session with no pending notifications — the key must be omitted, not emitted as null or 0.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("unseen"), "a nil unseen count must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.unseen == nil)
    }

    @Test func treeSessionNodeRoundTripsWithCommandWait() throws {
        // the read side of session.new --wait: a held command session carries the flag so a script can
        // record it and restore the session with --wait (it persists across restart, unlike overlay wait).
        let session = ControlSessionNode(id: "s1", name: "build", cwd: "/tmp", active: false, split: false,
                                         commandWait: true)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.commandWait == true)
    }

    @Test func treeSessionNodeOmitsCommandWaitWhenNil() throws {
        // a plain session or a non-holding command session — the key must be omitted, not emitted as null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("commandWait"), "a nil commandWait must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.commandWait == nil)
    }

    @Test func treeSessionNodeRoundTripsWithOverlaySizePercent() throws {
        // the read side of session.overlay.resize: a floating overlay's percent rides the tree node so a
        // script can record it before resizing to full and restore the exact size afterwards.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         overlay: true, overlaySizePercent: 95)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.overlaySizePercent == 95)
    }

    @Test func treeSessionNodeOmitsOverlaySizePercentWhenNil() throws {
        // no overlay, or a FULL-pane overlay — the key must be omitted, not emitted as null (so a script
        // reads absent as "full or no overlay", gating on the `overlay` bool first).
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false, overlay: true)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("overlaySizePercent"), "a nil overlay size must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.overlaySizePercent == nil)
    }

    @Test func treeSessionNodeRoundTripsWithSplitRatio() throws {
        // the read side of session.resize: the current divider fraction rides the tree node so a script
        // can record it before maximizing a pane and restore the exact ratio afterwards.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: true, splitRatio: 0.35)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.splitRatio == 0.35)
    }

    @Test func treeSessionNodeOmitsSplitRatioWhenNil() throws {
        // no split, or a split still at the default 0.5 — the key must be omitted, not emitted as null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("splitRatio"), "a nil split ratio must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.splitRatio == nil)
    }

    @Test func treeSessionNodeRoundTripsWithSplitFocused() throws {
        // the read side of session.focus: which pane holds focus rides the tree node so a script can record
        // it and restore focus afterwards. false = the main (left) pane, true = the split (right) pane.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: true, splitFocused: false)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.splitFocused == false)
    }

    @Test func treeSessionNodeOmitsSplitFocusedWhenNil() throws {
        // no split — the key must be omitted, not emitted as null (a false value IS emitted, since it means
        // the left pane is focused, distinct from "no split").
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("splitFocused"), "a nil split focus must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.splitFocused == nil)
    }

    @Test func treeSessionNodeRoundTripsWithSurfaces() throws {
        let surfaces = [
            ControlSurfaceNode(id: "surface:s1:left", kind: "left", active: true, visible: true),
            ControlSurfaceNode(id: "surface:s1:right", kind: "right", active: false, visible: false),
        ]
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true,
                                         split: true, surfaces: surfaces)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))

        let decoded = try roundTrip(response)

        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.surfaces == surfaces)
    }

    @Test func treeSessionNodeToleratesMissingSurfaces() throws {
        // a pre-`surface.zoom` server omits the key — it must decode as nil, and a node built without
        // surfaces must omit the key from the JSON (the optional-field pattern of the other tree additions).
        let raw = #"{"id":"s1","name":"shell","cwd":"/tmp","active":true,"split":false,"# +
            #""overlay":false,"scratch":false,"flagged":false}"#
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(raw.utf8))
        #expect(decoded.surfaces == nil)

        let json = String(data: try JSONEncoder().encode(decoded), encoding: .utf8) ?? ""
        #expect(!json.contains("surfaces"), "nil surfaces must be omitted from the JSON; got \(json)")
    }

    @Test func treeRoundTripsWithLiveWindowFields() throws {
        // the tree carries the live idle metric + the auto-follow config (both ms) + sidebar visibility.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false)
        let tree = ControlTree(workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true,
                                                                 sessions: [session])],
                               idleMs: 4200, autoFollowMs: 30_000, sidebarVisible: false)
        let response = ControlResponse(ok: true, result: ControlResult(tree: tree))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.idleMs == 4200)
        #expect(decoded.result?.tree?.autoFollowMs == 30_000)
        #expect(decoded.result?.tree?.sidebarVisible == false)
    }

    @Test func treeOmitsLiveWindowFieldsWhenNil() throws {
        // no activity yet + auto-follow disabled + unknown sidebar — every key must be omitted, not null.
        let tree = ControlTree(workspaces: [])
        let json = String(data: try JSONEncoder().encode(tree), encoding: .utf8) ?? ""
        #expect(!json.contains("idleMs"), "a nil idleMs must be omitted from the JSON; got \(json)")
        #expect(!json.contains("autoFollowMs"), "a nil autoFollowMs must be omitted from the JSON; got \(json)")
        #expect(!json.contains("sidebarVisible"), "a nil sidebarVisible must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlTree.self, from: Data(json.utf8))
        #expect(decoded.idleMs == nil)
        #expect(decoded.autoFollowMs == nil)
        #expect(decoded.sidebarVisible == nil)
    }

    @Test func windowNodeRoundTripsWithPerWindowFields() throws {
        let node = ControlWindowNode(id: "w1", name: "work", open: true, active: true, autoFollowMs: 5000,
                                     sidebarVisible: true)
        let response = ControlResponse(ok: true, result: ControlResult(windows: [node]))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.windows?.first?.autoFollowMs == 5000)
        #expect(decoded.result?.windows?.first?.sidebarVisible == true)
    }

    @Test func windowNodeOmitsPerWindowFieldsWhenNil() throws {
        // auto-follow disabled + a closed window with no store — both keys must be omitted, not null.
        let node = ControlWindowNode(id: "w1", name: "work", open: true, active: false)
        let json = String(data: try JSONEncoder().encode(node), encoding: .utf8) ?? ""
        #expect(!json.contains("autoFollowMs"), "a nil autoFollowMs must be omitted from the JSON; got \(json)")
        #expect(!json.contains("sidebarVisible"), "a nil sidebarVisible must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlWindowNode.self, from: Data(json.utf8))
        #expect(decoded.autoFollowMs == nil)
        #expect(decoded.sidebarVisible == nil)
    }

    @Test func windowNodeRoundTripsWithGeometry() throws {
        // the read side of window.move/window.resize: the live frame rides the window node so a script can
        // record it, resize/move, then restore the exact frame (fields match the CLI's --x/--y/--width/etc).
        let node = ControlWindowNode(id: "w1", name: "work", open: true, active: true,
                                     geometry: ControlWindowFrame(x: 100, y: 40, width: 1200, height: 800, display: 1))
        let response = ControlResponse(ok: true, result: ControlResult(windows: [node]))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        let frame = try #require(decoded.result?.windows?.first?.geometry)
        #expect(frame == ControlWindowFrame(x: 100, y: 40, width: 1200, height: 800, display: 1))
    }

    @Test func windowNodeOmitsGeometryWhenNil() throws {
        // a closed window with no live NSWindow — the key must be omitted, not emitted as null.
        let node = ControlWindowNode(id: "w1", name: "work", open: false, active: false)
        let json = String(data: try JSONEncoder().encode(node), encoding: .utf8) ?? ""
        #expect(!json.contains("geometry"), "a nil geometry must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlWindowNode.self, from: Data(json.utf8))
        #expect(decoded.geometry == nil)
    }

    @Test func windowNodeRoundTripsWithFullscreenAndZoom() throws {
        // the read side of window.fullscreen/window.zoom: both live toggle states ride the window node so a
        // script can make the toggles idempotent (only enter/exit when needed).
        let node = ControlWindowNode(id: "w1", name: "work", open: true, active: true, fullscreen: true, zoomed: false)
        let response = ControlResponse(ok: true, result: ControlResult(windows: [node]))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.windows?.first?.fullscreen == true)
        #expect(decoded.result?.windows?.first?.zoomed == false)
    }

    @Test func windowNodeOmitsFullscreenAndZoomWhenNil() throws {
        // a closed window with no live NSWindow — both keys must be omitted, not emitted as null.
        let node = ControlWindowNode(id: "w1", name: "work", open: false, active: false)
        let json = String(data: try JSONEncoder().encode(node), encoding: .utf8) ?? ""
        #expect(!json.contains("fullscreen"), "a nil fullscreen must be omitted from the JSON; got \(json)")
        #expect(!json.contains("zoomed"), "a nil zoomed must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlWindowNode.self, from: Data(json.utf8))
        #expect(decoded.fullscreen == nil)
        #expect(decoded.zoomed == nil)
    }

    @Test func workspaceNodeRoundTripsWithFocused() throws {
        // the read side of workspace.focus: the sidebar-focused workspace is flagged so a script can record
        // which one is focused and restore it (distinct from `active`, the selected workspace).
        let ws = ControlWorkspaceNode(id: "w1", name: "work", active: true, focused: true, sessions: [])
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(workspaces: [ws])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.focused == true)
    }

    @Test func workspaceNodeOmitsFocusedWhenNil() throws {
        // not the focused workspace (or none focused) — the key must be omitted, not emitted as null.
        let ws = ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [])
        let json = String(data: try JSONEncoder().encode(ws), encoding: .utf8) ?? ""
        #expect(!json.contains("focused"), "a nil focused must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlWorkspaceNode.self, from: Data(json.utf8))
        #expect(decoded.focused == nil)
    }

    @Test func treeRoundTripsWithSidebarMode() throws {
        // the read side of sidebar.mode: the sidebar view mode (tree/flagged) rides the tree top level.
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [], sidebarMode: "flagged")))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.sidebarMode == "flagged")
    }

    @Test func treeRoundTripsWithQuickVisible() throws {
        // the read side of quick: the quick-terminal visibility rides the tree top level so a script can
        // make the toggle idempotent.
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [], quickVisible: true)))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.quickVisible == true)
    }

    @Test func treeOmitsQuickVisibleWhenNil() throws {
        // a host-produced tree with no app closure — the key must be omitted, not emitted as null.
        let tree = ControlTree(workspaces: [])
        let json = String(data: try JSONEncoder().encode(tree), encoding: .utf8) ?? ""
        #expect(!json.contains("quickVisible"), "a nil quickVisible must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlTree.self, from: Data(json.utf8))
        #expect(decoded.quickVisible == nil)
    }

    @Test func treeRoundTripsWithZoomedSurface() throws {
        // the read side of surface.zoom: the zoomed surface's control id rides the tree top level so a
        // script can check "is it already zoomed" and record-then-restore.
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [], zoomedSurface: "surface:5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9:right")))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.zoomedSurface == "surface:5E5B1C5B-75C5-49E6-8806-2C61D8D6BBA9:right")
    }

    @Test func treeOmitsZoomedSurfaceWhenNil() throws {
        // nothing zoomed (or a host-produced tree with no app closure) — the key must be omitted, not null.
        let tree = ControlTree(workspaces: [])
        let json = String(data: try JSONEncoder().encode(tree), encoding: .utf8) ?? ""
        #expect(!json.contains("zoomedSurface"), "a nil zoomedSurface must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlTree.self, from: Data(json.utf8))
        #expect(decoded.zoomedSurface == nil)
    }

    @Test func dashboardRequestRoundTrips() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["9f3c", "abcd"])),
            ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["9f3c"], window: "win", fontSize: 12)),
            ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["9f3c", "abcd"], autoSize: true)),
            ControlRequest(cmd: .dashboard, args: ControlArgs(close: true)),
            ControlRequest(cmd: .dashboard, args: ControlArgs(window: "win", autoSize: true, mru: true)),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
        let opened = try roundTrip(ControlRequest(cmd: .dashboard,
                                                  args: ControlArgs(targets: ["a", "b"], fontSize: 14)))
        #expect(opened.args?.targets == ["a", "b"])
        #expect(opened.args?.fontSize == 14)
        #expect(opened.args?.autoSize == nil)
        #expect(opened.args?.mru == nil)
        let closed = try roundTrip(ControlRequest(cmd: .dashboard, args: ControlArgs(close: true)))
        #expect(closed.args?.close == true)
        let mru = try roundTrip(ControlRequest(cmd: .dashboard, args: ControlArgs(mru: true)))
        #expect(mru.args?.mru == true)
        #expect(mru.args?.targets == nil)
    }

    @Test func dashboardArgsOmitFieldsWhenNil() throws {
        // the new fields ride Bool?/Double? for the omit-when-nil wire contract: an open request with only
        // targets must not emit close/fontSize/autoSize at all.
        let request = ControlRequest(cmd: .dashboard, args: ControlArgs(targets: ["9f3c"]))
        let json = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
        #expect(!json.contains("close"), "a nil close must be omitted from the JSON; got \(json)")
        #expect(!json.contains("fontSize"), "a nil fontSize must be omitted from the JSON; got \(json)")
        #expect(!json.contains("autoSize"), "a nil autoSize must be omitted from the JSON; got \(json)")
        #expect(!json.contains("mru"), "a nil mru must be omitted from the JSON; got \(json)")
    }

    @Test func treeRoundTripsWithDashboardFields() throws {
        // the read side of dashboard: members / highlighted / applied font / mode ride the tree top level so
        // a script can read the live grid state. Members/highlighted are pane refs (`<uuid>:left`/`:right`) —
        // a split session appears as both its `:left` and `:right` cells. LIVE, tree-only like zoomedSurface.
        let members = ["9f3c:left", "9f3c:right", "abcd:left"]
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [], dashboardMembers: members, dashboardHighlighted: "9f3c:right",
            dashboardFontSize: 12, dashboardFontMode: "auto")))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        let tree = decoded.result?.tree
        #expect(tree?.dashboardMembers == members)
        #expect(tree?.dashboardHighlighted == "9f3c:right")
        #expect(tree?.dashboardFontSize == 12)
        #expect(tree?.dashboardFontMode == "auto")
    }

    @Test func treeOmitsDashboardFieldsWhenNil() throws {
        // no dashboard open (or a host-produced tree with no app closure) — the keys must be omitted, not null.
        let tree = ControlTree(workspaces: [])
        let json = String(data: try JSONEncoder().encode(tree), encoding: .utf8) ?? ""
        #expect(!json.contains("dashboardMembers"), "a nil dashboardMembers must be omitted; got \(json)")
        #expect(!json.contains("dashboardHighlighted"), "a nil dashboardHighlighted must be omitted; got \(json)")
        #expect(!json.contains("dashboardFontSize"), "a nil dashboardFontSize must be omitted; got \(json)")
        #expect(!json.contains("dashboardFontMode"), "a nil dashboardFontMode must be omitted; got \(json)")
        let decoded = try JSONDecoder().decode(ControlTree.self, from: Data(json.utf8))
        #expect(decoded.dashboardMembers == nil)
        #expect(decoded.dashboardHighlighted == nil)
        #expect(decoded.dashboardFontSize == nil)
        #expect(decoded.dashboardFontMode == nil)
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

    @Test func sessionMoveRoundTripsWithAfterAnchor() throws {
        let request = ControlRequest(cmd: .sessionMove, target: "9f3c", args: ControlArgs(after: "active"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.after == "active")
        #expect(decoded.args?.before == nil)
        #expect(decoded.args?.to == nil)
        #expect(decoded.args?.workspace == nil)
    }

    @Test func sessionMoveRoundTripsWithBeforeAnchor() throws {
        let request = ControlRequest(cmd: .sessionMove, target: "9f3c", args: ControlArgs(before: "1a2b"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.before == "1a2b")
        #expect(decoded.args?.after == nil)
    }

    @Test func sessionNewRoundTripsWithAfterAnchor() throws {
        let request = ControlRequest(cmd: .sessionNew, args: ControlArgs(after: "active"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.after == "active")
        #expect(decoded.args?.before == nil)
        #expect(decoded.args?.workspace == nil)
    }

    @Test func sessionNewRoundTripsWithBeforeAnchor() throws {
        let request = ControlRequest(cmd: .sessionNew, args: ControlArgs(before: "1a2b"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.before == "1a2b")
        #expect(decoded.args?.after == nil)
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
            ControlRequest(cmd: .windowFullscreen, target: "9f3c"),
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

    @Test func responseOkWithAffectedRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(affected: 2))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.affected == 2)
        #expect(decoded.result?.count == nil)
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

    @Test func themeSetSyncRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .themeSet, args: ControlArgs(light: "Builtin Light", dark: "agterm"))
        let decoded = try roundTrip(request)
        #expect(decoded.cmd == .themeSet)
        #expect(decoded.args?.light == "Builtin Light")
        #expect(decoded.args?.dark == "agterm")
        #expect(decoded.args?.name == nil)
    }

    @Test func themeListResponseCarriesSyncState() throws {
        let response = ControlResponse(ok: true, result: ControlResult(
            theme: "agterm", themes: ["agterm", "Builtin Light"], sync: true, light: "Builtin Light", dark: "agterm"))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.sync == true)
        #expect(decoded.result?.light == "Builtin Light")
        #expect(decoded.result?.dark == "agterm")
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
