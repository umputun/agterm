#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOOK_SCRIPT = HERE / "agy-status-hook.sh"


class AgyStatusHookTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.status_log = self.root / "status-calls.jsonl"
        self.status_script = self.root / "fake-status.sh"
        self.status_script.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                "$PYTHON_BIN" -c 'import json, os, sys; open(os.environ["FAKE_STATUS_LOG"], "a").write(json.dumps(sys.argv[1:]) + "\\n")' "$@"
                """
            )
        )
        self.status_script.chmod(0o755)

        self.fake_agy = self.root / "agy"
        self.fake_agy.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                sh -c '"$TEST_HOOK_SCRIPT" "$TEST_HOOK_ACTION"'
                """
            )
        )
        self.fake_agy.chmod(0o755)

    def run_hook(
        self,
        action,
        payload="{}",
        session_id="11111111-2222-4333-8444-555555555555",
        agy_args=(),
        status_script=None,
        use_wrapper_var=False,
        claude_code="",
        claude_session_id="",
    ):
        self.status_log.unlink(missing_ok=True)
        env = os.environ.copy()
        script_path = str(
            status_script if status_script is not None else self.status_script
        )
        env.pop("AGTERM_STATUS_WRAPPER", None)
        env.pop("AGTERM_STATUS_SCRIPT", None)
        env.update(
            {
                "PYTHON_BIN": sys.executable,
                "FAKE_STATUS_LOG": str(self.status_log),
                "AGTERM_STATUS_WRAPPER"
                if use_wrapper_var
                else "AGTERM_STATUS_SCRIPT": script_path,
                "TEST_HOOK_SCRIPT": str(HOOK_SCRIPT),
                "TEST_HOOK_ACTION": action,
            }
        )
        if session_id:
            env["AGTERM_SESSION_ID"] = session_id
        else:
            env.pop("AGTERM_SESSION_ID", None)

        if claude_code:
            env["CLAUDECODE"] = claude_code
        else:
            env.pop("CLAUDECODE", None)

        if claude_session_id:
            env["CLAUDE_CODE_SESSION_ID"] = claude_session_id
        else:
            env.pop("CLAUDE_CODE_SESSION_ID", None)

        result = subprocess.run(
            [str(self.fake_agy), *agy_args],
            input=payload,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        calls = []
        if self.status_log.exists():
            calls = [
                json.loads(line) for line in self.status_log.read_text().splitlines()
            ]
        return result.stdout, calls

    def test_stdout_and_status_per_action(self):
        cases = [
            ("invocation", "{}", {}, [["active", "--blink"]]),
            ("tool-done", "{}", {}, [["active", "--blink"]]),
            ("ask", "{}", {"decision": "allow"}, [["blocked"]]),
            (
                "stop",
                '{"fullyIdle":true}',
                {"decision": "stop"},
                [["completed", "--auto-reset"]],
            ),
        ]
        for action, payload, expected_json, expected_calls in cases:
            with self.subTest(action=action):
                stdout, calls = self.run_hook(action, payload=payload)
                self.assertEqual(expected_json, json.loads(stdout))
                self.assertEqual(1, len(stdout.splitlines()))
                self.assertEqual(expected_calls, calls)

        stdout, calls = self.run_hook("invocation", use_wrapper_var=True)
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual([["active", "--blink"]], calls)

    def test_outside_agterm_prints_json_without_calling_status_script(self):
        for action, expected in (
            ("invocation", {}),
            ("ask", {"decision": "allow"}),
            ("stop", {"decision": "stop"}),
        ):
            with self.subTest(action=action):
                stdout, calls = self.run_hook(action, session_id="")
                self.assertEqual(expected, json.loads(stdout))
                self.assertEqual([], calls)

    def test_skips_claude_code_worker(self):
        stdout, calls = self.run_hook("invocation", claude_code="1")
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual([], calls)

        stdout, calls = self.run_hook("ask", claude_session_id="claude-parent-123")
        self.assertEqual({"decision": "allow"}, json.loads(stdout))
        self.assertEqual([], calls)

    def test_stop_fully_idle_variants_and_pretty_json(self):
        pretty_true = '{\n  "executionNum": 1,\n  "fullyIdle" : true\n}\n'
        stdout, calls = self.run_hook("stop", payload=pretty_true)
        self.assertEqual({"decision": "stop"}, json.loads(stdout))
        self.assertEqual([["completed", "--auto-reset"]], calls)

        compact_false = '{"executionNum":1,"fullyIdle":false}'
        stdout, calls = self.run_hook("stop", payload=compact_false)
        self.assertEqual({"decision": "stop"}, json.loads(stdout))
        self.assertEqual([], calls)

        pretty_false = '{\n  "executionNum": 1,\n  "fullyIdle" : false\n}\n'
        stdout, calls = self.run_hook("stop", payload=pretty_false)
        self.assertEqual({"decision": "stop"}, json.loads(stdout))
        self.assertEqual([], calls)

    def test_headless_runs_skip_status_script(self):
        for flag in ("-p", "--print", "--prompt", "--print=say-ok", "--prompt=say-ok"):
            with self.subTest(flag=flag):
                stdout, calls = self.run_hook(
                    "invocation", agy_args=(flag, "say ok")
                )
                self.assertEqual({}, json.loads(stdout))
                self.assertEqual([], calls)

        stdout, calls = self.run_hook(
            "invocation", agy_args=("--prompt-interactive", "say ok")
        )
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual([["active", "--blink"]], calls)

    def test_missing_status_script_still_prints_json(self):
        missing = self.root / "nonexistent-status.sh"
        for action, expected in (
            ("invocation", {}),
            ("ask", {"decision": "allow"}),
            ("stop", {"decision": "stop"}),
        ):
            with self.subTest(action=action):
                stdout, calls = self.run_hook(action, status_script=missing)
                self.assertEqual(expected, json.loads(stdout))
                self.assertEqual([], calls)

    def test_unknown_action_prints_empty_json_and_exits_cleanly(self):
        stdout, calls = self.run_hook("unknown-action")
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual([], calls)

    def test_hooks_json_is_valid_and_quotes_home(self):
        hooks_path = HERE / "agy-status-hooks.json"
        data = json.loads(hooks_path.read_text())
        self.assertIn("agterm-status", data)
        block = data["agterm-status"]
        for event in ("PreInvocation", "Stop"):
            self.assertTrue(block[event][0]["command"].startswith('"$HOME/'))
        for event in ("PreToolUse", "PostToolUse"):
            self.assertTrue(
                block[event][0]["hooks"][0]["command"].startswith('"$HOME/')
            )


if __name__ == "__main__":
    unittest.main()
