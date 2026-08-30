#!/usr/bin/env python3
"""Regression checks for the two-agent chat composer parser."""

import argparse
import io
import os
import runpy
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import Mock, patch

SCRIPT = runpy.run_path(Path(__file__).with_name("peer-chat.py"))
CLAUDE_PROMPT_TEXT = SCRIPT["claude_prompt_text"]
CODEX_PROMPT_TEXT = SCRIPT["codex_prompt_text"]
COMPOSER_HAS_MESSAGE = SCRIPT["composer_has_message"]
LIVE_PROMPT_TEXT = SCRIPT["live_prompt_text"]
MAIN = SCRIPT["main"]
MAX_MESSAGE_BYTES = SCRIPT["MAX_MESSAGE_BYTES"]
MESSAGE_NAME = SCRIPT["message_name"]
PASTED_RE = SCRIPT["PASTED_RE"]
PROFILES = SCRIPT["PROFILES"]
PROMPT_BLOCKED = SCRIPT["PromptBlocked"]
SEND = SCRIPT["send"]
CLAUDE_PROFILE = PROFILES["claude"]
PARSE_ARGS = SCRIPT["parse_args"]
PREPARE_MESSAGE = SCRIPT["prepare_message"]
READ_MESSAGE = SCRIPT["read_message"]
RULE = "─" * 40
CODEX_FOOTER = "  repo · master · gpt-5.6 high · Context 0% used"


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

    def test_wrapped_box_needs_no_closing_rule(self) -> None:
        screen = (
            "older output\n"
            "❯ Chat from Codex: a wrapped message\n"
            "  with a continuation"
        )

        self.assertEqual(
            CLAUDE_PROMPT_TEXT(screen),
            "Chat from Codex: a wrapped message with a continuation",
        )

    def test_live_wrapped_box_without_closing_rule_is_refused(self) -> None:
        screen = (
            "older output\n"
            "❯ Chat from Codex: a wrapped message\n"
            "  with a continuation"
        )

        self.assertIsNone(LIVE_PROMPT_TEXT(CLAUDE_PROFILE, screen))

    def test_live_stale_prompt_under_a_dialog_is_refused(self) -> None:
        screen = "❯ previous user prompt\nAllow this command?\n  1. Yes\n  2. No"

        self.assertIsNone(LIVE_PROMPT_TEXT(CLAUDE_PROFILE, screen))


class CodexPromptTextTests(unittest.TestCase):
    def test_default_glyph(self) -> None:
        screen = f"› Chat from Claude: ping\n{CODEX_FOOTER}"

        self.assertEqual(CODEX_PROMPT_TEXT(screen), "Chat from Claude: ping")

    def test_ultra_effort_glyph(self) -> None:
        screen = f"» [Pasted Content 1868 chars]\n{CODEX_FOOTER}"

        self.assertEqual(CODEX_PROMPT_TEXT(screen), "[Pasted Content 1868 chars]")

    def test_empty_composer_placeholder(self) -> None:
        screen = f"» Ask Codex to do anything\n{CODEX_FOOTER}"

        self.assertEqual(CODEX_PROMPT_TEXT(screen), "Ask Codex to do anything")

    def test_shell_mode_is_not_a_prompt(self) -> None:
        screen = f"! ls -la\n{CODEX_FOOTER}"

        self.assertIsNone(CODEX_PROMPT_TEXT(screen))

    def test_live_shell_blocks_an_older_composer(self) -> None:
        screen = (
            "› earlier prompt\n"
            "  some response output\n"
            "! ls -la\n"
            "  shell mode active"
        )

        self.assertIsNone(CODEX_PROMPT_TEXT(screen))

    def test_prompt_shaped_shell_output_is_not_a_composer(self) -> None:
        screen = f"! printf output\n  › fake output\n{CODEX_FOOTER}"

        self.assertIsNone(CODEX_PROMPT_TEXT(screen))
        self.assertIsNone(LIVE_PROMPT_TEXT(PROFILES["codex"], screen))

    def test_live_prompt_is_adjacent_to_the_footer(self) -> None:
        screen = f"» Ask Codex to do anything\n\n{CODEX_FOOTER}"

        self.assertEqual(
            LIVE_PROMPT_TEXT(PROFILES["codex"], screen),
            "Ask Codex to do anything",
        )

    def test_live_prompt_accepts_configurable_footers(self) -> None:
        footers = (
            "  repo · master · gpt-5.6 high",
            "  Context 100% left · repo · master",
            "  Context 0% used · repo · master",
            "  Context 100% left",
            "  gpt-5.6 high",
        )

        for footer in footers:
            with self.subTest(footer=footer):
                screen = f"» Ask Codex to do anything\n{footer}"
                self.assertEqual(
                    LIVE_PROMPT_TEXT(PROFILES["codex"], screen),
                    "Ask Codex to do anything",
                )

    def test_transcript_history_above_live_prompt_is_ignored(self) -> None:
        screen = (
            "› earlier prompt\n"
            "response output\n"
            "! old shell transcript\n"
            "old shell output\n"
            "\n"
            "» Ask Codex to do anything\n"
            "\n"
            f"{CODEX_FOOTER}"
        )

        self.assertEqual(
            LIVE_PROMPT_TEXT(PROFILES["codex"], screen),
            "Ask Codex to do anything",
        )

    def test_unrecognised_trailing_row_is_not_live(self) -> None:
        screen = "» Ask Codex to do anything\nkey hint whose layout is unknown"

        self.assertIsNone(LIVE_PROMPT_TEXT(PROFILES["codex"], screen))

    def test_dialog_without_a_footer_is_not_live(self) -> None:
        screen = (
            "› previous user prompt\n"
            "Approval required\n"
            "  1. Allow\n"
            "  2. Deny"
        )

        self.assertIsNone(LIVE_PROMPT_TEXT(PROFILES["codex"], screen))

    def test_stale_prompt_under_a_dialog_is_not_live(self) -> None:
        screen = (
            "› previous user prompt\n"
            "Approval required\n"
            "  1. Allow\n"
            "  2. Deny\n"
            f"{CODEX_FOOTER}"
        )

        self.assertIsNone(LIVE_PROMPT_TEXT(PROFILES["codex"], screen))


class ComposerHasMessageTests(unittest.TestCase):
    def test_label_leading_summary_keeps_opening_body_fragment(self) -> None:
        typed = "Chat from Codex: opening transport fragment and more text"
        shown = "Chat from Codex: opening transport fragment [Pasted text #16]"

        self.assertTrue(COMPOSER_HAS_MESSAGE(CLAUDE_PROFILE, shown, typed))

    def test_label_leading_row_without_opening_body_fragment_is_refused(self) -> None:
        typed = "Chat from Codex: opening transport fragment and more text"
        shown = "Chat from Codex: unrelated composer content"

        self.assertFalse(COMPOSER_HAS_MESSAGE(CLAUDE_PROFILE, shown, typed))

    def test_label_leading_bare_paste_marker_is_refused(self) -> None:
        typed = "Chat from Codex: opening transport fragment and more text"
        shown = "Chat from Codex: [Pasted text #16]"

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

    def test_codex_accepts_paste_marker(self) -> None:
        typed = "Chat from Claude: " + "x" * 2000

        self.assertTrue(
            COMPOSER_HAS_MESSAGE(
                PROFILES["codex"], "[Pasted Content 2018 chars]", typed
            )
        )

    def test_codex_requires_literal_prefix(self) -> None:
        typed = "Chat from Claude: ping pong " + "x" * 40

        self.assertTrue(COMPOSER_HAS_MESSAGE(PROFILES["codex"], typed[:45], typed))
        self.assertFalse(COMPOSER_HAS_MESSAGE(PROFILES["codex"], "Chat from", typed))
        self.assertFalse(
            COMPOSER_HAS_MESSAGE(PROFILES["codex"], "something else", typed)
        )


class PastedMarkerTests(unittest.TestCase):
    def test_codex_marker(self) -> None:
        self.assertTrue(PASTED_RE.fullmatch("[Pasted Content 1 char]"))
        self.assertTrue(PASTED_RE.fullmatch("[Pasted Content 1868 chars]"))

    def test_claude_marker_is_checked_separately(self) -> None:
        self.assertIsNone(PASTED_RE.fullmatch("[Pasted text #1 +12 lines]"))

    def test_other_brackets_are_not_markers(self) -> None:
        self.assertIsNone(PASTED_RE.fullmatch("[Image #1]"))


class SendPreflightTests(unittest.TestCase):
    def test_prompt_is_checked_before_cursor(self) -> None:
        pane_text = Mock(return_value=f"! ls -la\n{CODEX_FOOTER}")
        cursor_column = Mock(return_value=2)
        replacements = {
            "pane_text": pane_text,
            "cursor_column": cursor_column,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaises(
            PROMPT_BLOCKED
        ):
            SEND("session-id", PROFILES["codex"], "ping")

        pane_text.assert_called_once()
        cursor_column.assert_not_called()


class MessageInputTests(unittest.TestCase):
    def test_private_message_is_consumed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            spool = Path(directory) / "spool"
            name = "peer-chat-codex-a91f.txt"
            replacements = {"MESSAGE_SPOOL": spool}
            with patch.dict(PREPARE_MESSAGE.__globals__, replacements):
                path = PREPARE_MESSAGE(name)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                path.write_text("a message\nwith two lines\n", encoding="utf-8")

                args = PARSE_ARGS(["--to", "claude", "--message-file", name])

                self.assertFalse(args.stdin)
                self.assertEqual(
                    READ_MESSAGE(args.stdin, args.message_file),
                    "a message\nwith two lines\n",
                )
                self.assertFalse(path.exists())
                self.assertEqual(spool.stat().st_mode & 0o777, 0o700)

    def test_world_readable_message_is_rejected_and_consumed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            spool = Path(directory) / "spool"
            name = "peer-chat-codex-b82d.txt"
            with patch.dict(PREPARE_MESSAGE.__globals__, {"MESSAGE_SPOOL": spool}):
                path = PREPARE_MESSAGE(name)
                path.write_text("private text", encoding="utf-8")
                path.chmod(0o644)

                with self.assertRaisesRegex(ValueError, "--prepare-message again"):
                    READ_MESSAGE(False, name)

                self.assertFalse(path.exists())

    def test_oversized_message_is_rejected_and_consumed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            spool = Path(directory) / "spool"
            name = "peer-chat-codex-c73e.txt"
            with patch.dict(PREPARE_MESSAGE.__globals__, {"MESSAGE_SPOOL": spool}):
                path = PREPARE_MESSAGE(name)
                path.write_text("x" * (MAX_MESSAGE_BYTES + 1), encoding="utf-8")

                with self.assertRaisesRegex(ValueError, "--prepare-message again"):
                    READ_MESSAGE(False, name)

                self.assertFalse(path.exists())

    def test_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spool = root / "spool"
            name = "peer-chat-codex-d64f.txt"
            with patch.dict(PREPARE_MESSAGE.__globals__, {"MESSAGE_SPOOL": spool}):
                path = PREPARE_MESSAGE(name)
                path.unlink()
                secret = root / "secret.txt"
                secret.write_text("secret", encoding="utf-8")
                path.symlink_to(secret)

                with self.assertRaises(OSError):
                    READ_MESSAGE(False, name)

                self.assertEqual(secret.read_text(encoding="utf-8"), "secret")

    def test_non_regular_message_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            spool = Path(directory) / "spool"
            name = "peer-chat-codex-e55a.txt"
            with patch.dict(PREPARE_MESSAGE.__globals__, {"MESSAGE_SPOOL": spool}):
                spool.mkdir(mode=0o700)
                path = spool / name
                os.mkfifo(path, mode=0o600)

                with self.assertRaisesRegex(ValueError, "regular file"):
                    READ_MESSAGE(False, name)

                self.assertTrue(path.exists())

    def test_multiply_linked_message_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            spool = Path(directory) / "spool"
            name = "peer-chat-codex-f46b.txt"
            with patch.dict(PREPARE_MESSAGE.__globals__, {"MESSAGE_SPOOL": spool}):
                path = PREPARE_MESSAGE(name)
                path.write_text("private text", encoding="utf-8")
                second_link = spool / "second-link"
                second_link.hardlink_to(path)

                with self.assertRaisesRegex(ValueError, "one link"):
                    READ_MESSAGE(False, name)

                self.assertTrue(path.exists())
                self.assertTrue(second_link.exists())

    def test_message_name_rejects_paths(self) -> None:
        with self.assertRaisesRegex(argparse.ArgumentTypeError, "message name"):
            MESSAGE_NAME("../secret.txt")

    def test_public_spool_error_names_the_mode_repair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            spool = Path(directory) / "spool"
            spool.mkdir()
            spool.chmod(0o755)
            name = "peer-chat-codex-h28d.txt"
            replacements = {"MESSAGE_SPOOL": spool}

            with (
                patch.dict(PREPARE_MESSAGE.__globals__, replacements),
                self.assertRaisesRegex(ValueError, r"chmod 700 .*/spool"),
            ):
                PREPARE_MESSAGE(name)

    def test_prepare_mode_needs_no_target(self) -> None:
        args = PARSE_ARGS(["--prepare-message", "peer-chat-codex-g37c.txt"])

        self.assertEqual(args.prepare_message, "peer-chat-codex-g37c.txt")
        self.assertIsNone(args.to)

    def test_stdin_mode_remains_available(self) -> None:
        args = PARSE_ARGS(["--to", "codex", "--stdin"])

        self.assertTrue(args.stdin)
        self.assertIsNone(args.message_file)

    def test_target_refusal_preserves_prepared_message(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            spool = Path(directory) / "spool"
            name = "peer-chat-codex-j04f.txt"
            replacements = {"MESSAGE_SPOOL": spool}
            with patch.dict(PREPARE_MESSAGE.__globals__, replacements):
                path = PREPARE_MESSAGE(name)
                path.write_text("message to retry", encoding="utf-8")
                args = argparse.Namespace(
                    prepare_message=None,
                    stdin=False,
                    message_file=name,
                    to="claude",
                    session=None,
                    target_command=None,
                )
                main_replacements = {
                    "parse_args": Mock(return_value=args),
                    "resolve_session": Mock(side_effect=RuntimeError("no target")),
                }

                with (
                    patch.dict(MAIN.__globals__, main_replacements),
                    redirect_stderr(io.StringIO()),
                ):
                    self.assertEqual(MAIN(), 1)

                self.assertEqual(path.read_text(encoding="utf-8"), "message to retry")


if __name__ == "__main__":
    unittest.main()
