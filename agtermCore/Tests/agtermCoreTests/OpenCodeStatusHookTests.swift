import Foundation
import Testing

/// Resolves a qualifying `node` for OpenCodeStatusHookTests. Kept outside the suite type so
/// `@Suite(.enabled(if:))` can reference it without a circular macro resolution on the suite itself.
private enum OpenCodeStatusHookSupport {
    /// First `node` on PATH that meets the module-syntax-detection floor (≥ 20.19 or ≥ 22.7), or nil.
    /// Suite-gated via `.enabled(if:)` so older/missing Node skips visibly rather than failing the
    /// import of the plugin's bare `.js` (no package.json above it).
    static var node: String? {
        guard let path = whichNode(), nodeVersionMeetsFloor(at: path) else { return nil }
        return path
    }

    private static func whichNode() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "node"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Module-syntax detection for unflagged `.js` ESM landed in Node 20.19 / 22.7; 21.x and older
    /// 20/22 lines fail the plugin import instead of skipping.
    private static func nodeVersionMeetsFloor(at path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        guard proc.terminationStatus == 0 else { return false }
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = trimmed.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        let (major, minor) = (parts[0], parts[1])
        if major > 22 { return true }
        if major == 22 { return minor >= 7 }
        if major == 20 { return minor >= 19 }
        return false
    }
}

// Exercises the OpenCode plugin shipped by the Help-menu installer: event-to-status mapping and wrapper
// spawning belong to the installed plugin, not to agterm's runtime status engine. Drives it through Node
// (the host OpenCode uses) with AGTERM_STATUS_WRAPPER recording argv; skipped when Node is absent.
@Suite(.enabled(if: OpenCodeStatusHookSupport.node != nil,
                "Node.js 22.7+ (or 20.19+ on the 20.x line) is required to exercise the OpenCode status plugin"))
struct OpenCodeStatusHookTests {
    private static var plugin: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status/opencode/agterm-status.js")
            .path
    }

    /// Run a node process; on non-zero exit, surface stderr so the failure names the cause.
    private func runNode(arguments: [String], environment: [String: String]) throws -> Int32 {
        let node = try #require(OpenCodeStatusHookSupport.node)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = arguments
        proc.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Issue.record(
                """
                node exited \(proc.terminationStatus)
                args: \(arguments)
                stderr:
                \(err)
                stdout:
                \(out)
                """
            )
        }
        return proc.terminationStatus
    }

    /// Run the plugin's `event` hook for each OpenCode bus payload; returns recorded wrapper argv lines.
    private func runEvents(_ events: [[String: Any]],
                           setStatusWrapper: Bool = true,
                           sessionID: String? = "sid") throws -> [String] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-opencode-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let statuses = dir.appendingPathComponent("statuses")
        let home = dir.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let recordScript = """
        #!/bin/bash
        printf '%s\\n' "$*" >> '\(statuses.path)'
        """

        let statusWrapper = dir.appendingPathComponent("status-wrapper")
        try recordScript.write(to: statusWrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusWrapper.path)

        if !setStatusWrapper {
            let defaultWrapperDir = home.appendingPathComponent(".config/agterm/agent-status", isDirectory: true)
            try fm.createDirectory(at: defaultWrapperDir, withIntermediateDirectories: true)
            let defaultWrapper = defaultWrapperDir.appendingPathComponent("agterm-agent-status.sh")
            try recordScript.write(to: defaultWrapper, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: defaultWrapper.path)
        }

        let eventsFile = dir.appendingPathComponent("events.json")
        try String(data: JSONSerialization.data(withJSONObject: events), encoding: .utf8)!
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        // Harness stays out of Resources (would ship to users). The harness is .mjs; Node loads the
        // plugin's .js as ESM via dynamic import / module-syntax detection — no --experimental-* flag.
        let harness = dir.appendingPathComponent("harness.mjs")
        try """
        import { readFileSync } from "node:fs";
        import { pathToFileURL } from "node:url";
        const { AgtermStatusPlugin } = await import(pathToFileURL(process.env.AGTERM_OPENCODE_PLUGIN).href);
        const events = JSON.parse(readFileSync(process.env.AGTERM_OPENCODE_EVENTS, "utf8"));
        const hooks = await AgtermStatusPlugin();
        if (typeof hooks.event !== "function") process.exit(0);
        for (const event of events) {
          await hooks.event({ event });
        }
        """.write(to: harness, atomically: true, encoding: .utf8)

        var environment: [String: String] = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "AGTERM_OPENCODE_PLUGIN": Self.plugin,
            "AGTERM_OPENCODE_EVENTS": eventsFile.path,
        ]
        if let sessionID {
            environment["AGTERM_SESSION_ID"] = sessionID
        }
        if setStatusWrapper {
            environment["AGTERM_STATUS_WRAPPER"] = statusWrapper.path
        }
        #expect(try runNode(arguments: [harness.path], environment: environment) == 0)

        return ((try? String(contentsOf: statuses, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func event(_ type: String, properties: [String: Any] = [:]) -> [String: Any] {
        ["type": type, "properties": properties]
    }

    private func status(_ kind: String, sessionID: String = "ses_root") -> [String: Any] {
        event("session.status", properties: ["sessionID": sessionID, "status": ["type": kind]])
    }

    @Test func pluginExportsOnlyPluginFunctions() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-opencode-exports-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // .mjs harness — avoid node -e (needs --input-type=module) and the removed
        // --experimental-default-type=module flag.
        let harness = dir.appendingPathComponent("exports.mjs")
        try """
        import { pathToFileURL } from "node:url";
        const mod = await import(pathToFileURL(process.env.AGTERM_OPENCODE_PLUGIN).href);
        const keys = Object.keys(mod);
        if (keys.length !== 1 || keys[0] !== "AgtermStatusPlugin") process.exit(2);
        if (typeof mod.AgtermStatusPlugin !== "function") process.exit(3);
        for (const [name, value] of Object.entries(mod)) {
          if (typeof value !== "function") process.exit(4);
        }
        """.write(to: harness, atomically: true, encoding: .utf8)
        #expect(try runNode(
            arguments: [harness.path],
            environment: [
                "PATH": "/usr/bin:/bin",
                "AGTERM_OPENCODE_PLUGIN": Self.plugin,
            ]
        ) == 0)
    }

    @Test func lifecycleEventsDriveOnlyTheGenericStatusWrapper() throws {
        let calls = try runEvents([
            status("busy"),
            status("retry"),
            status("idle"),
            event("permission.asked"),
            event("question.asked"),
            event("permission.replied"),
            event("question.replied"),
            event("question.rejected"),
        ])
        #expect(calls == [
            "active --blink",
            "active --blink",
            "completed --auto-reset",
            "blocked",
            "blocked",
            "active --blink",
            "active --blink",
            "active --blink",
        ])
    }

    @Test func sessionErrorStaysBlockedThroughFollowingIdle() throws {
        // SessionProcessor.halt publishes session.error then status(idle) on the next line; without an
        // errored latch the serial queue would overwrite blocked with completed --auto-reset.
        let calls = try runEvents([
            status("busy"),
            event("session.error", properties: [
                "sessionID": "ses_root",
                "error": ["name": "ProviderError"],
            ]),
            status("idle"),
        ])
        #expect(calls == ["active --blink", "blocked"])
    }

    @Test func abortErrorDoesNotLatchBlocked() throws {
        // Esc → halt(AbortError) → MessageAbortedError + idle. Must end on completed --auto-reset
        // (self-clears on visit), not stuck blocked ahead of clearedByKeystroke.
        let calls = try runEvents([
            status("busy"),
            event("session.error", properties: [
                "sessionID": "ses_root",
                "error": ["name": "MessageAbortedError"],
            ]),
            status("idle"),
        ])
        #expect(calls == ["active --blink", "completed --auto-reset"])
    }

    @Test func contextOverflowFollowedByBusyDoesNotPaintBlocked() throws {
        // Auto-compaction publishes ContextOverflowError and then resumes the loop, so the next event
        // is busy — the overflow was a hiccup, not a failed turn, and must not flash blocked.
        let calls = try runEvents([
            status("busy"),
            event("session.error", properties: [
                "sessionID": "ses_root",
                "error": ["name": "ContextOverflowError"],
            ]),
            status("busy"),
            status("idle"),
        ])
        #expect(calls == ["active --blink", "active --blink", "completed --auto-reset"])
    }

    @Test func contextOverflowFollowedByIdleReportsBlocked() throws {
        // With compaction disabled (or once it gives up) halt publishes the same error and then idle:
        // the turn really ended in failure, so this must land on blocked rather than completed.
        let calls = try runEvents([
            status("busy"),
            event("session.error", properties: [
                "sessionID": "ses_root",
                "error": ["name": "ContextOverflowError"],
            ]),
            status("idle"),
        ])
        #expect(calls == ["active --blink", "blocked"])
    }

    @Test func idleWithoutPrecedingBusyIsIgnored() throws {
        let calls = try runEvents([
            status("idle"),
            status("idle", sessionID: "ses_never_busy"),
        ])
        #expect(calls.isEmpty)
    }

    @Test func subagentIdleDoesNotCompleteWhileParentIsActive() throws {
        // Task tool creates a child session with its own busy/idle while the parent stays busy. The
        // permission between the two idles is the oracle: a gate that completed on the child's idle
        // would place completed BEFORE blocked instead of after it.
        let calls = try runEvents([
            status("busy", sessionID: "ses_parent"),
            status("busy", sessionID: "ses_child"),
            status("idle", sessionID: "ses_child"),
            event("permission.asked", properties: ["sessionID": "ses_parent"]),
            status("idle", sessionID: "ses_parent"),
        ])
        #expect(calls == [
            "active --blink",
            "active --blink",
            "blocked",
            "completed --auto-reset",
        ])
    }

    @Test func interleavedTopLevelSessionsCompleteOnlyWhenAllIdle() throws {
        let calls = try runEvents([
            status("busy", sessionID: "ses_a"),
            status("busy", sessionID: "ses_b"),
            status("idle", sessionID: "ses_a"),
            status("busy", sessionID: "ses_a"),
            status("idle", sessionID: "ses_b"),
            status("idle", sessionID: "ses_a"),
        ])
        #expect(calls == [
            "active --blink",
            "active --blink",
            "active --blink",
            "completed --auto-reset",
        ])
    }

    @Test func siblingIdleDoesNotCompleteOverAnotherSessionsError() throws {
        // halt() publishes session.error then that session's own idle while a sibling still runs: the
        // latch must outlive the swallowed idle, or the sibling's idle paints completed over blocked.
        let calls = try runEvents([
            status("busy", sessionID: "ses_a"),
            status("busy", sessionID: "ses_b"),
            event("session.error", properties: [
                "sessionID": "ses_a",
                "error": ["name": "ProviderAuthError"],
            ]),
            status("idle", sessionID: "ses_a"),
            status("idle", sessionID: "ses_b"),
        ])
        #expect(calls == ["active --blink", "active --blink", "blocked"])
    }

    @Test func turnAfterAnErrorCompletesNormally() throws {
        // The set-wide latch must not leak into the next turn.
        let calls = try runEvents([
            status("busy"),
            event("session.error", properties: [
                "sessionID": "ses_root",
                "error": ["name": "ProviderAuthError"],
            ]),
            status("idle"),
            status("busy"),
            status("idle"),
        ])
        #expect(calls == [
            "active --blink",
            "blocked",
            "active --blink",
            "completed --auto-reset",
        ])
    }

    @Test func ignoresDeprecatedSessionIdleAndNonStatusNoise() throws {
        let calls = try runEvents([
            event("session.idle", properties: ["sessionID": "s1"]),
            event("tool.execute.before"),
            event("tool.execute.after"),
            event("session.compacted"),
            event("chat.message"),
            event("session.created", properties: ["info": ["id": "child", "parentID": "root"]]),
        ])
        #expect(calls.isEmpty)
    }

    @Test func pluginIsSilentNoOpOutsideAgterm() throws {
        let calls = try runEvents(
            [status("busy")],
            sessionID: nil
        )
        #expect(calls.isEmpty)
    }

    @Test func defaultWrapperPathIsUsedWhenStatusWrapperUnset() throws {
        let calls = try runEvents(
            [event("permission.asked")],
            setStatusWrapper: false
        )
        #expect(calls == ["blocked"])
    }

    @Test func reportsRunStrictlyInOrder() throws {
        // Gate protocol: blocked holds until `release` exists; the next report must not start until then.
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-opencode-order-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let statuses = dir.appendingPathComponent("statuses")
        let started = dir.appendingPathComponent("started")
        let release = dir.appendingPathComponent("release")
        let wrapper = dir.appendingPathComponent("status-wrapper")
        try """
        #!/bin/bash
        printf '%s\\n' "start $*" >> '\(started.path)'
        if [ "$1" = "blocked" ]; then
          while [ ! -f '\(release.path)' ]; do sleep 0.01; done
        fi
        printf '%s\\n' "$*" >> '\(statuses.path)'
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        // permission.asked / replied always report (no active-set gate), so the queue order is isolated.
        let events: [[String: Any]] = [
            event("permission.asked"),
            event("permission.replied"),
        ]
        let eventsFile = dir.appendingPathComponent("events.json")
        try String(data: JSONSerialization.data(withJSONObject: events), encoding: .utf8)!
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let harness = dir.appendingPathComponent("harness.mjs")
        try """
        import { readFileSync, writeFileSync, existsSync } from "node:fs";
        import { pathToFileURL } from "node:url";
        import { setTimeout as sleep } from "node:timers/promises";
        const { AgtermStatusPlugin } = await import(pathToFileURL(process.env.AGTERM_OPENCODE_PLUGIN).href);
        const events = JSON.parse(readFileSync(process.env.AGTERM_OPENCODE_EVENTS, "utf8"));
        const hooks = await AgtermStatusPlugin();
        const pending = Promise.all(events.map((event) => hooks.event({ event })));
        const startedPath = process.env.AGTERM_OPENCODE_STARTED;
        const releasePath = process.env.AGTERM_OPENCODE_RELEASE;
        const statusesPath = process.env.AGTERM_OPENCODE_STATUSES;
        for (let i = 0; i < 500 && !existsSync(startedPath); i++) await sleep(10);
        // While blocked is held, the follow-up active report must not have started (queue serializes).
        const started = existsSync(startedPath) ? readFileSync(startedPath, "utf8") : "";
        if (started.includes("active")) {
          writeFileSync(releasePath, "1");
          await pending;
          process.exit(2);
        }
        if (existsSync(statusesPath) && readFileSync(statusesPath, "utf8").trim()) {
          writeFileSync(releasePath, "1");
          await pending;
          process.exit(3);
        }
        writeFileSync(releasePath, "1");
        await pending;
        """.write(to: harness, atomically: true, encoding: .utf8)

        #expect(try runNode(
            arguments: [harness.path],
            environment: [
                "HOME": dir.path,
                "PATH": "/usr/bin:/bin",
                "AGTERM_SESSION_ID": "sid",
                "AGTERM_STATUS_WRAPPER": wrapper.path,
                "AGTERM_OPENCODE_PLUGIN": Self.plugin,
                "AGTERM_OPENCODE_EVENTS": eventsFile.path,
                "AGTERM_OPENCODE_STARTED": started.path,
                "AGTERM_OPENCODE_RELEASE": release.path,
                "AGTERM_OPENCODE_STATUSES": statuses.path,
            ]
        ) == 0)

        let calls = ((try? String(contentsOf: statuses, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        #expect(calls == ["blocked", "active --blink"])
    }
}
