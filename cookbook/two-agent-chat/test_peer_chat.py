#!/usr/bin/env python3
"""Regression checks for the two-agent chat composer parser."""

import runpy
import unittest
from pathlib import Path

SCRIPT = runpy.run_path(Path(__file__).with_name("peer-chat.py"))
CLAUDE_PROMPT_TEXT = SCRIPT["claude_prompt_text"]
COMPOSER_HAS_MESSAGE = SCRIPT["composer_has_message"]
CLAUDE_PROFILE = SCRIPT["PROFILES"]["claude"]
RULE = "─" * 40


class ClaudePromptTextTests(unittest.TestCase):
    def test_plain_rule(self) -> None:
        screen = f"{RULE}\n❯ Chat from Codex: ping\n{RULE}"

        self.assertEqual(CLAUDE_PROMPT_TEXT(screen), "Chat from Codex: ping")

    def test_rule_with_context_label(self) -> None:
        screen = f"{RULE} e2e ─\n❯ Chat from Codex: ping\n{RULE}"

        self.assertEqual(CLAUDE_PROMPT_TEXT(screen), "Chat from Codex: ping")

    def test_wrapped_box_needs_no_rule_above(self) -> None:
        screen = (
            "older output\n"
            "❯ Chat from Codex: a wrapped message\n"
            "  with a continuation\n"
            f"{RULE}"
        )

        self.assertEqual(
            CLAUDE_PROMPT_TEXT(screen),
            "Chat from Codex: a wrapped message with a continuation",
        )

    def test_latest_prompt_wins_over_an_older_ruled_prompt(self) -> None:
        screen = (
            f"{RULE}\n"
            "❯ Chat from Codex: old\n"
            f"{RULE}\n"
            "older response\n"
            "❯ Chat from Codex: current\n"
            "  continuation\n"
            f"{RULE}"
        )

        self.assertEqual(
            CLAUDE_PROMPT_TEXT(screen),
            "Chat from Codex: current continuation",
        )

    def test_labelled_rule_terminates_a_wrapped_box(self) -> None:
        screen = (
            "older output\n"
            "❯ Chat from Codex: wrapped\n"
            "  tail\n"
            f"{RULE} e2e ─\n"
            "  UMBP: agterm [master]"
        )

        self.assertEqual(CLAUDE_PROMPT_TEXT(screen), "Chat from Codex: wrapped tail")

    def test_rule_after_prompt_is_not_required(self) -> None:
        screen = f"{RULE} e2e ─\n❯ Chat from Codex: ping"

        self.assertEqual(CLAUDE_PROMPT_TEXT(screen), "Chat from Codex: ping")


class ComposerHasMessageTests(unittest.TestCase):
    def test_label_leading_summary_keeps_opening_body_fragment(self) -> None:
        typed = "Chat from Codex: opening transport fragment and more text"
        shown = "Chat from Codex: opening transport fragment [Pasted text #16]"

        self.assertTrue(COMPOSER_HAS_MESSAGE(CLAUDE_PROFILE, shown, typed))

    def test_label_leading_row_without_opening_body_fragment_is_refused(self) -> None:
        typed = "Chat from Codex: opening transport fragment and more text"
        shown = "Chat from Codex: unrelated composer content"

        self.assertFalse(COMPOSER_HAS_MESSAGE(CLAUDE_PROFILE, shown, typed))

    def test_summary_leading_row_keeps_later_body_fragment(self) -> None:
        typed = (
            "Chat from Codex: opening transport fragment followed by a later "
            "acceptance fragment in the body"
        )
        shown = "[Pasted text #7 +12 lines] later acceptance fragment"

        self.assertTrue(COMPOSER_HAS_MESSAGE(CLAUDE_PROFILE, shown, typed))

    def test_singular_line_count_summary_is_accepted(self) -> None:
        typed = "Chat from Codex: opening transport fragment and later acceptance text"
        shown = "[Pasted text #7 +1 line] later acceptance text"

        self.assertTrue(COMPOSER_HAS_MESSAGE(CLAUDE_PROFILE, shown, typed))

    def test_summary_only_row_is_refused(self) -> None:
        typed = "Chat from Codex: opening transport fragment and more text"

        for shown in ("[Pasted text #7]", "[Pasted text #7 +12 lines]"):
            with self.subTest(shown=shown):
                self.assertFalse(
                    COMPOSER_HAS_MESSAGE(CLAUDE_PROFILE, shown, typed)
                )


if __name__ == "__main__":
    unittest.main()
