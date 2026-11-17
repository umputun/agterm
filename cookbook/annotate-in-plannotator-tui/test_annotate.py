#!/usr/bin/env python3
"""Regression tests for annotate.py: when reply notes are submitted, and the dropped second press.

A Return after the paste runs the notes in whatever holds the pane, so `runs_claude` is the gate
that keeps them out of a shell. The second-press test runs the script against a fake agtermctl.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent / "annotate.py"


def load(**env):
    saved = {key: os.environ.get(key) for key in env}
    os.environ.update(env)
    try:
        spec = importlib.util.spec_from_file_location("annotate", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


class RunsClaude(unittest.TestCase):
    def test_claude_by_name_or_path_submits(self):
        annotate = load()
        self.assertTrue(annotate.runs_claude(["claude"]))
        self.assertTrue(annotate.runs_claude(["/opt/homebrew/bin/claude", "--resume"]))
        self.assertTrue(annotate.runs_claude(["node", "/usr/local/lib/node_modules/.bin/claude"]))

    def test_a_shell_an_ssh_or_an_unknown_foreground_does_not(self):
        annotate = load()
        self.assertFalse(annotate.runs_claude([]))
        self.assertFalse(annotate.runs_claude(None))
        self.assertFalse(annotate.runs_claude(["ssh", "host"]))
        self.assertFalse(annotate.runs_claude(["vim", "claude.md"]))

    def test_the_pattern_can_name_a_wrapper(self):
        annotate = load(CLAUDE_FG_MATCH=r"(^|/)(claude|mywrapper)$")
        self.assertTrue(annotate.runs_claude(["sh", "/usr/local/bin/mywrapper"]))


class SecondPress(unittest.TestCase):
    def test_a_held_lock_says_where_it_is(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = Path(tmp) / "calls"
            fake = Path(tmp) / "agtermctl"
            fake.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{calls}"\n', encoding="utf-8")
            fake.chmod(0o755)
            tui = Path(tmp) / "plannotator-tui"
            tui.write_text("#!/bin/sh\n", encoding="utf-8")
            tui.chmod(0o755)
            lock = Path(tmp) / "agterm-annotate" / "S1.left" / "lock"
            lock.mkdir(parents=True)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "replies"],
                env={
                    **os.environ,
                    "TMPDIR": tmp,
                    "AGTERMCTL": str(fake),
                    "PLANNOTATOR_TUI": str(tui),
                    "AGT_SESSION_ID": "S1",
                    "AGT_PANE": "left",
                },
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            said = calls.read_text(encoding="utf-8")
            self.assertIn("notify", said)
            self.assertIn(str(lock), said)
            self.assertTrue(lock.is_dir(), "a dropped press must leave the open viewer's lock alone")


class StaleOutbox(unittest.TestCase):
    def test_an_outbox_left_by_an_earlier_viewer_is_not_pasted(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = Path(tmp) / "calls"
            fake = Path(tmp) / "agtermctl"
            # Every call succeeds and prints nothing: the viewer closes without sending.
            fake.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{calls}"\n', encoding="utf-8")
            fake.chmod(0o755)
            tui = Path(tmp) / "plannotator-tui"
            tui.write_text("#!/bin/sh\n", encoding="utf-8")
            tui.chmod(0o755)
            room = Path(tmp) / "agterm-annotate" / "S1.left"
            room.mkdir(parents=True)
            (room / "outbox.jsonl").write_text('"old notes"\n', encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "pane"],
                env={
                    **os.environ,
                    "TMPDIR": tmp,
                    "AGTERMCTL": str(fake),
                    "PLANNOTATOR_TUI": str(tui),
                    "AGT_SESSION_ID": "S1",
                    "AGT_PANE": "left",
                    "AGT_SELECTION": "some output",
                },
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            said = calls.read_text(encoding="utf-8")
            self.assertIn("overlay open", said)
            self.assertNotIn("session paste", said)
            self.assertFalse((room / "outbox.jsonl").exists())


DAEMON = "agterm-" + "ab" * 16
ORIGIN = "23F5DD35-34F6-43D8-843B-4FAD66CB9F04"


def fake(path, body):
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(0o755)


WINDOW = "60898DCF-6171-49E4-BA36-C3D38A088DE8"
FAR = "/far/annotate.py"


class Attached(unittest.TestCase):
    """A pane attached from another Mac, against a fake agtermctl, ssh and clipboard."""

    def chord_env(self, tmp, ssh_body, foreground, extra=None):
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        calls = tmp / "calls"
        calls.touch()
        tree = json.dumps({"result": {"tree": {"workspaces": [{"sessions": [{"id": "S1", "foreground": foreground}]}]}}})
        (tmp / "tree.json").write_text(tree, encoding="utf-8")
        fake(bin_dir / "agtermctl", f'printf "agtermctl %s\\n" "$*" >> "{calls}"\n'
             f'case "$1" in tree) cat "{tmp / "tree.json"}";; esac\n')
        fake(bin_dir / "ssh", f'printf "ssh %s\\n" "$*" >> "{calls}"\n' + ssh_body)
        fake(bin_dir / "pbcopy", "cat > /dev/null\n")
        fake(bin_dir / "pbpaste", "true\n")
        fake(bin_dir / "plannotator-tui", "true\n")
        return {
            **os.environ,
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "TMPDIR": str(tmp),
            "AGTERM_ANNOTATE_DIR": str(tmp / "cache"),
            "AGTERMCTL": str(bin_dir / "agtermctl"),
            "AGTERM_ANNOTATE_SSH": str(bin_dir / "ssh"),
            # Named, so the command ssh sends does not depend on where this clone sits.
            "AGTERM_ANNOTATE_REMOTE": FAR,
            "PLANNOTATOR_TUI": str(bin_dir / "plannotator-tui"),
            "AGT_SESSION_ID": "S1",
            "AGT_PANE": "left",
            "AGT_SESSION_HOST": "me@mini",
            **(extra or {}),
        }

    def run_chord(self, tmp, mode, ssh_body, foreground, extra=None):
        tmp = Path(tmp)
        env = self.chord_env(tmp, ssh_body, foreground, extra)
        result = subprocess.run([sys.executable, str(SCRIPT), mode], env=env, capture_output=True, text=True, check=False)
        return result, (tmp / "calls").read_text(encoding="utf-8")

    @staticmethod
    def far(located, taken="{}"):
        return f"case \"$*\" in *' locate {DAEMON}') echo '{located}';; *' take {ORIGIN} left {WINDOW}') echo '{taken}';; esac\n"

    LOCATED = json.dumps({"session": ORIGIN, "pane": "left", "window": WINDOW, "foreground": ["claude"], "transcript": "/x.jsonl"})

    def test_replies_run_the_viewer_on_the_other_mac_and_paste_here(self):
        taken = json.dumps({"notes": "my notes", "sends": 2, "claude": True})
        with tempfile.TemporaryDirectory() as tmp:
            result, said = self.run_chord(tmp, "replies", self.far(self.LOCATED, taken), ["/bin/sh", "-c", f"ssh me@mini zmx attach {DAEMON}"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"-- me@mini {FAR} locate {DAEMON}", said)
            overlay = next(line for line in said.splitlines() if "overlay open" in line)
            self.assertIn("-tt", overlay)
            self.assertIn(f"serve {ORIGIN} left {WINDOW}", overlay)
            self.assertNotIn("herdr pane", overlay, "the viewer must run over there, not here")
            self.assertIn("session paste --target S1 --pane left", said)
            self.assertIn("session type --stdin --target S1 --pane left", said)
            self.assertEqual((Path(tmp) / "cache" / "last-notes.md").read_text(encoding="utf-8"), "my notes")

    def test_notes_are_pasted_unsent_when_claude_is_gone_over_there(self):
        taken = json.dumps({"notes": "my notes", "sends": 1, "claude": False})
        with tempfile.TemporaryDirectory() as tmp:
            result, said = self.run_chord(tmp, "replies", self.far(self.LOCATED, taken), ["ssh", f"zmx attach {DAEMON}"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("session paste", said)
            self.assertNotIn("session type", said)

    def test_this_macs_submit_setting_wins_over_the_other_mac(self):
        # SUBMIT["replies"] = False is how a user stops reply notes at the prompt; Claude running
        # over there must not override it.
        taken = json.dumps({"notes": "my notes", "sends": 1, "claude": True})
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            env = self.chord_env(tmp, self.far(self.LOCATED, taken), ["ssh", DAEMON])
            with mock.patch.dict(os.environ, env, clear=True):
                annotate = load()
                annotate.SUBMIT["replies"] = False
                code = annotate.main(["replies"])
            said = (tmp / "calls").read_text(encoding="utf-8")
            self.assertEqual(code, 0)
            self.assertIn("session paste", said)
            self.assertNotIn("session type", said)

    def test_an_unreachable_mac_is_said_and_nothing_opens(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, said = self.run_chord(tmp, "replies", "echo 'Connection refused' >&2; exit 255\n", ["ssh", DAEMON])
            self.assertEqual(result.returncode, 1)
            self.assertIn("could not reach me@mini", said)
            self.assertNotIn("overlay open", said)

    def test_a_pane_review_goes_on_when_the_other_side_has_no_recipe(self):
        # An agterm-server Linux host, or a Mac with an older copy: the pane chord worked there
        # before and needs nothing from that side.
        with tempfile.TemporaryDirectory() as tmp:
            body = "echo 'annotate.py: not found' >&2; exit 127\n"
            result, said = self.run_chord(tmp, "pane", body, ["ssh", DAEMON], {"AGT_SELECTION": "output"})
            self.assertEqual(result.returncode, 0, result.stderr)
            overlay = next(line for line in said.splitlines() if "overlay open" in line)
            self.assertIn("herdr pane", overlay)
            self.assertNotIn("notify", said)

    def test_a_pane_with_no_daemon_stays_local(self):
        # A split opened here on an attached session runs a local shell: no ssh, the local record.
        with tempfile.TemporaryDirectory() as tmp:
            result, said = self.run_chord(tmp, "replies", "exit 9\n", ["/bin/zsh"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("ssh ", said)
            self.assertIn("no Claude transcript on record yet", said)

    def test_a_pane_review_stays_here_and_names_the_agent_over_there(self):
        located = json.dumps({"session": ORIGIN, "pane": "left", "window": WINDOW, "foreground": ["/opt/bin/claude"], "transcript": ""})
        with tempfile.TemporaryDirectory() as tmp:
            result, said = self.run_chord(tmp, "pane", self.far(located), ["ssh", DAEMON], {"AGT_SELECTION": "output"})
            self.assertEqual(result.returncode, 0, result.stderr)
            overlay = next(line for line in said.splitlines() if "overlay open" in line)
            self.assertIn("herdr pane", overlay)
            self.assertIn("PLANNOTATOR_TUI_DELIVER_AGENT=claude", overlay)
            self.assertNotIn(" take ", said)


class OnTheOtherMac(unittest.TestCase):
    """The helper modes, run where the session runs, against a fake agtermctl."""

    def helper(self, tmp, *argv, foreground=("claude",)):
        tmp = Path(tmp)
        zmx = json.dumps({"result": {"remote": {"sessions": [
            {"id": ORIGIN, "windowID": WINDOW, "panes": [{"pane": "left", "daemon": DAEMON}]}]}}})
        tree = json.dumps({"result": {"tree": {"workspaces": [{"sessions": [{"id": ORIGIN, "foreground": list(foreground)}]}]}}})
        (tmp / "zmx.json").write_text(zmx, encoding="utf-8")
        (tmp / "tree.json").write_text(tree, encoding="utf-8")
        ctl = tmp / "agtermctl"
        # tree answers only when asked for the session's own window, as the far side's frontmost
        # window may be another one
        fake(ctl, f'printf "%s\\n" "$*" >> "{tmp / "ctl-calls"}"\n'
             f'case "$*" in zmx*) cat "{tmp / "zmx.json"}";; "tree --json --window {WINDOW}") cat "{tmp / "tree.json"}";; '
             f'tree*) echo \'{{"result": {{"tree": {{"workspaces": []}}}}}}\';; esac\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith("AGT_")}
        env.update({"TMPDIR": str(tmp), "AGTERM_ANNOTATE_DIR": str(tmp / "cache"), "AGTERMCTL": str(ctl)})
        result = subprocess.run([sys.executable, str(SCRIPT), *argv], env=env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_locate_names_the_session_its_window_foreground_and_transcript(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / "t.jsonl"
            transcript.write_text("{}\n", encoding="utf-8")
            (Path(tmp) / "cache").mkdir()
            (Path(tmp) / "cache" / f"{ORIGIN}.left.json").write_text(json.dumps({"transcript_path": str(transcript)}), encoding="utf-8")
            got = self.helper(tmp, "locate", DAEMON)
            self.assertEqual(got, {"session": ORIGIN, "pane": "left", "window": WINDOW, "foreground": ["claude"],
                                   "transcript": str(transcript)})

    def test_locate_of_an_unknown_daemon_is_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.helper(tmp, "locate", "agterm-" + "cd" * 16), {})

    def test_take_hands_over_the_last_send_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            room = Path(tmp) / "agterm-annotate" / f"remote-{ORIGIN}.left"
            room.mkdir(parents=True)
            (room / "outbox.jsonl").write_text('"first"\n"whole review"\n', encoding="utf-8")
            self.assertEqual(self.helper(tmp, "take", ORIGIN, "left", WINDOW), {"notes": "whole review", "sends": 2, "claude": True})
            self.assertFalse((room / "outbox.jsonl").exists())
            self.assertEqual(self.helper(tmp, "take", ORIGIN, "left", WINDOW), {"notes": None, "sends": 0, "claude": False})

    def test_take_sees_no_claude_in_a_shell(self):
        with tempfile.TemporaryDirectory() as tmp:
            room = Path(tmp) / "agterm-annotate" / f"remote-{ORIGIN}.left"
            room.mkdir(parents=True)
            (room / "outbox.jsonl").write_text('"notes"\n', encoding="utf-8")
            self.assertFalse(self.helper(tmp, "take", ORIGIN, "left", WINDOW, foreground=())["claude"])

    def test_the_helpers_refuse_what_is_not_a_daemon_session_or_window(self):
        for argv in (["locate", "x; rm -rf ~"], ["take", "not-a-uuid", "left", "-"], ["serve", ORIGIN, "scratch", "-"],
                     ["take", ORIGIN, "left", "$(id)"], ["take", ORIGIN, "left"]):
            result = subprocess.run([sys.executable, str(SCRIPT), *argv], capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0, argv)


class RemoteScript(unittest.TestCase):
    def test_a_path_under_home_is_found_under_the_other_home(self):
        annotate = load()
        here = Path(os.path.realpath(SCRIPT))
        if Path.home() in here.parents:
            self.assertTrue(annotate.remote_script().startswith("$HOME/"))

    def test_the_override_is_used_as_given(self):
        annotate = load()
        with mock.patch.dict(os.environ, {"AGTERM_ANNOTATE_REMOTE": "/opt/annotate dir/annotate.py"}):
            self.assertEqual(annotate.remote_script(), "'/opt/annotate dir/annotate.py'")


if __name__ == "__main__":
    unittest.main()
