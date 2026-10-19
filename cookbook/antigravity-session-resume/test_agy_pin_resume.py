#!/usr/bin/env python3

import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PIN_SCRIPT = HERE / "agy-pin-resume.sh"
ZSH_WRAPPER = HERE / "agy-resume.zsh"

SESSION_ID = "11111111-2222-4333-8444-555555555555"
PANE_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
CONV_ID = "c8f6256e-53da-4513-b9c2-c72b1e3f142c"


class AgyPinResumeTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.ctl_log = self.root / "agtermctl-calls.jsonl"
        self.agy_log = self.root / "agy-calls.jsonl"
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()

        self.fake_ctl = self.bin_dir / "agtermctl"
        self.fake_ctl.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                "$PYTHON_BIN" -c 'import json, os, sys; open(os.environ["FAKE_CTL_LOG"], "a").write(json.dumps(sys.argv[1:]) + "\\n")' "$@"
                """
            )
        )
        self.fake_ctl.chmod(0o755)

        self.fake_agy_hook_parent = self.root / "agy"
        self.fake_agy_hook_parent.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                sh -c '"$TEST_PIN_SCRIPT"'
                """
            )
        )
        self.fake_agy_hook_parent.chmod(0o755)

        self.fake_agy_cli = self.bin_dir / "agy"
        self.fake_agy_cli.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                "$PYTHON_BIN" -c 'import json, os, sys; open(os.environ["FAKE_AGY_LOG"], "a").write(json.dumps(sys.argv[1:]) + "\\n")' "$@"
                exit "${FAKE_AGY_EXIT:-0}"
                """
            )
        )
        self.fake_agy_cli.chmod(0o755)

    def read_jsonl(self, path):
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def run_pin_hook(
        self,
        payload=None,
        session_id=SESSION_ID,
        pane_id=PANE_ID,
        socket_path="/tmp/fake-agterm.sock",
        claude_code="",
        claude_session_id="",
        agy_args=(),
    ):
        self.ctl_log.unlink(missing_ok=True)
        if payload is None:
            payload = json.dumps({"conversationId": CONV_ID})

        env = os.environ.copy()
        env.update(
            {
                "PYTHON_BIN": sys.executable,
                "FAKE_CTL_LOG": str(self.ctl_log),
                "AGTERMCTL": str(self.fake_ctl),
                "TEST_PIN_SCRIPT": str(PIN_SCRIPT),
            }
        )
        if session_id:
            env["AGTERM_SESSION_ID"] = session_id
        else:
            env.pop("AGTERM_SESSION_ID", None)

        if pane_id:
            env["AGTERM_PANE_ID"] = pane_id
        else:
            env.pop("AGTERM_PANE_ID", None)

        if socket_path:
            env["AGTERM_SOCKET"] = socket_path
        else:
            env.pop("AGTERM_SOCKET", None)

        if claude_code:
            env["CLAUDECODE"] = claude_code
        else:
            env.pop("CLAUDECODE", None)

        if claude_session_id:
            env["CLAUDE_CODE_SESSION_ID"] = claude_session_id
        else:
            env.pop("CLAUDE_CODE_SESSION_ID", None)

        result = subprocess.run(
            [str(self.fake_agy_hook_parent), *agy_args],
            input=payload,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return result.stdout, self.read_jsonl(self.ctl_log)

    def test_pins_conversation_with_target_pane_and_socket(self):
        stdout, calls = self.run_pin_hook()
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual(
            [
                [
                    "session",
                    "restore",
                    f"agy --conversation {CONV_ID}",
                    "--target",
                    SESSION_ID,
                    "--pane-id",
                    PANE_ID,
                    "--socket",
                    "/tmp/fake-agterm.sock",
                ]
            ],
            calls,
        )

    def test_skips_when_pane_id_is_unset(self):
        pretty_payload = f'{{\n  "conversationId" : "{CONV_ID}"\n}}\n'
        stdout, calls = self.run_pin_hook(payload=pretty_payload, pane_id="")
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual([], calls)

    def test_rejects_unsafe_or_empty_conversation_id(self):
        unsafe_ids = [
            "",
            "-leading-hyphen",
            "--help",
            "id with spaces",
            "id;rm -rf /",
            "$(whoami)",
            "`id`",
            "../other",
            "id'quote",
        ]
        for bad_id in unsafe_ids:
            with self.subTest(bad_id=bad_id):
                stdout, calls = self.run_pin_hook(
                    payload=json.dumps({"conversationId": bad_id})
                )
                self.assertEqual({}, json.loads(stdout))
                self.assertEqual([], calls)

    def test_skips_headless_runs(self):
        for flag in ("-p", "--print", "--prompt", "--print=hi", "--prompt=hi"):
            with self.subTest(flag=flag):
                stdout, calls = self.run_pin_hook(agy_args=(flag, "say ok"))
                self.assertEqual({}, json.loads(stdout))
                self.assertEqual([], calls)

    def test_skips_claude_code_worker(self):
        stdout, calls = self.run_pin_hook(claude_code="1")
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual([], calls)

        stdout, calls = self.run_pin_hook(claude_session_id="claude-parent-123")
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual([], calls)

    def test_skips_outside_agterm(self):
        stdout, calls = self.run_pin_hook(session_id="")
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual([], calls)

        stdout, calls = self.run_pin_hook(socket_path="")
        self.assertEqual({}, json.loads(stdout))
        self.assertEqual([], calls)

    def run_zsh_wrapper(
        self,
        *args,
        exit_code=0,
        session_id=SESSION_ID,
        pane_id=PANE_ID,
        socket_path="/tmp/fake-agterm.sock",
        claude_code="",
        claude_session_id="",
    ):
        if not shutil.which("zsh"):
            self.skipTest("zsh is not installed")
        self.ctl_log.unlink(missing_ok=True)
        self.agy_log.unlink(missing_ok=True)

        env = os.environ.copy()
        env.update(
            {
                "PYTHON_BIN": sys.executable,
                "FAKE_CTL_LOG": str(self.ctl_log),
                "FAKE_AGY_LOG": str(self.agy_log),
                "FAKE_AGY_EXIT": str(exit_code),
                "AGTERMCTL": str(self.fake_ctl),
                "HOME": str(self.root),
                "PATH": f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}",
                "WRAPPER": str(ZSH_WRAPPER),
                "TERM": "xterm-256color",
            }
        )
        if session_id:
            env["AGTERM_SESSION_ID"] = session_id
        else:
            env.pop("AGTERM_SESSION_ID", None)

        if pane_id:
            env["AGTERM_PANE_ID"] = pane_id
        else:
            env.pop("AGTERM_PANE_ID", None)

        if socket_path:
            env["AGTERM_SOCKET"] = socket_path
        else:
            env.pop("AGTERM_SOCKET", None)

        if claude_code:
            env["CLAUDECODE"] = claude_code
        else:
            env.pop("CLAUDECODE", None)

        if claude_session_id:
            env["CLAUDE_CODE_SESSION_ID"] = claude_session_id
        else:
            env.pop("CLAUDE_CODE_SESSION_ID", None)

        result = subprocess.run(
            ["zsh", "-fic", 'source "$WRAPPER"; agy "$@"', "test-harness", *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )
        return (
            result.returncode,
            self.read_jsonl(self.agy_log),
            self.read_jsonl(self.ctl_log),
        )

    def test_zsh_wrapper_passes_arguments_and_unpins_after_interactive_run(self):
        rc, agy_calls, ctl_calls = self.run_zsh_wrapper(
            "--conversation", CONV_ID, "--model", "gemini-2.5-pro"
        )
        self.assertEqual(0, rc)
        self.assertEqual(
            [["--conversation", CONV_ID, "--model", "gemini-2.5-pro"]],
            agy_calls,
        )
        self.assertEqual(
            [
                [
                    "session",
                    "restore",
                    "--clear",
                    "--target",
                    SESSION_ID,
                    "--pane-id",
                    PANE_ID,
                    "--socket",
                    "/tmp/fake-agterm.sock",
                ]
            ],
            ctl_calls,
        )

    def test_zsh_wrapper_skips_unpin_when_pane_id_is_unset(self):
        rc, agy_calls, ctl_calls = self.run_zsh_wrapper(pane_id="")
        self.assertEqual(0, rc)
        self.assertEqual([[]], agy_calls)
        self.assertEqual([], ctl_calls)

    def test_zsh_wrapper_preserves_nonzero_exit_status_and_still_unpins(self):
        rc, agy_calls, ctl_calls = self.run_zsh_wrapper(exit_code=42)
        self.assertEqual(42, rc)
        self.assertEqual([[]], agy_calls)
        self.assertEqual(1, len(ctl_calls))
        self.assertEqual(["session", "restore", "--clear"], ctl_calls[0][:3])

    def test_zsh_wrapper_skips_unpin_on_sighup_or_sigterm_exit(self):
        for signal_rc in (129, 143):
            with self.subTest(signal_rc=signal_rc):
                rc, agy_calls, ctl_calls = self.run_zsh_wrapper(exit_code=signal_rc)
                self.assertEqual(signal_rc, rc)
                self.assertEqual([[]], agy_calls)
                self.assertEqual([], ctl_calls)

    def test_zsh_wrapper_does_not_unpin_after_headless_info_or_subcommand_run(self):
        for flag_args in (
            ("-p", "say ok"),
            ("--print", "say ok"),
            ("--prompt", "say ok"),
            ("--print=say ok",),
            ("--prompt=say ok",),
            ("-h",),
            ("--help",),
            ("--version",),
            ("mcp", "list"),
            ("models",),
            ("update",),
        ):
            with self.subTest(flag_args=flag_args):
                rc, agy_calls, ctl_calls = self.run_zsh_wrapper(*flag_args)
                self.assertEqual(0, rc)
                self.assertEqual([list(flag_args)], agy_calls)
                self.assertEqual([], ctl_calls)

        rc, agy_calls, ctl_calls = self.run_zsh_wrapper("--", "-p")
        self.assertEqual(0, rc)
        self.assertEqual([["--", "-p"]], agy_calls)
        self.assertEqual(1, len(ctl_calls))

    def test_zsh_wrapper_skips_unpin_under_claude_code(self):
        rc, agy_calls, ctl_calls = self.run_zsh_wrapper(claude_code="1")
        self.assertEqual(0, rc)
        self.assertEqual([[]], agy_calls)
        self.assertEqual([], ctl_calls)

        rc, agy_calls, ctl_calls = self.run_zsh_wrapper(
            claude_session_id="claude-parent-123"
        )
        self.assertEqual(0, rc)
        self.assertEqual([[]], agy_calls)
        self.assertEqual([], ctl_calls)

    def test_zsh_wrapper_outside_agterm_skips_unpin(self):
        rc, agy_calls, ctl_calls = self.run_zsh_wrapper(session_id="")
        self.assertEqual(0, rc)
        self.assertEqual([[]], agy_calls)
        self.assertEqual([], ctl_calls)

    def test_hooks_json_is_valid_and_quotes_home(self):
        hooks_path = HERE / "agy-resume-hooks.json"
        data = json.loads(hooks_path.read_text())
        self.assertIn("agterm-session-resume", data)
        cmd = data["agterm-session-resume"]["SessionStart"][0]["command"]
        self.assertEqual('"$HOME/.config/agterm/hooks/agy/agy-pin-resume.sh"', cmd)


if __name__ == "__main__":
    unittest.main()
