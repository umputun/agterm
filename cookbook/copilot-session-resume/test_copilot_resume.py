#!/usr/bin/env python3

import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

PANE_ID = "01900000-0005-7000-8000-000000000006"
OLD_ID = "01900000-0000-7000-8000-000000000001"
NEW_ID = "01900000-0001-7000-8000-000000000002"
HERE = Path(__file__).parent
RECIPE = Path(
    os.environ.get("COPILOT_RESUME_SCRIPT", HERE / "copilot-resume.zsh")
).resolve()
HOOK = Path(
    os.environ.get("COPILOT_RESUME_HOOK", HERE / "copilot-resume-hook.sh")
).resolve()
OWN = "--secret-env-vars=AGTERM_COPILOT_RESUME"
FAKE_COPILOT = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json
    import os
    import sys

    with open(os.environ["FAKE_COPILOT_LOG"], "a") as log:
        print(json.dumps(sys.argv[1:]), file=log)
    sys.exit(int(os.environ.get("FAKE_COPILOT_EXIT", "0")))
    """
)


class CopilotResumeFunctionTest(unittest.TestCase):
    def setUp(self):
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        self.home = Path(temp_dir.name)
        self.map_file = self.home / ".copilot" / "agterm" / PANE_ID
        self.log = self.home / "copilot-args.jsonl"
        self.bin_dir = self.home / "bin"
        self.bin_dir.mkdir()
        fake = self.bin_dir / "copilot"
        fake.write_text(FAKE_COPILOT)
        fake.chmod(0o755)

    def run_copilot(self, *args, pane=PANE_ID, extra_env=None, piped=False, prelude=""):
        env = os.environ.copy()
        for name in ("AGTERM_PANE_ID", "COPILOT_HOME", "COPILOT_CLI", "COPILOT_AGENT_SESSION_ID"):
            env.pop(name, None)
        env.update(
            {
                "FAKE_COPILOT_LOG": str(self.log),
                "HOME": str(self.home),
                "PATH": f"{self.bin_dir}{os.pathsep}{env['PATH']}",
                "RECIPE": str(RECIPE),
            }
        )
        if pane is not None:
            env["AGTERM_PANE_ID"] = pane
        env.update(extra_env or {})
        # a pane's copilot reads a terminal; piped stdin is a headless run
        stdin_fd = None
        if not piped:
            master, stdin_fd = os.openpty()
            self.addCleanup(os.close, master)
            self.addCleanup(os.close, stdin_fd)
        return subprocess.run(
            ["zsh", "-fc", prelude + 'source "$RECIPE"\ncopilot "$@"', "test-harness", *args],
            env=env,
            stdin=stdin_fd,
            input="question\n" if piped else None,
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def map_to(self, session_id, path=None):
        path = path or self.map_file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(session_id + "\n")

    def test_runs_as_typed_where_it_cannot_track(self):
        self.map_to(OLD_ID)
        cases = {
            "outside agterm": {"pane": None},
            "malformed pane": {"pane": "../../etc"},
            "copilot tool shell": {"extra_env": {"COPILOT_CLI": "1"}},
            "copilot agent shell": {"extra_env": {"COPILOT_AGENT_SESSION_ID": OLD_ID}},
            "piped stdin": {"piped": True},
        }
        for name, kwargs in cases.items():
            with self.subTest(name):
                self.log.unlink(missing_ok=True)
                self.run_copilot("--model", "x", **kwargs)
                self.assertEqual([["--model", "x"]], self.calls())

    def test_npm_install_runs_as_typed(self):
        loader = self.home / "lib" / "node_modules" / "@github" / "copilot" / "npm-loader.js"
        loader.parent.mkdir(parents=True)
        (self.bin_dir / "copilot").rename(loader)
        (self.bin_dir / "copilot").symlink_to(loader)
        self.map_to(OLD_ID)
        self.run_copilot("--model", "x")
        self.assertEqual([["--model", "x"]], self.calls())

    def test_first_launch_marks_without_session(self):
        self.run_copilot("--model", "x")
        self.assertEqual([[OWN, "--model", "x"]], self.calls())

    def test_mapped_pane_resumes_its_session(self):
        self.map_to(OLD_ID)
        self.run_copilot("--model", "x", pane=PANE_ID.upper())
        self.assertEqual([[OWN, "--session-id", OLD_ID, "--model", "x"]], self.calls())

    def test_unusable_mapping_starts_fresh(self):
        for name, content in {"malformed": "not-a-session", "not hex": "z" * 8 + OLD_ID[8:]}.items():
            with self.subTest(name):
                self.log.unlink(missing_ok=True)
                self.map_to(content)
                self.run_copilot()
                self.assertEqual([[OWN]], self.calls())
        self.map_file.unlink()
        self.map_file.mkdir()
        self.log.unlink()
        result = self.run_copilot()
        self.assertEqual("", result.stderr)
        self.assertEqual([[OWN]], self.calls())

    def test_copilot_home_holds_the_mapping(self):
        copilot_home = self.home / "alt"
        self.map_to(NEW_ID, copilot_home / "agterm" / PANE_ID)
        self.run_copilot(extra_env={"COPILOT_HOME": str(copilot_home)})
        self.assertEqual([[OWN, "--session-id", NEW_ID]], self.calls())

    def test_replay_decides_again_from_the_mapping(self):
        self.map_to(NEW_ID)
        self.run_copilot(OWN, "--session-id", OLD_ID, "--model", "x")
        self.assertEqual([[OWN, "--session-id", NEW_ID, "--model", "x"]], self.calls())

    def test_replay_without_a_mapping_starts_fresh(self):
        self.run_copilot(OWN, "--session-id", OLD_ID, "--model", "x")
        self.assertEqual([[OWN, "--model", "x"]], self.calls())

    def test_existing_alias_does_not_block_the_function(self):
        result = self.run_copilot(prelude="alias copilot='copilot --model y'\n")
        self.assertEqual("", result.stderr)
        self.assertEqual([[OWN]], self.calls())

    def test_value_option_without_a_value_adds_nothing(self):
        self.run_copilot("--model")
        self.assertEqual([[OWN, "--model"]], self.calls())

    def test_replay_drops_the_launch_prompt(self):
        self.map_to(NEW_ID)
        self.run_copilot(
            OWN, "--session-id", OLD_ID, "-i", "fix it", "--interactive=again", "-inow",
            "--model", "x", "--interactive", "last", "--", "-i", "kept",
        )
        self.run_copilot(OWN, "-i")
        self.assertEqual(
            [[OWN, "--session-id", NEW_ID, "--model", "x", "--", "-i", "kept"], [OWN, "--session-id", NEW_ID]],
            self.calls(),
        )

    def test_typed_launch_prompt_is_kept(self):
        self.map_to(NEW_ID)
        for args in (["-i", "help"], ["-i", "--help"], ["--interactive", "-p"]):
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                self.run_copilot(*args)
                self.assertEqual([[OWN, "--session-id", NEW_ID, *args]], self.calls())

    def test_option_value_is_not_a_subcommand(self):
        args = [
            "--model", "sessions", "-C", "mcp", "--secret-env-vars", "help", "--effort", "init",
            "--allow-tool", "skill", "--excluded-tools", "plugin",
        ]
        self.run_copilot(*args)
        self.assertEqual([[OWN, *args]], self.calls())

    def test_explicit_selectors_subcommands_and_headless_pass_through(self):
        self.map_to(NEW_ID)
        cases = [
            ["-p", "hi"],
            ["-phi"],
            ["--prompt=hi"],
            ["--model", "x", "--resume", OLD_ID],
            ["--resume=" + OLD_ID],
            ["--continue"],
            ["--session-id", OLD_ID],
            ["--new-session-id", OLD_ID],
            ["-n", "feature"],
            ["--connect"],
            ["--acp"],
            ["--server"],
            ["--headless"],
            ["--cloud"],
            ["--worktree"],
            ["-v"],
            ["--help"],
            ["mcp", "list"],
            ["sessions"],
            ["--log-level", "debug", "workflows"],
            ["--secret-env-vars", "TOKEN", "sessions", "list"],
        ]
        for args in cases:
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                self.run_copilot(*args)
                self.assertEqual([args], self.calls())

    def test_exit_status_is_kept(self):
        for args in ([], ["-p", "hi"]):
            with self.subTest(args=args):
                result = self.run_copilot(*args, extra_env={"FAKE_COPILOT_EXIT": "3"})
                self.assertEqual(3, result.returncode, result.stderr)
        result = self.run_copilot(pane=None, extra_env={"FAKE_COPILOT_EXIT": "4"})
        self.assertEqual(4, result.returncode, result.stderr)


class CopilotResumeHookTest(unittest.TestCase):
    """bash started under argv[0] `copilot ...` stands in for Copilot, so the hook reads a real chain with ps."""

    def setUp(self):
        temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(temp_dir.cleanup)
        self.home = Path(temp_dir.name)
        self.map_file = self.home / ".copilot" / "agterm" / PANE_ID

    def run_as(self, argv0, script='"$HOOK"; :', event=None, pane=PANE_ID, extra_env=None):
        env = os.environ.copy()
        for name in ("AGTERM_PANE_ID", "COPILOT_HOME"):
            env.pop(name, None)
        env.update({"HOME": str(self.home), "HOOK": str(HOOK)})
        env.update(extra_env or {})
        if pane is not None:
            env["AGTERM_PANE_ID"] = pane
        # the trailing `:` keeps bash from exec'ing the hook in place of the stand-in
        result = subprocess.run(
            [argv0, "-c", script],
            executable="/bin/bash",
            input=self.event() if event is None else event,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stdout)
        self.assertEqual("", result.stderr)
        return result

    @staticmethod
    def event(session_id=NEW_ID):
        return json.dumps({"sessionId": session_id, "source": "new", "initialPrompt": "hi"})

    def test_records_a_copilot_the_function_started(self):
        self.run_as(f"copilot {OWN}", event=self.event(NEW_ID.upper()))
        self.assertEqual(NEW_ID + "\n", self.map_file.read_text())

    def test_records_through_the_hook_shell(self):
        for shell in ("/bin/bash", "-bash"):
            with self.subTest(shell=shell):
                self.map_file.unlink(missing_ok=True)
                script = f"""(exec -a {shell} /bin/bash --noprofile -c '"$HOOK"; :'); :"""
                self.run_as(f"copilot {OWN} --model x", script=script)
                self.assertEqual(NEW_ID + "\n", self.map_file.read_text())

    def installed_copilot(self, folder):
        path = self.home / folder / "copilot"
        path.parent.mkdir(parents=True)
        path.write_text("#!/bin/sh\n")
        path.chmod(0o755)
        return path

    def test_records_a_copilot_restarted_by_its_path(self):
        for folder in ("Caskroom/1.0", "Copilot CLI/1.0"):
            with self.subTest(folder=folder):
                self.map_file.unlink(missing_ok=True)
                self.run_as(f"{self.installed_copilot(folder)} {OWN} --session-id {OLD_ID}")
                self.assertEqual(NEW_ID + "\n", self.map_file.read_text())

    def test_copilot_home_holds_the_mapping(self):
        copilot_home = self.home / "alt"
        self.run_as(f"copilot {OWN}", extra_env={"COPILOT_HOME": str(copilot_home)})
        self.assertEqual(NEW_ID + "\n", (copilot_home / "agterm" / PANE_ID).read_text())
        self.assertFalse(self.map_file.exists())

    def test_follows_a_new_conversation(self):
        self.map_file.parent.mkdir(parents=True)
        self.map_file.write_text(OLD_ID + "\n")
        self.run_as(f"copilot {OWN}", pane=PANE_ID.upper())
        self.assertEqual(NEW_ID + "\n", self.map_file.read_text())

    def test_ignores_copilots_the_function_did_not_start(self):
        installed = self.installed_copilot("Copilot CLI")
        cases = {
            "typed headless": "copilot -p hi",
            "marker in a prompt": f"copilot -p 'explain {OWN}'",
            "marker after a path in a prompt": f"copilot -p 'see /bin/copilot {OWN}'",
            "marker in the prompt of a path launch": f"{installed} -p 'see {installed} {OWN}'",
            "path that names no program": f"/nonexistent/copilot {OWN}",
            "longer marker": f"copilot {OWN}_EXTRA",
            "other program": f"node {OWN}",
        }
        for name, argv0 in cases.items():
            with self.subTest(name):
                self.run_as(argv0)
                self.assertFalse(self.map_file.exists())

    def test_ignores_a_worker_under_a_marked_copilot(self):
        worker = """(exec -a 'copilot -p hi' /bin/bash -c '"$HOOK"; :'); :"""
        cases = {
            "direct child": worker,
            "behind a tool shell": f"/bin/bash -c {json.dumps(worker)}; :",
        }
        for name, script in cases.items():
            with self.subTest(name):
                self.run_as(f"copilot {OWN}", script=script)
                self.assertFalse(self.map_file.exists())

    def test_ignores_events_it_cannot_place(self):
        cases = {
            "no pane": {"pane": None},
            "bad pane": {"pane": "../../etc"},
            "no session id": {"event": "{}"},
            "bad session id": {"event": self.event("../x")},
        }
        for name, kwargs in cases.items():
            with self.subTest(name):
                self.run_as(f"copilot {OWN}", **kwargs)
                self.assertFalse((self.home / ".copilot" / "agterm").exists())


if __name__ == "__main__":
    unittest.main()
