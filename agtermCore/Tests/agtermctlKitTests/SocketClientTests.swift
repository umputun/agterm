import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

// serialized: the stdout-capturing tests redirect the process-global STDOUT_FILENO, so in parallel
// one test's output lands in the other's pipe.
@Suite(.serialized)
struct SocketClientTests {
    @Test func consecutiveEventReadsUseIndependentOneShotConnections() throws {
        let run = UUID(uuidString: "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1")!
        let script = EventReadScript(run: run)
        let server = ScriptedStubServer(responder: script.respond)
        try server.start()
        defer { server.stop() }
        let client = SocketClient(path: server.path)

        let first = try client.send(ControlRequest(cmd: .eventsRead))
        let anchor = try #require(first.result?.events)
        let second = try client.send(ControlRequest(
            cmd: .eventsRead, args: ControlArgs(after: String(anchor.next), run: anchor.run.uuidString)
        ))

        #expect(second.result?.events?.next == 8)
        #expect(script.requests().map { $0.args?.after } == [nil, "7"])
    }

    @Test func roundTripOkResponse() throws {
        let canned = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let server = StubServer(response: canned)
        try server.start()
        defer { server.stop() }

        let client = SocketClient(path: server.path)
        let response = try client.send(ControlRequest(cmd: .sessionSelect, target: "active"))

        #expect(response.ok)
        #expect(response.result?.id == "9f3c")
        #expect(server.received?.cmd == .sessionSelect)
        #expect(server.received?.target == "active")
    }

    @Test func roundTripErrorResponse() throws {
        let canned = ControlResponse(ok: false, error: "cannot delete last workspace")
        let server = StubServer(response: canned)
        try server.start()
        defer { server.stop() }

        let client = SocketClient(path: server.path)
        let response = try client.send(ControlRequest(cmd: .workspaceDelete, target: "active"))

        #expect(!response.ok)
        #expect(response.error == "cannot delete last workspace")
    }

    // a `session.text --all` payload exceeds the old 1 MiB read cap; it must round-trip, not fail.
    @Test func roundTripLargeResponse() throws {
        let big = String(repeating: "scrollback line\n", count: 200_000) // ~3 MiB, well over 1 MiB
        let server = StubServer(response: ControlResponse(ok: true, result: ControlResult(text: big)))
        try server.start()
        defer { server.stop() }

        let client = SocketClient(path: server.path)
        let response = try client.send(ControlRequest(cmd: .sessionText, target: "active"))

        #expect(response.ok)
        #expect(response.result?.text == big)
    }

    @Test func connectFailureToMissingSocketThrows() {
        let client = SocketClient(path: NSTemporaryDirectory() + "agterm-missing-\(UUID().uuidString.prefix(8)).sock")
        #expect(throws: SocketClientError.self) { try client.send(ControlRequest(cmd: .tree)) }
    }

    @Test func oversizedRequestFailsBeforeConnecting() {
        let missing = NSTemporaryDirectory() + "agterm-missing-\(UUID().uuidString.prefix(8)).sock"
        let big = String(repeating: "x", count: ControlWire.maxRequestLineBytes + 1)
        let client = SocketClient(path: missing)

        do {
            _ = try client.send(ControlRequest(cmd: .sessionType, target: "active", args: ControlArgs(text: big)))
            Issue.record("expected an oversized request to fail")
        } catch let error as SocketClientError {
            // the size check must fire before connect: a connect error would say "is agterm running?"
            #expect(error.description.hasPrefix("request too large"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // the server hangs up mid-request when it rejects an oversized line; without SO_NOSIGPIPE the
    // client's next write raises the default-fatal SIGPIPE and the process dies with no output.
    @Test func writeToHungUpPeerThrowsInsteadOfDying() throws {
        let server = HangUpStubServer()
        try server.start()
        defer { server.stop() }
        // under the request cap but far over the socket buffer, so writeAll is mid-write when the close lands
        let payload = String(repeating: "x", count: 900_000)
        let client = SocketClient(path: server.path)

        do {
            _ = try client.send(ControlRequest(cmd: .sessionType, target: "active", args: ControlArgs(text: payload)))
            Issue.record("expected the write to a hung-up peer to fail")
        } catch let error as SocketClientError {
            #expect(error.description.hasPrefix("write failed"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func socketPathLimitMatchesPlatformCapacity() {
        let addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let fittingPath = "/" + String(repeating: "x", count: capacity - 2)
        let oversizedPath = "/" + String(repeating: "x", count: capacity - 1)

        do {
            _ = try SocketClient(path: fittingPath).send(ControlRequest(cmd: .tree))
            Issue.record("expected connect to a missing socket to fail")
        } catch let error as SocketClientError {
            #expect(!error.description.hasPrefix("socket path too long"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        do {
            _ = try SocketClient(path: oversizedPath).send(ControlRequest(cmd: .tree))
            Issue.record("expected an oversized socket path to fail")
        } catch let error as SocketClientError {
            #expect(error.description.hasPrefix("socket path too long"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func formatsKeymapWithEveryActionAndTheLiveMenu() {
        let keymap = Keymap(builtinOverrides: [.closeSession: Chord(mods: [.command], key: "e")], commands: [])
        let payload = ControlKeymap.project(
            keymap: keymap, diagnostics: [KeymapDiagnostic(line: 3, message: "unknown action")],
            path: "/tmp/keymap.conf",
            menu: [ControlKeymapMenuItem(menu: "File", title: "Close", chord: "cmd+w", selector: "performClose:")]
        )

        let out = SocketClient.formatKeymap(payload)

        #expect(out.contains("keymap: /tmp/keymap.conf"))
        #expect(out.contains("* close_session"), "an overridden action is marked")
        #expect(out.contains("cmd+e"))
        #expect(out.contains("line 3: unknown action"))
        #expect(out.contains("cmd+w  File ▸ Close"), "the live menu chord is listed for comparison")
        // every action appears, keyless ones included, so the listing is the whole set
        for action in BuiltinAction.allCases { #expect(out.contains(action.rawValue)) }
    }

    // line 0 is the whole-file sentinel, not a real line (SettingsView.diagnosticLine drops it too).
    @Test func formatsKeymapDroppingTheLineNumberForWholeFileDiagnostics() {
        let payload = ControlKeymap.project(
            keymap: Keymap(builtinOverrides: [:], commands: []),
            diagnostics: [KeymapDiagnostic(line: 0, message: "conflicts with a built-in; keybind dropped"),
                          KeymapDiagnostic(line: 7, message: "unknown action")],
            path: "/tmp/keymap.conf"
        )

        let out = SocketClient.formatKeymap(payload)

        #expect(out.contains("    conflicts with a built-in; keybind dropped"))
        #expect(!out.contains("line 0"), "the sentinel must not be printed as a line number")
        #expect(out.contains("line 7: unknown action"), "a real line number is still shown")
    }

    // a disabled item's chord is inert, so the marker is the one fact that explains a dead binding.
    @Test func formatsKeymapMarkingDisabledMenuItems() {
        let payload = ControlKeymap.project(
            keymap: Keymap(builtinOverrides: [:], commands: []), diagnostics: [], path: "/tmp/keymap.conf",
            menu: [ControlKeymapMenuItem(menu: "Navigate", title: "Focus Left Pane", chord: "cmd+opt+left",
                                         selector: "menuAction:", enabled: false),
                   ControlKeymapMenuItem(menu: "File", title: "New Session", chord: "cmd+n",
                                         selector: "menuAction:")]
        )

        let out = SocketClient.formatKeymap(payload)

        #expect(out.contains("cmd+opt+left  Navigate ▸ Focus Left Pane  (disabled)"))
        #expect(out.contains("cmd+n  File ▸ New Session\n") || out.hasSuffix("cmd+n  File ▸ New Session"),
                "an enabled row carries no marker")
    }

    @Test func formatsKeymapJoiningAlternativesWithTheFilesOwnSeparator() {
        let parsed = parseKeymap("map cmd+t|ctrl+space>s toggle_split\nmap ctrl+a>g toggle_sidebar")
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: parsed.diagnostics,
                                            path: "/tmp/keymap.conf")

        let out = SocketClient.formatKeymap(payload)
        func binds(_ action: String) -> String? {
            out.split(separator: "\n").first { $0.contains(" \(action) ") }?
                .split(separator: " ").last.map(String.init)
        }

        #expect(binds("toggle_split") == "cmd+t|ctrl+space>s")
        #expect(binds("toggle_sidebar") == "ctrl+a>g", "an unbound action lists its alternatives alone")
        #expect(binds("first_session") == "-", "an action with no binding at all still prints a dash")
    }

    // the compatibility invariant: the same `|`-free fixture agtermCoreTests pins, rendered exactly as the
    // pre-alternatives formatter rendered it — every expected byte below came from that formatter.
    @Test func formatsAPipeFreeKeymapByteIdenticallyToThePreAlternativesOutput() {
        let fixture = """
        # regression fixture: no `|` anywhere, no multi-chord map
        map cmd+shift+e toggle_split
        map t toggle_sidebar
        map ctrl+cmd+left focus_left_pane
        map cmd+w new_session

        command "Deploy" cmd+shift+y ./deploy.sh
        command "Open Notes" vim {AGT_SESSION_PWD}/notes.md
        command "Clash" command+shift+e echo clash
        command "First" control+shift+g echo one
        command "Second" ctrl+shift+g echo two
        """
        let parsed = parseKeymap(fixture)
        let payload = ControlKeymap.project(keymap: parsed.keymap, diagnostics: parsed.diagnostics,
                                            path: "/tmp/keymap.conf")

        #expect(SocketClient.formatKeymap(payload) == """
        keymap: /tmp/keymap.conf

        actions:
            new_window                  cmd+opt+n
            rename_window               -
            delete_window               -
            new_workspace               cmd+shift+n
            rename_workspace            -
            delete_workspace            -
            new_session                 cmd+n
            open_directory              cmd+o
            rename_session              -
            duplicate_session           -
            close_session               cmd+w
            reopen_recent               cmd+shift+t
            undo_close                  cmd+z
            clear_status                -
            increase_font_size          cmd++
            decrease_font_size          cmd+-
            reset_font_size             cmd+0
          * toggle_split                cmd+shift+e
            toggle_scratch              cmd+j
            toggle_terminal_zoom        cmd+shift+return
            toggle_search               cmd+f
          * toggle_sidebar              t
            select_theme                -
            toggle_fullscreen           ctrl+cmd+f
            toggle_flagged_view         -
            toggle_flag                 cmd+shift+f
            focus_workspace             -
            toggle_workspace_filter     -
          * focus_left_pane             ctrl+cmd+left
            focus_right_pane            cmd+opt+right
            previous_session            cmd+opt+up
            next_session                cmd+opt+down
            previous_attention_session  ctrl+opt+up
            next_attention_session      ctrl+opt+down
            first_session               -
            last_session                -
            quick_terminal              ctrl+`
            session_palette             ctrl+p
            command_palette             ctrl+shift+p
            custom_command_palette      ctrl+shift+o
            show_attention              ctrl+shift+i
            dashboard                   cmd+shift+d

        commands:
            Deploy  cmd+shift+y
            Open Notes  (palette only)
            Clash  (palette only)
            First  (palette only)
            Second  (palette only)

        diagnostics:
            line 5: chord conflicts with built-in 'close_session'; map skipped
            custom command 'Clash' shortcut 'command+shift+e' conflicts with a built-in; keybind dropped
            custom command 'First' shortcut 'control+shift+g' conflicts with custom command 'Second'; keybind dropped
            custom command 'Second' shortcut 'ctrl+shift+g' conflicts with custom command 'First'; keybind dropped
        """)
    }

    @Test func formatsKeymapWithoutOptionalSectionsWhenEmpty() {
        let payload = ControlKeymap.project(keymap: Keymap(builtinOverrides: [:], commands: []),
                                            diagnostics: [], path: "/tmp/keymap.conf")

        let out = SocketClient.formatKeymap(payload)

        #expect(!out.contains("commands:"))
        #expect(!out.contains("diagnostics:"))
        #expect(!out.contains("menu:"), "menu is omitted, not printed empty, when the caller supplied none")
        #expect(out.contains("close_session"))
    }

    @Test func formatResponsePicksTheKeymapRenderer() {
        let payload = ControlKeymap.project(keymap: Keymap(builtinOverrides: [:], commands: []),
                                            diagnostics: [], path: "/tmp/keymap.conf")
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(keymap: payload)),
                                              json: false)
        #expect(out.hasPrefix("keymap: /tmp/keymap.conf"))
    }

    @Test func runEchoesNewIdForCreateCommand() throws {
        let server = StubServer(response: ControlResponse(ok: true, result: ControlResult(id: "9f3c")))
        try server.start()
        defer { server.stop() }

        let command = try Session.New.parse(["--socket", server.path])
        let printed = try captureStdout { try command.run() }
        #expect(printed == "9f3c\n")
    }

    @Test func runQuietsIdForNonCreateCommand() throws {
        let server = StubServer(response: ControlResponse(ok: true, result: ControlResult(id: "9f3c")))
        try server.start()
        defer { server.stop() }

        let command = try Tree.parse(["--socket", server.path])
        let printed = try captureStdout { try command.run() }
        #expect(printed == "ok\n")
    }

    /// Runs `body` with the process stdout redirected to a pipe, returning everything it printed.
    private func captureStdout(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        defer { close(saved) }
        fflush(nil)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        try body()
        fflush(nil)
        dup2(saved, STDOUT_FILENO)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test func runThrowsExitCodeFailureOnErrorResponse() throws {
        let server = StubServer(response: ControlResponse(ok: false, error: "boom"))
        try server.start()
        defer { server.stop() }

        let command = try Tree.parse(["--socket", server.path, "--json"])
        #expect(throws: ExitCode.failure) { try command.run() }
    }

    // drives the real run() against a scripted multi-connection server: open, poll, exit with the status.
    @Test func blockPollsResultThenExitsWithStatus() throws {
        let script = OverlayResultScript(stillRunningTimes: 1,
                                         finalResult: ControlResponse(ok: true, result: ControlResult(id: "abc", exitCode: 7)))
        let server = ScriptedStubServer(responder: script.respond)
        try server.start()
        defer { server.stop() }

        let command = try Session.Overlay.Open.parse(["echo", "--block", "--socket", server.path])
        do {
            try command.run()
            Issue.record("expected --block to exit with the program's status")
        } catch let code as ExitCode {
            #expect(code.rawValue == 7)
        }
    }

    // an ok result with no exitCode is a protocol violation → --block fails, never exits 0.
    @Test func blockFailsWhenResultMissingExitCode() throws {
        let script = OverlayResultScript(stillRunningTimes: 0,
                                         finalResult: ControlResponse(ok: true, result: ControlResult(id: "abc")))
        let server = ScriptedStubServer(responder: script.respond)
        try server.start()
        defer { server.stop() }

        let command = try Session.Overlay.Open.parse(["echo", "--block", "--socket", server.path])
        #expect(throws: ExitCode.failure) { try command.run() }
    }

    @Test func blockFailsWhenOpenFails() throws {
        let server = ScriptedStubServer { req in
            req.cmd == .sessionOverlayOpen
                ? ControlResponse(ok: false, error: "overlay already open")
                : ControlResponse(ok: false, error: "unexpected")
        }
        try server.start()
        defer { server.stop() }

        let command = try Session.Overlay.Open.parse(["echo", "--block", "--socket", server.path])
        #expect(throws: ExitCode.failure) { try command.run() }
    }

    @Test func formatsPickIDAsJSON() throws {
        let line = try SocketClient.formatPickID("pick-1")
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])

        #expect(object == ["id": "pick-1"])
    }

    @Test func formatsPickResultAsJSON() throws {
        let result = ControlPickResult(result: .picked, id: "two", label: "Two", index: 1)
        let line = try SocketClient.formatPickResult(result)

        #expect(try JSONDecoder().decode(ControlPickResult.self, from: Data(line.utf8)) == result)
    }

    @Test(arguments: [
        (ControlPickOutcome.pending, Int32(1)),
        (.picked, Int32(0)),
        (.custom, Int32(0)),
        (.cancelled, Int32(2))
    ])
    func pickExitCodeMapsEveryOutcome(_ outcome: ControlPickOutcome, _ expected: Int32) {
        #expect(SocketClient.pickExitCode(for: outcome).rawValue == expected)
    }

    @Test func pickPollBackoffUsesTenFastSleepsThenSlowSleeps() {
        #expect((1...10).map(SocketClient.pickPollDelay(afterPendingPoll:)) ==
            Array(repeating: 0.1, count: 10))
        #expect(SocketClient.pickPollDelay(afterPendingPoll: 11) == 0.5)
        #expect(SocketClient.pickPollDelay(afterPendingPoll: 100) == 0.5)
    }

    @Test func pickNoBlockPrintsIDWithoutPolling() throws {
        let command = try Pick.Open.parse(["--no-block"])
        var requests: [ControlRequest] = []
        var output: [String] = []

        try command.execute(
            input: Data("One\n".utf8),
            send: { request in
                requests.append(request)
                return ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
            },
            sleep: { _ in Issue.record("--no-block must not sleep") },
            output: { output.append($0) }
        )

        #expect(requests == [
            ControlRequest(
                cmd: .pickOpen,
                args: ControlArgs(items: [ControlPickItem(id: "One", label: "One")])
            )
        ])
        #expect(try JSONSerialization.jsonObject(with: Data(#require(output.first).utf8)) as? [String: String] ==
            ["id": "pick-1"])
    }

    @Test func pickBlockPollsWithBackoffPrintsResultAndExitsZero() throws {
        let command = try Pick.Open.parse(["--window", "w1"])
        var requests: [ControlRequest] = []
        var sleeps: [TimeInterval] = []
        var output: [String] = []
        var polls = 0

        try command.execute(
            input: Data("One\n".utf8),
            send: { request in
                requests.append(request)
                if request.cmd == .pickOpen {
                    return ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                }
                polls += 1
                if polls <= 11 {
                    return ControlResponse(ok: true, result: ControlResult(
                        pick: ControlPickResult(result: .pending)
                    ))
                }
                return ControlResponse(ok: true, result: ControlResult(
                    pick: ControlPickResult(result: .picked, id: "One", label: "One", index: 0)
                ))
            },
            sleep: { sleeps.append($0) },
            output: { output.append($0) }
        )

        #expect(requests.dropFirst().allSatisfy {
            $0 == ControlRequest(cmd: .pickResult, target: "pick-1")
        })
        #expect(sleeps == Array(repeating: 0.1, count: 10) + [0.5])
        let result = try JSONDecoder().decode(
            ControlPickResult.self,
            from: Data(#require(output.first).utf8)
        )
        #expect(result == ControlPickResult(result: .picked, id: "One", label: "One", index: 0))
    }

    @Test func pickBlockThrowsCancelledExitCodeAfterPrintingResult() throws {
        let command = try Pick.Open.parse([])
        var output: [String] = []

        do {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    request.cmd == .pickOpen
                        ? ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                        : ControlResponse(ok: true, result: ControlResult(
                            pick: ControlPickResult(result: .cancelled)
                        ))
                },
                sleep: { _ in Issue.record("a terminal result must not sleep") },
                output: { output.append($0) }
            )
            Issue.record("expected the cancelled exit code")
        } catch let code as ExitCode {
            #expect(code.rawValue == 2)
        }

        let result = try JSONDecoder().decode(
            ControlPickResult.self,
            from: Data(#require(output.first).utf8)
        )
        #expect(result.result == .cancelled)
    }

    @Test func pickBlockFailsForOpenErrorAndMalformedResult() throws {
        let command = try Pick.Open.parse([])
        var errors: [String] = []
        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { _ in ControlResponse(ok: false, error: "boom") },
                sleep: { _ in },
                output: { _ in Issue.record("a non-JSON server error must not use stdout") },
                errorOutput: { errors.append($0) }
            )
        }
        #expect(errors == ["error: boom"])

        errors.removeAll()
        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    request.cmd == .pickOpen
                        ? ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                        : ControlResponse(ok: true)
                },
                sleep: { _ in },
                output: { _ in Issue.record("a protocol error must not use stdout") },
                errorOutput: { errors.append($0) }
            )
        }
        #expect(errors == ["error: pick.result missing result"])
    }

    @Test func pickBlockCancelsThePickerItCanNoLongerWaitOn() throws {
        let command = try Pick.Open.parse([])
        var sent: [ControlRequest] = []
        // ok, but with no pick payload: the server still holds the picker, so it must be dismissed.
        let malformedPoll: (ControlRequest) throws -> ControlResponse = { request in
            sent.append(request)
            return request.cmd == .pickOpen
                ? ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                : ControlResponse(ok: true)
        }

        #expect(throws: ExitCode.failure) {
            try command.execute(input: Data("One\n".utf8), send: malformedPoll,
                                sleep: { _ in }, output: { _ in }, errorOutput: { _ in })
        }
        #expect(sent.map(\.cmd) == [.pickOpen, .pickResult, .pickCancel],
                "a poll that cannot continue must dismiss the picker it opened")
        #expect(sent.last?.target == "pick-1")

        sent.removeAll()
        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    guard request.cmd != .pickCancel else { throw SocketClientError("socket gone") }
                    return try malformedPoll(request)
                },
                sleep: { _ in }, output: { _ in }, errorOutput: { _ in }
            )
        }
        #expect(sent.map(\.cmd) == [.pickOpen, .pickResult],
                "a failing cancel is best effort and must not replace the poll failure")
    }

    @Test func pickBlockDoesNotCancelWhenTheServerAlreadyLostThePicker() throws {
        let command = try Pick.Open.parse([])
        var sent: [ControlRequest] = []

        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    sent.append(request)
                    return request.cmd == .pickOpen
                        ? ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                        : ControlResponse(ok: false, error: "unknown pick: pick-1")
                },
                sleep: { _ in }, output: { _ in }, errorOutput: { _ in }
            )
        }

        #expect(sent.map(\.cmd) == [.pickOpen, .pickResult],
                "the poll carries no window selector, so a not-ok result means there is nothing left to cancel")
    }

    @Test func pickBlockCancelsWhenThePollItselfThrows() throws {
        let command = try Pick.Open.parse([])
        var sent: [ControlRequest] = []

        #expect(throws: SocketClientError.self) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    sent.append(request)
                    switch request.cmd {
                    case .pickOpen: return ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                    case .pickResult: throw SocketClientError("no response from /tmp/agterm.sock")
                    default: return ControlResponse(ok: true)
                    }
                },
                sleep: { _ in }, output: { _ in }, errorOutput: { _ in }
            )
        }

        #expect(sent.map(\.cmd) == [.pickOpen, .pickResult, .pickCancel],
                "a transport failure mid-wait must still dismiss the picker rather than leave it pending")
        #expect(sent.last?.target == "pick-1")
    }

    @Test func pickBlockRoutesJSONServerErrorThroughInjectedStdout() throws {
        let command = try Pick.Open.parse(["--json"])
        var output: [String] = []

        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { _ in ControlResponse(ok: false, error: "boom") },
                sleep: { _ in },
                output: { output.append($0) },
                errorOutput: { _ in Issue.record("a JSON server error must not use stderr") }
            )
        }

        let response = try JSONDecoder().decode(ControlResponse.self, from: Data(#require(output.first).utf8))
        #expect(!response.ok)
        #expect(response.error == "boom")
    }

    @Test(arguments: [
        (ControlPickOutcome.picked, Int32(0)),
        (.custom, Int32(0)),
        (.pending, Int32(1)),
        (.cancelled, Int32(2)),
    ])
    func pickResultExecutesRequestPrintsJSONAndMapsExit(
        _ outcome: ControlPickOutcome,
        _ expectedExit: Int32
    ) throws {
        let command = try Pick.Result.parse(["pick-1", "--window", "w1"])
        var request: ControlRequest?
        var output: [String] = []
        let run = {
            try command.execute(
                send: {
                    request = $0
                    return ControlResponse(ok: true, result: ControlResult(
                        pick: ControlPickResult(result: outcome)
                    ))
                },
                output: { output.append($0) }
            )
        }

        if expectedExit == 0 {
            try run()
        } else {
            do {
                try run()
                Issue.record("expected mapped exit \(expectedExit)")
            } catch let code as ExitCode {
                #expect(code.rawValue == expectedExit)
            }
        }
        #expect(request == ControlRequest(
            cmd: .pickResult,
            target: "pick-1",
            args: ControlArgs(window: "w1")
        ))
        #expect(try JSONDecoder().decode(
            ControlPickResult.self,
            from: Data(#require(output.first).utf8)
        ).result == outcome)
    }

    @Test func pickResultRoutesServerAndProtocolErrorsThroughInjectedStderr() throws {
        let command = try Pick.Result.parse(["pick-1"])
        var errors: [String] = []

        #expect(throws: ExitCode.failure) {
            try command.execute(
                send: { _ in ControlResponse(ok: false, error: "boom") },
                output: { _ in Issue.record("a non-JSON server error must not use stdout") },
                errorOutput: { errors.append($0) }
            )
        }
        #expect(errors == ["error: boom"])

        errors.removeAll()
        #expect(throws: ExitCode.failure) {
            try command.execute(
                send: { _ in ControlResponse(ok: true) },
                output: { _ in Issue.record("a protocol error must not use stdout") },
                errorOutput: { errors.append($0) }
            )
        }
        #expect(errors == ["error: pick.result missing result"])
    }

    @Test func pickResultRoutesJSONServerErrorThroughInjectedStdout() throws {
        let command = try Pick.Result.parse(["pick-1", "--json"])
        var output: [String] = []

        #expect(throws: ExitCode.failure) {
            try command.execute(
                send: { _ in ControlResponse(ok: false, error: "boom") },
                output: { output.append($0) },
                errorOutput: { _ in Issue.record("a JSON server error must not use stderr") }
            )
        }

        let response = try JSONDecoder().decode(ControlResponse.self, from: Data(#require(output.first).utf8))
        #expect(!response.ok)
        #expect(response.error == "boom")
    }

    @Test func formatResponseBareOk() {
        #expect(SocketClient.formatResponse(ControlResponse(ok: true), json: false) == "ok")
    }

    @Test func formatResponseEchoesIdWhenRequested() {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        #expect(SocketClient.formatResponse(response, json: false, echoID: true) == "9f3c")
    }

    @Test func formatResponseSuppressesIdByDefault() {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        #expect(SocketClient.formatResponse(response, json: false) == "ok")
    }

    @Test func formatResponseText() {
        let response = ControlResponse(ok: true, result: ControlResult(text: "selected\nlines"))
        #expect(SocketClient.formatResponse(response, json: false) == "selected\nlines")
    }

    @Test func formatResponseZeroCountIsOk() {
        // keymap.reload reports a parse-diagnostic count; 0 reads as a clean reload.
        let response = ControlResponse(ok: true, result: ControlResult(count: 0))
        #expect(SocketClient.formatResponse(response, json: false) == "ok")
    }

    @Test func formatResponseNonZeroCountPluralizes() {
        let response = ControlResponse(ok: true, result: ControlResult(count: 3))
        #expect(SocketClient.formatResponse(response, json: false) == "3 diagnostic(s)")
    }

    @Test(arguments: [(1, "1 session"), (2, "2 sessions"), (0, "0 sessions")])
    func formatResponseAffectedSessions(_ affected: Int, _ expected: String) {
        let response = ControlResponse(ok: true, result: ControlResult(affected: affected))
        #expect(SocketClient.formatResponse(response, json: false) == expected)
    }

    @Test func formatResponseError() {
        #expect(SocketClient.formatResponse(ControlResponse(ok: false, error: "boom"), json: false) == "error: boom")
    }

    @Test func formatResponseRatio() {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c", ratio: 0.85))
        #expect(SocketClient.formatResponse(response, json: false) == "0.850")
    }

    @Test func formatResponseErrorFallback() {
        #expect(SocketClient.formatResponse(ControlResponse(ok: false), json: false) == "error: unknown error")
    }

    @Test func formatResponseJSONIsRaw() throws {
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c"))
        let line = SocketClient.formatResponse(response, json: true)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
        #expect(decoded.ok)
        #expect(decoded.result?.id == "9f3c")
    }

    @Test func formatResponseTree() {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: true)
        let workspace = ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "* work  [w1]")
        #expect(lines[1] == "  * shell (split)  [s1]  /tmp")
    }

    @Test func formatTreeTagsHiddenSplit() {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         hasSplit: true)
        let workspace = ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[1] == "  * shell (split hidden)  [s1]  /tmp")
    }

    @Test func formatTreeTagsAnUnrealizedSession() {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         realized: false)
        let workspace = ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[1] == "  * shell (not realized)  [s1]  /tmp")
    }

    @Test func formatTreeLeavesARealizedSessionUntagged() {
        let session = ControlSessionNode(id: "s2", name: "shell", cwd: "/tmp", active: true, split: false,
                                         realized: true)
        let workspace = ControlWorkspaceNode(id: "w2", name: "work", active: true, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[1] == "  * shell  [s2]  /tmp", "only the failing state earns a tag; nil must stay quiet too")
    }

    @Test func formatTreeShowsScratchTag() {
        let session = ControlSessionNode(id: "s3", name: "shell", cwd: "/tmp", active: true, split: false,
                                         overlay: false, scratch: true)
        let workspace = ControlWorkspaceNode(id: "w3", name: "work", active: true, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[1] == "  * shell (scratch)  [s3]  /tmp")
    }

    @Test func formatTreeMarksInactive() {
        let session = ControlSessionNode(id: "s2", name: "logs", cwd: "/var", active: false, split: false)
        let workspace = ControlWorkspaceNode(id: "w2", name: "other", active: false, sessions: [session])
        let tree = ControlTree(workspaces: [workspace])
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(tree: tree)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "  other  [w2]")
        #expect(lines[1] == "    logs  [s2]  /var")
    }

    @Test func formatResponseWindows() {
        let windows = [
            ControlWindowNode(id: "w1", name: "work", open: true, active: true),
            ControlWindowNode(id: "w2", name: "personal", open: true, active: false),
            ControlWindowNode(id: "w3", name: "archive", open: false, active: false),
            // a closed-but-active window (a frontmost id not yet loaded) renders [active] without [open].
            ControlWindowNode(id: "w4", name: "pending", open: false, active: true),
        ]
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(windows: windows)), json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "w1  work [open] [active]")
        #expect(lines[1] == "w2  personal [open]")
        #expect(lines[2] == "w3  archive")
        #expect(lines[3] == "w4  pending [active]")
    }

    @Test func formatResponseEmptyWindows() {
        let out = SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(windows: [])), json: false)
        // a present-but-empty `windows` payload still takes the windows branch, so it renders empty.
        #expect(out == "")
    }

    @Test func formatResponseThemesMarksCurrent() {
        let response = ControlResponse(ok: true, result: ControlResult(theme: "Nord", themes: ["Dracula", "Nord"]))
        let out = SocketClient.formatResponse(response, json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines == ["  default ghostty", "  Dracula", "* Nord"])
    }

    @Test func formatResponseThemesMarksGhosttyDefaultWhenCurrent() {
        // nil current theme = ghostty's built-in is active, so the leading "default ghostty" row is marked.
        let response = ControlResponse(ok: true, result: ControlResult(theme: nil, themes: ["Dracula"]))
        let out = SocketClient.formatResponse(response, json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines == ["* default ghostty", "  Dracula"])
    }

    @Test func formatResponseThemeSetIsBareOk() {
        // theme.set returns only `theme` (no `themes` array), so it prints `ok` like other mutations.
        let response = ControlResponse(ok: true, result: ControlResult(theme: "Dracula"))
        #expect(SocketClient.formatResponse(response, json: false) == "ok")
    }

    @Test func formatResponseThemesMarksBothSyncedSides() {
        let response = ControlResponse(ok: true, result: ControlResult(
            theme: nil, themes: ["agterm", "Builtin Light", "Nord"], sync: true, light: "Builtin Light", dark: "agterm"))
        let out = SocketClient.formatResponse(response, json: false)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "syncing with macOS appearance — light: Builtin Light, dark: agterm")
        #expect(lines.contains("* agterm"))
        #expect(lines.contains("* Builtin Light"))
        #expect(lines.contains("  Nord"))
        #expect(lines.contains("  default ghostty"))
    }
}

private final class EventReadScript: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ControlRequest] = []
    private let run: UUID

    init(run: UUID) { self.run = run }

    func respond(_ request: ControlRequest) -> ControlResponse {
        lock.lock(); seen.append(request); let count = seen.count; lock.unlock()
        let next: UInt64 = count == 1 ? 7 : 8
        return ControlResponse(ok: true, result: ControlResult(events: ControlEventBatch(run: run, next: next, items: [])))
    }

    func requests() -> [ControlRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }
}

/// An in-process unix-socket server for the round-trip tests: binds a short temp path, accepts one
/// connection, reads the request line, records it, and writes back a canned `ControlResponse`.
private final class StubServer: @unchecked Sendable {
    let path: String
    private let canned: ControlResponse
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "stub.server")
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private(set) var received: ControlRequest?

    init(response: ControlResponse) {
        self.canned = response
        self.path = NSTemporaryDirectory() + "agterm-stub-\(UUID().uuidString.prefix(8)).sock"
    }

    func start() throws {
        let fd = systemSocket()
        guard fd >= 0 else { throw SocketClientError("stub socket() failed") }
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketClientError("stub bind failed: \(String(cString: strerror(errno)))")
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw SocketClientError("stub listen failed")
        }
        listenFD = fd
        queue.async { [self] in accept(fd); finished.signal() }
    }

    private func accept(_ fd: Int32) {
        let conn = systemAccept(fd)
        lock.lock(); let done = stopped; lock.unlock()
        // stop() woke this accept only to join it — don't serve a request on a stopping server.
        if done { if conn >= 0 { close(conn) }; return }
        guard conn >= 0 else { return }
        defer { close(conn) }

        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(conn, &byte, 1)
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        received = try? JSONDecoder().decode(ControlRequest.self, from: buffer)

        guard var data = try? JSONEncoder().encode(canned) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let written = write(conn, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func stop() {
        guard listenFD >= 0 else { unlink(path); return }
        lock.lock(); stopped = true; lock.unlock()
        wakeAccept(path)                        // unblock a pending accept() so the loop observes `stopped`
        _ = finished.wait(timeout: .now() + 2)  // join the accept loop before freeing the fd
        close(listenFD); listenFD = -1
        unlink(path)
    }
}

/// A server that accepts one connection and closes it immediately without reading the request — the
/// shape of the real server rejecting an oversized line. A client mid-write on that connection gets
/// EPIPE, which is the SIGPIPE hazard `SO_NOSIGPIPE` exists to defuse.
private final class HangUpStubServer: @unchecked Sendable {
    let path: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "hangup.stub.server")
    private let finished = DispatchSemaphore(value: 0)

    init() {
        self.path = NSTemporaryDirectory() + "agterm-hangup-\(UUID().uuidString.prefix(8)).sock"
    }

    func start() throws {
        let fd = systemSocket()
        guard fd >= 0 else { throw SocketClientError("stub socket() failed") }
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketClientError("stub bind failed: \(String(cString: strerror(errno)))")
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw SocketClientError("stub listen failed")
        }
        listenFD = fd
        queue.async { [self] in
            let conn = systemAccept(fd)
            if conn >= 0 { close(conn) }
            finished.signal()
        }
    }

    func stop() {
        guard listenFD >= 0 else { unlink(path); return }
        wakeAccept(path)                        // unblock a still-pending accept() so it can finish
        _ = finished.wait(timeout: .now() + 2)  // join the accept before freeing the fd
        close(listenFD); listenFD = -1
        unlink(path)
    }
}

/// Connect once to `path` and immediately close, to wake a stub server's blocked `accept()` so its
/// background loop can observe `stopped` and exit. Best-effort — a failed connect is ignored. Shared by
/// both stub servers so `stop()` can JOIN the accept loop before the listen fd is closed, which is what
/// keeps a lingering loop from serving the next server's client on a reused fd number.
private func wakeAccept(_ path: String) {
    let fd = systemSocket()
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { dst in
        dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
            pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
        }
    }
    _ = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            systemConnect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

/// A multi-connection unix-socket server: accepts connections in a loop until `stop()`, answering each
/// request via `responder`. Used to drive the `--block` flow, which makes several round trips (open,
/// then one connection per `session.overlay.result` poll).
private final class ScriptedStubServer: @unchecked Sendable {
    let path: String
    private let responder: @Sendable (ControlRequest) -> ControlResponse
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "scripted.stub.server")
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false

    init(responder: @escaping @Sendable (ControlRequest) -> ControlResponse) {
        self.responder = responder
        self.path = NSTemporaryDirectory() + "agterm-scripted-\(UUID().uuidString.prefix(8)).sock"
    }

    func start() throws {
        let fd = systemSocket()
        guard fd >= 0 else { throw SocketClientError("scripted socket() failed") }
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketClientError("scripted bind failed: \(String(cString: strerror(errno)))")
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw SocketClientError("scripted listen failed")
        }
        listenFD = fd
        queue.async { [self] in acceptLoop(fd); finished.signal() }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = systemAccept(fd)
            lock.lock(); let done = stopped; lock.unlock()
            // stop() flips `stopped` then self-connects to wake this accept; observing it here is what
            // lets the loop exit (and be joined) before the fd is closed, so it can never run accept on a
            // number the next server has reused.
            if done { if conn >= 0 { close(conn) }; return }
            if conn < 0 { return }
            handle(conn)
            close(conn)
        }
    }

    private func handle(_ conn: Int32) {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(conn, &byte, 1)
            if n <= 0 { return }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: buffer) else { return }
        guard var data = try? JSONEncoder().encode(responder(request)) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < data.count {
                let written = write(conn, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func stop() {
        guard listenFD >= 0 else { unlink(path); return }
        lock.lock(); stopped = true; lock.unlock()
        wakeAccept(path)                        // unblock a pending accept() so the loop observes `stopped`
        _ = finished.wait(timeout: .now() + 2)  // join the accept loop before freeing the fd
        close(listenFD); listenFD = -1
        unlink(path)
    }
}

private func systemSocket() -> Int32 {
    #if canImport(Darwin)
    return socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

private func systemAccept(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.accept(fd, nil, nil)
    #else
    return Glibc.accept(fd, nil, nil)
    #endif
}

private func systemConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, addr, len)
    #else
    return Glibc.connect(fd, addr, len)
    #endif
}

/// Scripts the `--block` round trips: `session.overlay.open` returns a fixed id; `session.overlay.result`
/// errors `stillRunning` for the first `stillRunningTimes` calls, then returns `finalResult`.
private final class OverlayResultScript: @unchecked Sendable {
    private let lock = NSLock()
    private var resultCalls = 0
    private let stillRunningTimes: Int
    private let finalResult: ControlResponse

    init(stillRunningTimes: Int, finalResult: ControlResponse) {
        self.stillRunningTimes = stillRunningTimes
        self.finalResult = finalResult
    }

    func respond(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionOverlayOpen:
            return ControlResponse(ok: true, result: ControlResult(id: "abc"))
        case .sessionOverlayResult:
            lock.lock(); resultCalls += 1; let n = resultCalls; lock.unlock()
            return n <= stillRunningTimes
                ? ControlResponse(ok: false, error: OverlayResultError.stillRunning)
                : finalResult
        default:
            return ControlResponse(ok: false, error: "unexpected cmd \(request.cmd)")
        }
    }
}
