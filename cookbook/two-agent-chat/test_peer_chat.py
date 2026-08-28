#!/usr/bin/env python3
"""Regression checks for the two-agent chat composer parser."""

import runpy
import unittest
from pathlib import Path

SCRIPT = runpy.run_path(Path(__file__).with_name("peer-chat.py"))
CLAUDE_PROMPT_TEXT = SCRIPT["claude_prompt_text"]
RULE = "─" * 40


class ClaudePromptTextTests(unittest.TestCase):
    def test_plain_rule(self) -> None:
        screen = f"{RULE}\n❯ Chat from Codex: ping\n{RULE}"

        self.assertEqual(CLAUDE_PROMPT_TEXT(screen), "Chat from Codex: ping")

    def test_rule_with_context_label(self) -> None:
        screen = f"{RULE} e2e ─\n❯ Chat from Codex: ping\n{RULE}"

        self.assertEqual(CLAUDE_PROMPT_TEXT(screen), "Chat from Codex: ping")

    def test_rule_after_prompt_is_required(self) -> None:
        screen = f"{RULE} e2e ─\n❯ Chat from Codex: ping"

        self.assertIsNone(CLAUDE_PROMPT_TEXT(screen))


if __name__ == "__main__":
    unittest.main()
