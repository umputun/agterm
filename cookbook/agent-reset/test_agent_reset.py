#!/usr/bin/env python3
"""Regression checks for agent-reset."""

import os
import runpy
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

# the script compiles its match patterns from the environment as it loads, and overriding them is a
# documented feature, so the suite loads it with those cleared rather than testing whatever the
# developer's shell exports
_WITHOUT_OVERRIDES = {k: v for k, v in os.environ.items()
                      if k not in ("CLAUDE_FG_MATCH", "CODEX_FG_MATCH")}
with patch.dict(os.environ, _WITHOUT_OVERRIDES, clear=True):
    SCRIPT = runpy.run_path(Path(__file__).with_name("agent-reset.py"))
INPUTS_FOR = SCRIPT["inputs_for"]
IS_CLAUDE = SCRIPT["is_claude"]
IS_PRIMARY = SCRIPT["is_primary"]
SUBMIT = SCRIPT["SUBMIT"]
MAIN = SCRIPT["main"]


class DetectionTests(unittest.TestCase):
    def test_is_claude(self):
        cases = [
            ("bare binary", ["/Users/x/.local/bin/claude"], True),
            ("wrapper naming it", ["/bin/sh", "/usr/local/bin/claude", "-c"], True),
            ("shell", ["-zsh"], False),
            ("nothing running", [], False),
            ("another tui", ["/opt/homebrew/bin/lazygit"], False),
            ("not a suffix match", ["/usr/bin/claude-helper"], False),
        ]
        for name, argv, want in cases:
            with self.subTest(name):
                self.assertEqual(IS_CLAUDE(argv), want)

    def test_inputs_for(self):
        cases = [
            ("claude submits with a newline", ["/usr/local/bin/claude"], ("/clear\n",)),
            ("codex submits in a second write", ["/opt/homebrew/bin/codex"],
             ("/clear", SUBMIT)),
            ("shell", ["-zsh"], ()),
            ("nothing running", [], ()),
        ]
        for name, argv, want in cases:
            with self.subTest(name):
                self.assertEqual(INPUTS_FOR(argv), want)

    def test_is_primary(self):
        cases = [("main pane", "left", True), ("unset defaults to main", "", True),
                 ("split", "right", False)]
        for name, pane, want in cases:
            with self.subTest(name):
                self.assertEqual(IS_PRIMARY(pane), want)


class MainTests(unittest.TestCase):
    def run_main(self, pane, left, right, fired_pane_rc=0):
        """run_main drives main() against stubbed panes, returning the agtermctl argv it ran."""
        calls = []

        def fake_run(args, socket):
            calls.append(list(args))
            rc = fired_pane_rc if ("--pane" in args and args[args.index("--pane") + 1] == pane) else 0
            return subprocess.CompletedProcess(args, rc, b"", b"")

        env = {"AGT_SESSION_ID": "SID", "AGT_PANE": pane, "AGT_SOCKET": ""}
        replacements = {
            "os": type("os", (), {"environ": env})(),
            "run": fake_run,
            "foreground": lambda socket, sid, p: left if p == "left" else right,
        }
        with patch.dict(MAIN.__globals__, replacements):
            code = MAIN()
        return code, calls

    def panes_typed(self, calls):
        return [c[c.index("--pane") + 1] for c in calls if "--pane" in c]

    def test_cascades_from_the_main_pane_to_the_split(self):
        code, calls = self.run_main("left", ["/usr/local/bin/claude"], ["/opt/homebrew/bin/codex"])
        self.assertEqual(code, 0)
        self.assertEqual(self.panes_typed(calls), ["left", "right", "right"])
        self.assertEqual(calls[-1][:2], ["session", "context"])

    def typed_text(self, calls):
        return [c[2] for c in calls if c[:2] == ["session", "type"]]

    def test_resets_both_panes_when_both_run_codex(self):
        code, calls = self.run_main("left", ["/opt/homebrew/bin/codex"], ["/opt/homebrew/bin/codex"])
        self.assertEqual(code, 0)
        self.assertEqual(self.panes_typed(calls), ["left", "left", "right", "right"])
        self.assertEqual(self.typed_text(calls), ["/clear", SUBMIT, "/clear", SUBMIT])

    def test_resets_both_panes_when_both_run_claude(self):
        code, calls = self.run_main("left", ["/usr/local/bin/claude"], ["/usr/local/bin/claude"])
        self.assertEqual(code, 0)
        self.assertEqual(self.panes_typed(calls), ["left", "right"])
        self.assertEqual(self.typed_text(calls), ["/clear\n", "/clear\n"])

    def test_each_pane_gets_the_submit_its_own_agent_needs(self):
        code, calls = self.run_main("left", ["/opt/homebrew/bin/codex"], ["/usr/local/bin/claude"])
        self.assertEqual(code, 0)
        self.assertEqual(self.typed_text(calls), ["/clear", SUBMIT, "/clear\n"])

    def test_does_not_cascade_from_the_split(self):
        code, calls = self.run_main("right", ["/usr/local/bin/claude"], ["/usr/local/bin/claude"])
        self.assertEqual(code, 0)
        self.assertEqual(self.panes_typed(calls), ["right"])
        self.assertNotIn(["session", "context"], [c[:2] for c in calls])

    def test_keeps_the_context_and_fails_when_the_main_write_fails(self):
        code, calls = self.run_main("left", ["/usr/local/bin/claude"], ["/opt/homebrew/bin/codex"],
                                    fired_pane_rc=1)
        self.assertEqual(code, 1)
        self.assertIn("right", self.panes_typed(calls))
        self.assertNotIn(["session", "context"], [c[:2] for c in calls])

    def test_leaves_the_split_alone_when_the_main_pane_is_a_shell(self):
        code, calls = self.run_main("left", ["-zsh"], ["/opt/homebrew/bin/codex"])
        self.assertEqual(code, 0)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
