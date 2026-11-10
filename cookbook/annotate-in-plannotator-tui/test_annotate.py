#!/usr/bin/env python3
"""Regression tests for annotate.py: when reply notes are submitted, and the dropped second press.

A Return after the paste runs the notes in whatever holds the pane, so `runs_claude` is the gate
that keeps them out of a shell. The second-press test runs the script against a fake agtermctl.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
