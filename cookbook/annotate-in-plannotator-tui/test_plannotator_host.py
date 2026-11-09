#!/usr/bin/env python3
"""Regression test for plannotator-host.py: the replies plannotator-tui reads from its `herdr` CLI.

plannotator-tui parses a refusal from the JSON envelope on stderr and treats exit 0 as delivered,
so the exit status and the envelope's `error.code` are the contract checked here.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HOST = Path(__file__).resolve().parent / "plannotator-host.py"


def run(args, **env):
    return subprocess.run(
        [sys.executable, str(HOST), *args],
        env={**os.environ, **env},
        capture_output=True,
        text=True,
        check=False,
    )


def error_code(result):
    return json.loads(result.stderr)["error"]["code"]


class HostTest(unittest.TestCase):
    def setUp(self):
        self.room = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.room)
        self.outbox = self.room / "outbox.jsonl"

    def test_pane_read_returns_the_capture_whatever_the_flags(self):
        capture = self.room / "capture.txt"
        capture.write_text("$ make test\nok\n", encoding="utf-8")
        result = run(
            ["pane", "read", "left pane", "--source", "recent-unwrapped", "--lines", "50", "--format", "text"],
            AGT_ANNOTATE_CAPTURE=str(capture),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "$ make test\nok\n")

    def test_each_prompt_is_one_json_line_in_the_outbox(self):
        for text in ("# Annotations\n> first", "# Annotations\n> second"):
            result = run(["agent", "prompt", "left pane", text], AGT_ANNOTATE_OUTBOX=str(self.outbox))
            self.assertEqual(result.returncode, 0, result.stderr)
        sends = [json.loads(line) for line in self.outbox.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(sends, ["# Annotations\n> first", "# Annotations\n> second"])

    def test_a_refused_pane_writes_nothing_and_names_the_reason(self):
        result = run(
            ["agent", "prompt", "left pane", "note"],
            AGT_ANNOTATE_OUTBOX=str(self.outbox),
            AGT_ANNOTATE_REFUSE="nothing is running in the left pane",
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(error_code(result), "agent_not_found")
        self.assertIn("nothing is running", result.stderr)
        self.assertFalse(self.outbox.exists())

    def test_an_empty_prompt_is_refused(self):
        result = run(["agent", "prompt", "left pane", "  \n"], AGT_ANNOTATE_OUTBOX=str(self.outbox))
        self.assertEqual(error_code(result), "empty_agent_prompt")
        self.assertFalse(self.outbox.exists())

    def test_pane_get_labels_the_agent_or_refuses(self):
        named = run(["pane", "get", "left pane"], PLANNOTATOR_TUI_DELIVER_AGENT="claude")
        self.assertEqual(json.loads(named.stdout)["result"]["pane"]["agent"], "claude")
        unnamed = run(["pane", "get", "left pane"], PLANNOTATOR_TUI_DELIVER_AGENT="")
        self.assertEqual(error_code(unnamed), "agent_not_found")

    def test_any_other_call_is_unsupported_rather_than_faked(self):
        result = run(["pane", "process-info", "--pane", "left pane"])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(error_code(result), "unsupported")
        self.assertIn("pane process-info", result.stderr)


if __name__ == "__main__":
    unittest.main()
