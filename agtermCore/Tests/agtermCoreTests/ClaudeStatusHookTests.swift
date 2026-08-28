import Foundation
import Testing

// Exercises only the Claude adapter shipped by the Help-menu installer. Its guard is a claim about process
// TOPOLOGY, so each case builds a real chain of processes above the script rather than stubbing one out.
struct ClaudeStatusHookTests {
    private static var hook: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status/agterm-claude-status.sh")
            .path
    }

    // spawns `chain` as nested processes — outermost first, one process per entry, each carrying that entry
    // as its argv[0] — and runs the adapter under the innermost one with `args`. `host:agent` builds a
    // runtime-hosted process instead: argv[0] is the host, argv[1] a script named after the agent.
    //
    // Every chain names its own boundary, because the adapter stops walking at `login`. Without one the test
    // would inherit whatever ancestry the runner happens to have, and `swift test` run from inside a Claude
    // session — the very thing this adapter exists for — would put a real `claude` above the fixture and turn
    // the owner cases silent. The boundary makes each case depend only on the processes it builds.
    private func run(chain: [String], args: [String], sessionID: String? = "sid",
                     extraEnv: [String: String] = [:]) throws -> (calls: [String], exit: Int32) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-claude-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let calls = dir.appendingPathComponent("calls")
        let wrapper = dir.appendingPathComponent("status-wrapper")
        let spawner = dir.appendingPathComponent("spawn-chain.sh")
        try "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(calls.path)'\n".write(to: wrapper, atomically: true, encoding: .utf8)
        // each level re-enters this script with one fewer name. The subshell is what makes the level a
        // separate process: `exec -a` replaces its own process, so without the fork the whole chain would
        // collapse onto one pid, and the trailing `exit` keeps bash from optimizing that fork away.
        try """
        #!/bin/bash
        set -u
        dir=$(cd "$(dirname "$0")" && pwd)
        levels=()
        while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do levels+=("$1"); shift; done
        shift
        if [ "${#levels[@]}" -eq 0 ]; then
          "$@"
          exit $?
        fi
        first=${levels[0]}
        rest=("${levels[@]:1}")
        case "$first" in
          *:*) ( exec -a "${first%%:*}" /bin/bash "$dir/${first#*:}" ${rest[@]+"${rest[@]}"} -- "$@" ) ;;
          *)   ( exec -a "$first" /bin/bash "$0" ${rest[@]+"${rest[@]}"} -- "$@" ) ;;
        esac
        exit $?
        """.write(to: spawner, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spawner.path)
        // a hosted level needs the spawner under the agent's own name, so the walk reads it as argv[1]
        for level in chain where level.contains(":") {
            try fm.copyItem(at: spawner, to: dir.appendingPathComponent(String(level.split(separator: ":")[1])))
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [spawner.path] + chain + ["--", Self.hook] + args
        var environment = [
            "AGTERM_STATUS_WRAPPER": wrapper.path,
            "AGTERM_SOCKET": "/tmp/agterm.sock",
            "PATH": "/usr/bin:/bin",
        ]
        environment["AGTERM_SESSION_ID"] = sessionID
        environment.merge(extraEnv) { _, new in new }
        proc.environment = environment
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let recorded = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        return (recorded, proc.terminationStatus)
    }

    @Test func paneAgentDelegatesWithArgvVerbatim() throws {
        // one agent between the hook and the pane: the firing agent owns the row, so the call goes through
        // with every argument intact — the flags are the wrapper's, and a user may have appended more
        let result = try run(chain: ["login", "claude"], args: ["completed", "--auto-reset", "--pane", "right"])
        #expect(result.calls == ["completed --auto-reset --pane right"])
        #expect(result.exit == 0)
    }

    @Test func spawnedWorkerStaysSilent() throws {
        // a second agent above ours means another agent spawned this one, so its status belongs to a session
        // that is not the pane's — the row it would repaint is the SPAWNER's
        let result = try run(chain: ["login", "claude", "claude"], args: ["completed", "--auto-reset"])
        #expect(result.calls.isEmpty)
        #expect(result.exit == 0)
    }

    @Test func integrationDrivenSpawnerIsCounted() throws {
        // agterm detects agents by two mechanisms — own hooks (claude, codex, …) and the shell
        // integration's AGTERM_AGENT_RE (gemini, cursor-agent, aider, crush, goose). Both are spawners
        // to this walk: a claude worker under gemini must not repaint the gemini pane.
        let result = try run(chain: ["login", "gemini", "claude"], args: ["completed", "--auto-reset"])
        #expect(result.calls.isEmpty)
        #expect(result.exit == 0)
    }

    @Test func overriddenAgentRegexExtendsTheSet() throws {
        // integration.sh documents overriding AGTERM_AGENT_RE, and on the bash/zsh path an exported
        // override reaches this process — an agent only the override names is a spawner all the same
        let result = try run(chain: ["login", "my-agent", "claude"], args: ["completed", "--auto-reset"],
                             extraEnv: ["AGTERM_AGENT_RE": "^(my-agent)([[:space:]]|$)"])
        #expect(result.calls.isEmpty)
        #expect(result.exit == 0)
    }

    @Test func invalidOverrideRegexFailsOpen() throws {
        // fish and RE_MATCH_PCRE zsh accept PCRE, so an override can be valid in the shell that set it
        // and invalid as the ERE this script matches with — that case must degrade to the literal list
        // (the pane's own agent keeps reporting), never to an error or a false silence
        let result = try run(chain: ["login", "claude"], args: ["completed", "--auto-reset"],
                             extraEnv: ["AGTERM_AGENT_RE": "^(?i)(my-agent)$"])
        #expect(result.calls == ["completed --auto-reset"])
        #expect(result.exit == 0)
    }

    @Test func workerUnderScriptStaysSilent() throws {
        // the topology a tty test gets wrong: script/expect give the worker a fresh pty, so it would
        // look pane-owning by terminal state. The walk reads the chain instead — the intermediate
        // process doesn't hide the spawning agent above it.
        let result = try run(chain: ["login", "claude", "script", "claude"], args: ["completed", "--auto-reset"])
        #expect(result.calls.isEmpty)
        #expect(result.exit == 0)
    }

    @Test func exhaustedWalkFailsOpen() throws {
        // more processes above the agent than the 8-hop bound: the walk gives up without reaching a
        // verdict and delegates — a missed guard is the pre-adapter behavior, a false silence is a bug
        // with no symptom
        let deep = ["login", "claude"] + Array(repeating: "sh", count: 8) + ["claude"]
        let result = try run(chain: deep, args: ["completed", "--auto-reset"])
        #expect(result.calls == ["completed --auto-reset"])
        #expect(result.exit == 0)
    }

    @Test func runtimeHostedAgentIsCountedThroughArgv1() throws {
        // a node/bun-hosted CLI presents as `node …/claude`, so argv[0] alone would miss it and the worker
        // would report. Counting it makes this the same two-agent chain as above.
        let result = try run(chain: ["login", "claude", "node:claude"], args: ["active", "--blink"])
        #expect(result.calls.isEmpty)
        #expect(result.exit == 0)
    }

    @Test func walkStopsAtThePaneBoundary() throws {
        // an agent BEYOND the pane boundary is not this pane's business: the walk stops at `login`, so the
        // outer claude is never counted and the inner one still reads as the pane's own agent
        let result = try run(chain: ["claude", "login", "claude"], args: ["active", "--blink"])
        #expect(result.calls == ["active --blink"])
        #expect(result.exit == 0)
    }

    @Test func isAgentCoversTheShippedDefaultRegexNames() throws {
        // the script's own comment states this invariant in prose and round 1 of #461 shipped it broken:
        // a name added to the default regex and forgotten here stops counting that agent as a spawner
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integration = try String(contentsOf: root
            .appendingPathComponent("agterm/Resources/agent-status/shell/integration.sh"), encoding: .utf8)
        guard let alternation = integration
            .components(separatedBy: "AGTERM_AGENT_RE:=^(").dropFirst().first?
            .components(separatedBy: ")").first, !alternation.isEmpty else {
            Issue.record("integration.sh must define the default AGTERM_AGENT_RE as an anchored alternation")
            return
        }
        let hookText = try String(contentsOf: URL(fileURLWithPath: Self.hook), encoding: .utf8)
        guard let arm = hookText.components(separatedBy: "case \"$1\" in ").dropFirst().first?
            .components(separatedBy: ")").first else {
            Issue.record("agterm-claude-status.sh must classify agents with a `case \"$1\" in ... )` arm")
            return
        }
        let literals = Set(arm.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
        // subset, never equality: the arm also carries the hook-driven agents, which the regex must not
        for name in alternation.components(separatedBy: "|") {
            #expect(literals.contains(name), "is_agent must count \(name) from integration.sh's default regex")
        }
    }

    @Test func outsideAgtermExitsSilently() throws {
        // no session id: nothing to address, and a hook must never fail the turn it fired from
        let result = try run(chain: ["login", "claude"], args: ["completed", "--auto-reset"], sessionID: nil)
        #expect(result.calls.isEmpty)
        #expect(result.exit == 0)
    }
}
