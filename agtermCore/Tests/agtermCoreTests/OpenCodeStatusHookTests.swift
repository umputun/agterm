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

// Exercises the OpenCode plugin shipped by the Help-menu installer: event-to-status mapping and
// wrapper spawning belong to the installed plugin, not to agterm's runtime status engine. Drives it
// through Node (the host OpenCode uses) with AGTERM_STATUS_WRAPPER recording argv; skipped when Node
// is absent.
//
// The plugin is dual-entrypoint: default.setup(ctx) serves OpenCode v2 (ctx.event.subscribe() with
// payloads under `data`; the public v2 stream carries the turn lifecycle as session.execution.
// started/succeeded/failed/interrupted and questions as form.*), and default.server() serves v1
// >= 1.18.29 (legacy bus payloads under `properties` with session.status/question.*/session.error).
// v2 scripts may interleave {"__delayMs": n} steps so the failure debounce lands deterministically.
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

    /// Shared scaffolding: scratch HOME, a recording wrapper (or one at the default wrapper path),
    /// the events/script JSON, and the recorded status lines.
    private func makeScratch(script: [[String: Any]], setStatusWrapper: Bool) throws -> (
        dir: URL, statuses: URL, eventsFile: URL, wrapper: URL
    ) {
        let fm = FileManager()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-opencode-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let home = dir.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let statuses = dir.appendingPathComponent("statuses")
        let recordScript = """
        #!/bin/bash
        printf '%s\\n' "$*" >> '\(statuses.path)'
        """
        let wrapper = dir.appendingPathComponent("status-wrapper")
        try recordScript.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        if !setStatusWrapper {
            let defaultWrapperDir = home.appendingPathComponent(".config/agterm/agent-status", isDirectory: true)
            try fm.createDirectory(at: defaultWrapperDir, withIntermediateDirectories: true)
            let defaultWrapper = defaultWrapperDir.appendingPathComponent("agterm-agent-status.sh")
            try recordScript.write(to: defaultWrapper, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: defaultWrapper.path)
        }

        let eventsFile = dir.appendingPathComponent("events.json")
        try String(data: JSONSerialization.data(withJSONObject: script), encoding: .utf8)!
            .write(to: eventsFile, atomically: true, encoding: .utf8)
        return (dir, statuses, eventsFile, wrapper)
    }

    /// Drive the v2 entrypoint: default.setup(ctx) with a signal-aware in-memory event bus that
    /// yields the script, honoring {"__delayMs": n} steps. Cleanup drains the pump and any armed
    /// failure debounces, so the recorded statuses are complete when this returns.
    private func runV2(_ script: [[String: Any]],
                       sessionID: String? = "sid",
                       setStatusWrapper: Bool = true,
                       extraFile: String? = nil) throws -> [String] {
        let scratch = try makeScratch(script: script, setStatusWrapper: setStatusWrapper)
        defer { try? FileManager.default.removeItem(at: scratch.dir) }

        // Harness stays out of Resources (would ship to users). The harness is .mjs; Node loads the
        // plugin's .js as ESM via dynamic import / module-syntax detection — no --experimental-* flag.
        let harness = scratch.dir.appendingPathComponent("harness.mjs")
        try """
        import { readFileSync } from "node:fs";
        import { setTimeout as sleep } from "node:timers/promises";
        import { pathToFileURL } from "node:url";
        const mod = await import(pathToFileURL(process.env.AGTERM_OPENCODE_PLUGIN).href);
        const script = JSON.parse(readFileSync(process.env.AGTERM_OPENCODE_EVENTS, "utf8"));
        const bus = {
          pending: [], wake: null, delivered: 0,
          push(event) { this.pending.push(event); this.wake?.(); },
          async *subscribe({ signal }) {
            const onAbort = () => { this.wake?.(); };
            signal.addEventListener("abort", onAbort);
            try {
              while (!signal.aborted) {
                while (this.pending.length && !signal.aborted) { this.delivered++; yield this.pending.shift(); }
                if (signal.aborted) break;
                await new Promise((resolve) => { this.wake = resolve; });
                this.wake = null;
              }
            } finally {
              signal.removeEventListener("abort", onAbort);
            }
          },
        };
        const cleanup = await mod.default.setup({ event: bus });
        // Outside agterm setup legitimately returns undefined (silent no-op).
        if (cleanup !== undefined && typeof cleanup !== "function") { console.error("setup returned no cleanup"); process.exit(2); }
        let pushed = 0;
        for (const step of script) {
          if (step.__delayMs === undefined) { bus.push(step); pushed++; continue; }
          // A delay step first waits until the pump CONSUMED everything pushed so far — the
          // debounced report's timer only starts when its event is processed — then sleeps, so
          // the debounce reliably lands before the next event is pushed.
          for (let i = 0; i < 2000 && bus.delivered < pushed; i++) await sleep(5);
          await sleep(step.__delayMs);
        }
        // Wait until the pump has taken every event, not a fixed sleep: a cold wrapper spawn can
        // outrun the script, and cleanup's abort would then drop still-queued events.
        const total = script.filter((s) => s.__delayMs === undefined).length;
        for (let i = 0; i < 600 && bus.delivered < total; i++) await sleep(5);
        await sleep(70); // let the failure debounce fire before cleanup
        await cleanup?.();
        """.write(to: harness, atomically: true, encoding: .utf8)

        var environment: [String: String] = [
            "HOME": scratch.dir.appendingPathComponent("home").path,
            "PATH": "/usr/bin:/bin",
            "AGTERM_OPENCODE_PLUGIN": Self.plugin,
            "AGTERM_OPENCODE_EVENTS": scratch.eventsFile.path,
            "AGTERM_STATUS_FAILURE_DEBOUNCE_MS": "30",
        ]
        if let sessionID {
            environment["AGTERM_SESSION_ID"] = sessionID
        }
        if setStatusWrapper {
            environment["AGTERM_STATUS_WRAPPER"] = scratch.wrapper.path
        }
        if let extraFile {
            environment["AGTERM_OPENCODE_EXTRA"] = extraFile
        }
        #expect(try runNode(arguments: [harness.path], environment: environment) == 0)

        return ((try? String(contentsOf: scratch.statuses, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Drive the v1 entrypoint: default.server() hooks fed legacy bus payloads ({type, properties}).
    private func runV1(_ events: [[String: Any]],
                       sessionID: String? = "sid",
                       setStatusWrapper: Bool = true) throws -> [String] {
        let scratch = try makeScratch(script: events, setStatusWrapper: setStatusWrapper)
        defer { try? FileManager.default.removeItem(at: scratch.dir) }

        let harness = scratch.dir.appendingPathComponent("harness.mjs")
        try """
        import { readFileSync } from "node:fs";
        import { pathToFileURL } from "node:url";
        const mod = await import(pathToFileURL(process.env.AGTERM_OPENCODE_PLUGIN).href);
        const events = JSON.parse(readFileSync(process.env.AGTERM_OPENCODE_EVENTS, "utf8"));
        const hooks = await mod.default.server();
        // Outside agterm server() legitimately returns an empty hooks object (silent no-op).
        if (hooks.event === undefined) process.exit(0);
        if (typeof hooks.event !== "function") { console.error("server() returned no event hook"); process.exit(2); }
        for (const event of events) {
          await hooks.event({ event });
        }
        """.write(to: harness, atomically: true, encoding: .utf8)

        var environment: [String: String] = [
            "HOME": scratch.dir.appendingPathComponent("home").path,
            "PATH": "/usr/bin:/bin",
            "AGTERM_OPENCODE_PLUGIN": Self.plugin,
            "AGTERM_OPENCODE_EVENTS": scratch.eventsFile.path,
        ]
        if let sessionID {
            environment["AGTERM_SESSION_ID"] = sessionID
        }
        if setStatusWrapper {
            environment["AGTERM_STATUS_WRAPPER"] = scratch.wrapper.path
        }
        #expect(try runNode(arguments: [harness.path], environment: environment) == 0)

        return ((try? String(contentsOf: scratch.statuses, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    // MARK: entrypoint shape

    @Test func defaultExportCarriesDualEntrypoints() throws {
        let fm = FileManager()
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
        const plugin = mod.default;
        if (plugin === undefined || typeof plugin !== "object") process.exit(2);
        if (plugin.id !== "agterm-status") process.exit(3);
        if (typeof plugin.setup !== "function") process.exit(4);
        if (typeof plugin.server !== "function") process.exit(5);
        """.write(to: harness, atomically: true, encoding: .utf8)
        #expect(try runNode(
            arguments: [harness.path],
            environment: [
                "PATH": "/usr/bin:/bin",
                "AGTERM_OPENCODE_PLUGIN": Self.plugin,
            ]
        ) == 0)
    }

    // MARK: v2 event vocabulary (public stream: execution lifecycle + forms)

    private func v2Event(_ type: String, _ data: [String: Any] = [:]) -> [String: Any] {
        ["type": type, "data": data]
    }

    private func started(_ sessionID: String = "ses_root") -> [String: Any] {
        v2Event("session.execution.started", ["sessionID": sessionID])
    }

    private func step(_ sessionID: String = "ses_root") -> [String: Any] {
        v2Event("session.step.started", ["sessionID": sessionID])
    }

    private func succeeded(_ sessionID: String = "ses_root") -> [String: Any] {
        v2Event("session.execution.succeeded", ["sessionID": sessionID])
    }

    private func failed(_ sessionID: String = "ses_root", errorType: String = "provider.auth") -> [String: Any] {
        v2Event("session.execution.failed", ["sessionID": sessionID, "error": ["type": errorType, "message": "boom"]])
    }

    private func interrupted(_ sessionID: String = "ses_root", reason: String = "user") -> [String: Any] {
        v2Event("session.execution.interrupted", ["sessionID": sessionID, "reason": reason])
    }

    @Test func v2HappyTurnReportsActiveThenCompleted() throws {
        let calls = try runV2([started(), step(), step(), succeeded()])
        #expect(calls == ["active --blink", "completed --auto-reset"])
    }

    @Test func v2FailedTurnLandsBlocked() throws {
        let calls = try runV2([started(), failed()])
        #expect(calls == ["active --blink", "blocked"])
    }

    @Test func v2ResumeWithinDebounceDoesNotFlashBlocked() throws {
        // session.retry.scheduled or the resumed step arrives before the failure debounce fires:
        // the turn continued (retry / auto-compaction), so blocked must never appear.
        let calls = try runV2([
            started(),
            failed(),
            v2Event("session.retry.scheduled", ["sessionID": "ses_root"]),
            step(),
            succeeded(),
        ])
        #expect(calls == ["active --blink", "completed --auto-reset"])
    }

    @Test func v2OverflowFailureResumesWithoutBlocked() throws {
        // Same debounce absorbs the context-overflow ambiguity v1 solved with its overflow latch.
        let calls = try runV2([
            started(),
            failed(errorType: "context-overflow"),
            step(),
            succeeded(),
        ])
        #expect(calls == ["active --blink", "completed --auto-reset"])
    }

    @Test func v2InterruptEndsOnCompletedNotBlocked() throws {
        // Esc routes through session.execution.interrupted(reason=user): an interrupt is never a
        // failed turn, so the pane lands on completed --auto-reset (self-clears on visit).
        let calls = try runV2([started(), interrupted()])
        #expect(calls == ["active --blink", "completed --auto-reset"])
    }

    @Test func v2PermissionAndFormEventsDriveBlockedAndActive() throws {
        let calls = try runV2([
            started(),
            v2Event("permission.asked", ["sessionID": "ses_root", "id": "prm_1", "action": "edit", "resources": []]),
            v2Event("permission.replied", ["sessionID": "ses_root", "requestID": "prm_1", "reply": "once"]),
            v2Event("form.created", ["form": ["id": "frm_1", "sessionID": "ses_root", "title": "Pick one"]]),
            v2Event("form.replied", ["id": "frm_1", "sessionID": "ses_root"]),
            v2Event("form.cancelled", ["id": "frm_2", "sessionID": "ses_root"]),
            succeeded(),
        ])
        #expect(calls == [
            "active --blink",
            "blocked",
            "active --blink",
            "blocked",
            "active --blink",
            "active --blink",
            "completed --auto-reset",
        ])
    }

    @Test func v2SubagentIdleDoesNotCompleteWhileParentIsActive() throws {
        // A task subagent's turn ends while the parent stays busy. The permission between the two
        // succeeded events is the oracle: a gate that completed on the child would place completed
        // BEFORE blocked instead of after it.
        let calls = try runV2([
            started("ses_parent"),
            started("ses_child"),
            succeeded("ses_child"),
            v2Event("permission.asked", ["sessionID": "ses_parent"]),
            succeeded("ses_parent"),
        ])
        #expect(calls == ["active --blink", "active --blink", "blocked", "completed --auto-reset"])
    }

    @Test func v2SiblingSucceededDoesNotCompleteOverAnotherSessionsError() throws {
        // ses_a's turn failed (errored latch) while ses_b still runs: ses_b's success must not
        // paint completed over the blocked. The latch clears set-wide once everything idles.
        let calls = try runV2([
            started("ses_a"),
            started("ses_b"),
            failed("ses_a"),
            succeeded("ses_b"),
        ])
        #expect(calls == ["active --blink", "active --blink", "blocked"])
    }

    @Test func v2TurnAfterAnErrorCompletesNormally() throws {
        // The set-wide latch must not leak into the next turn; the delay lets the debounce land
        // the blocked before the next turn starts.
        let calls = try runV2([
            started(),
            failed(),
            ["__delayMs": 80],
            started(),
            succeeded(),
        ])
        #expect(calls == ["active --blink", "blocked", "active --blink", "completed --auto-reset"])
    }

    @Test func v2MidTurnAttachStillPaintsActive() throws {
        // A plugin reload between execution.started and the turn's end misses the started event;
        // step.started must still paint active so the pane is not idle-stale for a whole turn.
        let calls = try runV2([step(), step(), succeeded()])
        #expect(calls == ["active --blink", "completed --auto-reset"])
    }

    @Test func v2IgnoresDeprecatedAndPerStepNoise() throws {
        let calls = try runV2([
            v2Event("session.idle", ["sessionID": "s1"]),
            // Not on the public v2 stream; if one ever leaks through, only session.status(busy)
            // semantics would be safe — assert the mapped vocabulary is ignored wholesale.
            ["type": "session.status", "data": ["sessionID": "s1", "status": ["type": "busy"]]],
            v2Event("session.text.delta", ["sessionID": "s1"]),
            v2Event("session.reasoning.delta", ["sessionID": "s1"]),
            v2Event("session.tool.called", ["sessionID": "s1"]),
            v2Event("session.compacted", ["sessionID": "s1"]),
            v2Event("session.created", ["info": ["id": "child", "parentID": "root"]]),
            v2Event("session.inbox.enqueued", ["sessionID": "s1"]),
        ])
        #expect(calls.isEmpty)
    }

    // MARK: v1 event vocabulary (legacy bus via server())

    private func v1Event(_ type: String, properties: [String: Any] = [:]) -> [String: Any] {
        ["type": type, "properties": properties]
    }

    private func v1Status(_ kind: String, sessionID: String = "ses_root") -> [String: Any] {
        v1Event("session.status", properties: ["sessionID": sessionID, "status": ["type": kind]])
    }

    @Test func v1LifecycleEventsDriveOnlyTheGenericStatusWrapper() throws {
        let calls = try runV1([
            v1Status("busy"),
            v1Status("retry"),
            v1Status("idle"),
            v1Event("permission.asked"),
            v1Event("question.asked"),
            v1Event("permission.replied"),
            v1Event("question.replied"),
            v1Event("question.rejected"),
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

    @Test func v1SessionErrorStaysBlockedThroughFollowingIdle() throws {
        // halt publishes session.error then status(idle) on the next line; without an errored
        // latch the serial queue would overwrite blocked with completed --auto-reset.
        let calls = try runV1([
            v1Status("busy"),
            v1Event("session.error", properties: [
                "sessionID": "ses_root",
                "error": ["name": "ProviderError"],
            ]),
            v1Status("idle"),
        ])
        #expect(calls == ["active --blink", "blocked"])
    }

    @Test func v1AbortErrorDoesNotLatchBlocked() throws {
        // Esc → halt(AbortError) → MessageAbortedError + idle. Must end on completed --auto-reset
        // (self-clears on visit), not stuck blocked ahead of clearedByKeystroke.
        let calls = try runV1([
            v1Status("busy"),
            v1Event("session.error", properties: [
                "sessionID": "ses_root",
                "error": ["name": "MessageAbortedError"],
            ]),
            v1Status("idle"),
        ])
        #expect(calls == ["active --blink", "completed --auto-reset"])
    }

    @Test func v1ContextOverflowFollowedByBusyDoesNotPaintBlocked() throws {
        // Auto-compaction publishes ContextOverflowError and then resumes the loop, so the next
        // event is busy — the overflow was a hiccup, not a failed turn, and must not flash blocked.
        let calls = try runV1([
            v1Status("busy"),
            v1Event("session.error", properties: [
                "sessionID": "ses_root",
                "error": ["name": "ContextOverflowError"],
            ]),
            v1Status("busy"),
            v1Status("idle"),
        ])
        #expect(calls == ["active --blink", "active --blink", "completed --auto-reset"])
    }

    @Test func v1ContextOverflowFollowedByIdleReportsBlocked() throws {
        // With compaction disabled (or once it gives up) halt publishes the same error and then
        // idle: the turn really ended in failure, so this must land on blocked rather than completed.
        let calls = try runV1([
            v1Status("busy"),
            v1Event("session.error", properties: [
                "sessionID": "ses_root",
                "error": ["name": "ContextOverflowError"],
            ]),
            v1Status("idle"),
        ])
        #expect(calls == ["active --blink", "blocked"])
    }

    @Test func v1IdleWithoutPrecedingBusyIsIgnored() throws {
        let calls = try runV1([
            v1Status("idle"),
            v1Status("idle", sessionID: "ses_never_busy"),
        ])
        #expect(calls.isEmpty)
    }

    @Test func v1InterleavedTopLevelSessionsCompleteOnlyWhenAllIdle() throws {
        let calls = try runV1([
            v1Status("busy", sessionID: "ses_a"),
            v1Status("busy", sessionID: "ses_b"),
            v1Status("idle", sessionID: "ses_a"),
            v1Status("busy", sessionID: "ses_a"),
            v1Status("idle", sessionID: "ses_b"),
            v1Status("idle", sessionID: "ses_a"),
        ])
        #expect(calls == [
            "active --blink",
            "active --blink",
            "active --blink",
            "completed --auto-reset",
        ])
    }

    // MARK: environment behavior

    @Test func pluginIsSilentNoOpOutsideAgterm() throws {
        let v2 = try runV2([started(), succeeded()], sessionID: nil)
        let v1 = try runV1([v1Status("busy")], sessionID: nil)
        #expect(v2.isEmpty)
        #expect(v1.isEmpty)
    }

    @Test func defaultWrapperPathIsUsedWhenStatusWrapperUnset() throws {
        let calls = try runV2(
            [v2Event("permission.asked", ["sessionID": "ses_root", "id": "prm", "action": "edit", "resources": []])],
            setStatusWrapper: false
        )
        #expect(calls == ["blocked"])
    }

    @Test func reportsRunStrictlyInOrder() throws {
        // Gate protocol: blocked holds until `release` exists; the next report must not start until
        // then. permission.asked / replied always report (no active-set gate), so the queue order is
        // isolated from the failure debounce.
        let fm = FileManager()
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

        let events: [[String: Any]] = [
            v2Event("permission.asked", ["sessionID": "ses_root", "id": "prm", "action": "edit", "resources": []]),
            v2Event("permission.replied", ["sessionID": "ses_root", "requestID": "prm", "reply": "once"]),
        ]
        let eventsFile = dir.appendingPathComponent("events.json")
        try String(data: JSONSerialization.data(withJSONObject: events), encoding: .utf8)!
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let harness = dir.appendingPathComponent("harness.mjs")
        try """
        import { readFileSync, writeFileSync, existsSync } from "node:fs";
        import { setTimeout as sleep } from "node:timers/promises";
        import { pathToFileURL } from "node:url";
        const mod = await import(pathToFileURL(process.env.AGTERM_OPENCODE_PLUGIN).href);
        const script = JSON.parse(readFileSync(process.env.AGTERM_OPENCODE_EVENTS, "utf8"));
        const bus = {
          pending: [], wake: null, delivered: 0,
          push(event) { this.pending.push(event); this.wake?.(); },
          async *subscribe({ signal }) {
            const onAbort = () => { this.wake?.(); };
            signal.addEventListener("abort", onAbort);
            try {
              while (!signal.aborted) {
                while (this.pending.length && !signal.aborted) { this.delivered++; yield this.pending.shift(); }
                if (signal.aborted) break;
                await new Promise((resolve) => { this.wake = resolve; });
                this.wake = null;
              }
            } finally { signal.removeEventListener("abort", onAbort); }
          },
        };
        const cleanup = await mod.default.setup({ event: bus });
        if (cleanup !== undefined && typeof cleanup !== "function") { console.error("setup returned no cleanup"); process.exit(2); }
        for (const event of script) bus.push(event);
        const total = script.length;
        // Wait for the FIRST report to start (its wrapper holds blocked on the release gate);
        // waiting for full delivery here would deadlock against that gate.
        for (let i = 0; i < 600 && bus.delivered < 1; i++) await sleep(5);
        const startedPath = process.env.AGTERM_OPENCODE_STARTED;
        const releasePath = process.env.AGTERM_OPENCODE_RELEASE;
        const statusesPath = process.env.AGTERM_OPENCODE_STATUSES;
        for (let i = 0; i < 500 && !existsSync(startedPath); i++) await sleep(10);
        // While blocked is held, the follow-up active report must not have started (queue serializes).
        const startedOut = existsSync(startedPath) ? readFileSync(startedPath, "utf8") : "";
        if (startedOut.includes("active")) {
          writeFileSync(releasePath, "1");
          await cleanup();
          process.exit(2);
        }
        if (existsSync(statusesPath) && readFileSync(statusesPath, "utf8").trim()) {
          writeFileSync(releasePath, "1");
          await cleanup();
          process.exit(3);
        }
        writeFileSync(releasePath, "1");
        // The gate is open: let the pump take the second event before cleanup so its report is
        // not dropped by the abort.
        for (let i = 0; i < 600 && bus.delivered < total; i++) await sleep(5);
        await cleanup();
        """.write(to: harness, atomically: true, encoding: .utf8)

        #expect(try runNode(
            arguments: [harness.path],
            environment: [
                "HOME": dir.path,
                "PATH": "/usr/bin:/bin",
                "AGTERM_SESSION_ID": "sid",
                "AGTERM_STATUS_WRAPPER": wrapper.path,
                "AGTERM_STATUS_FAILURE_DEBOUNCE_MS": "30",
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
