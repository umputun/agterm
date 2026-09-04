#!/usr/bin/env python3
"""Regression checks for the two-agent chat transport."""

import argparse
import inspect
import io
import json
import os
import runpy
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import ANY, Mock, call, patch

SCRIPT = runpy.run_path(Path(__file__).with_name("peer-chat.py"))
CHUNK_SETTLE_DELAY = SCRIPT["CHUNK_SETTLE_DELAY"]
CHUNK_VERIFY_OVERLAP = SCRIPT["CHUNK_VERIFY_OVERLAP"]
CLEAR_COMPOSER = SCRIPT["clear_composer"]
COMPOSER_DIRTY = SCRIPT["ComposerDirty"]
COMPOSER_HAS_EXPECTED_TAIL = SCRIPT["composer_has_expected_tail"]
COMPOSER_IS_EMPTY = SCRIPT["composer_is_empty"]
COMPOSER_PROBE_MARKER = SCRIPT["composer_probe_marker"]
COMPOSER_STATE = SCRIPT["composer_state"]
CURSOR_COLUMN = SCRIPT["cursor_column"]
DELIVERY_PROGRESS = SCRIPT["DeliveryProgress"]
LIVE_PROMPT_TEXT = SCRIPT["live_prompt_text"]
MAIN = SCRIPT["main"]
MAX_MESSAGE_BYTES = SCRIPT["MAX_MESSAGE_BYTES"]
MESSAGE_NAME = SCRIPT["message_name"]
PROFILES = SCRIPT["PROFILES"]
PROMPT_BLOCKED = SCRIPT["PromptBlocked"]
SEND = SCRIPT["send"]
SEND_WITH_RETRY = SCRIPT["send_with_retry"]
COMPOSER_SETTLE_DELAY = SCRIPT["COMPOSER_SETTLE_DELAY"]
TEXT_CHUNKS = SCRIPT["text_chunks"]
TYPE_BODY = SCRIPT["type_body"]
TYPE_CHUNK_BYTES = SCRIPT["TYPE_CHUNK_BYTES"]
WAIT_FOR_ACCEPTED = SCRIPT["wait_for_accepted"]
WAIT_FOR_COMPOSER_CHANGE = SCRIPT["wait_for_composer_change"]
CLAUDE_PROFILE = PROFILES["claude"]
PARSE_ARGS = SCRIPT["parse_args"]
PREPARE_MESSAGE = SCRIPT["prepare_message"]
READ_MESSAGE = SCRIPT["read_message"]
RESOLVE_WINDOW = SCRIPT["resolve_window"]
RESOLVE_TARGET = SCRIPT["resolve_target"]
RUN_MAIN = SCRIPT["run_main"]
TARGET_PROFILE = SCRIPT["target_profile"]
PANE_TEXT = SCRIPT["pane_text"]
TREE = SCRIPT["tree"]
TYPE_TEXT = SCRIPT["type_text"]
RULE = "─" * 40
CODEX_FOOTER = "  repo · master · gpt-5.6 high · Context 0% used"


def stepping_time(step: float = 0.11) -> Mock:
    current = [-step]

    def monotonic() -> float:
        current[0] += step
        return current[0]

    return Mock(monotonic=Mock(side_effect=monotonic), sleep=Mock())


class ClaudeLivePromptTextTests(unittest.TestCase):
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

    def test_closed_historical_prompt_above_a_dialog_is_refused(self) -> None:
        screen = (
            f"{RULE}\n"
            "❯ previous user prompt\n"
            "assistant response\n"
            f"{RULE}\n"
            "Allow this command?\n"
            "  1. Yes\n"
            "  2. No"
        )

        self.assertIsNone(LIVE_PROMPT_TEXT(CLAUDE_PROFILE, screen))

    def test_live_composer_accepts_indented_status_rows(self) -> None:
        screen = (
            f"{RULE}\n"
            "❯ Chat from Codex: review this\n"
            f"{RULE}\n"
            "  repo [branch] [Opus 5] 70% /rc\n"
            "  ⏵⏵ bypass permissions on (shift+tab to cycle)"
        )

        self.assertEqual(
            LIVE_PROMPT_TEXT(CLAUDE_PROFILE, screen),
            "Chat from Codex: review this",
        )

    def test_queue_hints_are_known_empty_claude_placeholders(self) -> None:
        hints = [
            "Press up to edit queued messages",
            "Press up to edit queued messages, Enter to send them immediately",
        ]

        for hint in hints:
            with self.subTest(hint=hint):
                screen = f"{RULE}\n❯ {hint}\n{RULE}"
                content = LIVE_PROMPT_TEXT(CLAUDE_PROFILE, screen)
                self.assertEqual(content, hint)
                self.assertTrue(COMPOSER_IS_EMPTY(CLAUDE_PROFILE, content))

    def test_startup_hints_are_known_empty_claude_placeholders(self) -> None:
        hints = [
            'Try "fix lint errors"',
            'Try "create a util logging.py that..."',
            'Try "edit cookbook/two-agent-chat/peer-chat.py to..."',
            # git quotes and escapes a path holding a double quote, so the suggestion
            # carries its own; pins `.+` over `[^"]*`
            'Try "refactor "odd\\"name.py""',
        ]

        for hint in hints:
            with self.subTest(hint=hint):
                screen = f"{RULE}\n❯ {hint}\n{RULE}"
                content = LIVE_PROMPT_TEXT(CLAUDE_PROFILE, screen)
                self.assertEqual(content, hint)
                self.assertTrue(COMPOSER_IS_EMPTY(CLAUDE_PROFILE, content))

    def test_wrapped_startup_hint_is_a_known_empty_claude_placeholder(self) -> None:
        screen = (
            f"{RULE}\n"
            '❯ Try "write a test for cookbook/two-agent-chat/\n'
            '  peer-chat.py"\n'
            f"{RULE}"
        )

        content = LIVE_PROMPT_TEXT(CLAUDE_PROFILE, screen)

        self.assertTrue(COMPOSER_IS_EMPTY(CLAUDE_PROFILE, content))

    def test_startup_hint_pattern_does_not_accept_other_claude_text(self) -> None:
        drafts = [
            'Try to fix the lint errors',
            'please Try "fix lint errors"',
            'Try ""',
        ]

        for draft in drafts:
            with self.subTest(draft=draft):
                screen = f"{RULE}\n❯ {draft}\n{RULE}"
                content = LIVE_PROMPT_TEXT(CLAUDE_PROFILE, screen)
                self.assertFalse(COMPOSER_IS_EMPTY(CLAUDE_PROFILE, content))

    def test_wrapped_queue_hint_is_a_known_empty_claude_placeholder(self) -> None:
        screen = (
            f"{RULE}\n"
            "❯ Press up to edit queued messages, Enter to\n"
            "  send them immediately\n"
            f"{RULE}"
        )

        content = LIVE_PROMPT_TEXT(CLAUDE_PROFILE, screen)

        self.assertEqual(
            content,
            "Press up to edit queued messages, Enter to\nsend them immediately",
        )
        self.assertTrue(COMPOSER_IS_EMPTY(CLAUDE_PROFILE, content))


class CodexLivePromptTextTests(unittest.TestCase):
    def test_numbered_approval_selection_is_not_a_composer(self) -> None:
        screen = (
            "Would you like to run the following command?\n\n"
            "› 1. Yes, proceed (y)\n"
            "  2. Yes, and don't ask again\n"
            "  3. No, and tell Codex what to do differently\n"
        )

        self.assertIsNone(LIVE_PROMPT_TEXT(PROFILES["codex"], screen))

    def test_default_glyph(self) -> None:
        screen = f"› Chat from Claude: ping\n{CODEX_FOOTER}"

        self.assertEqual(
            LIVE_PROMPT_TEXT(PROFILES["codex"], screen), "Chat from Claude: ping"
        )

    def test_wrapped_composer_ignores_the_changing_footer(self) -> None:
        screen = (
            "» Chat from Claude: a long reply whose first row wraps\n"
            "  onto a second row and remains in the composer\n"
            f"{CODEX_FOOTER}"
        )

        self.assertEqual(
            LIVE_PROMPT_TEXT(PROFILES["codex"], screen),
            "Chat from Claude: a long reply whose first row wraps\nonto a second "
            "row and remains in the composer",
        )

    def test_ultra_effort_glyph(self) -> None:
        screen = f"» [Pasted Content 1868 chars]\n{CODEX_FOOTER}"

        self.assertEqual(
            LIVE_PROMPT_TEXT(PROFILES["codex"], screen),
            "[Pasted Content 1868 chars]",
        )

    def test_empty_composer_placeholder(self) -> None:
        screen = f"» Ask Codex to do anything\n{CODEX_FOOTER}"

        self.assertEqual(
            LIVE_PROMPT_TEXT(PROFILES["codex"], screen), "Ask Codex to do anything"
        )

    def test_wrapped_empty_composer_placeholder_is_known_empty(self) -> None:
        screen = f"» Ask Codex to do\n  anything\n{CODEX_FOOTER}"
        content = LIVE_PROMPT_TEXT(PROFILES["codex"], screen)

        self.assertEqual(content, "Ask Codex to do\nanything")
        self.assertTrue(COMPOSER_IS_EMPTY(PROFILES["codex"], content))

    def test_shell_mode_is_not_a_prompt(self) -> None:
        screen = f"! ls -la\n{CODEX_FOOTER}"

        self.assertIsNone(LIVE_PROMPT_TEXT(PROFILES["codex"], screen))

    def test_live_shell_blocks_an_older_composer(self) -> None:
        screen = (
            "› earlier prompt\n"
            "  some response output\n"
            "! ls -la\n"
            "  shell mode active"
        )

        self.assertIsNone(LIVE_PROMPT_TEXT(PROFILES["codex"], screen))

    def test_prompt_shaped_shell_output_is_not_a_composer(self) -> None:
        screen = f"! printf output\n  › fake output\n{CODEX_FOOTER}"

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


class SendPreflightTests(unittest.TestCase):
    def test_prompt_is_checked_before_cursor(self) -> None:
        pane_text = Mock(return_value=f"! ls -la\n{CODEX_FOOTER}")
        cursor_column = Mock(return_value=2)
        type_text = Mock()
        replacements = {
            "pane_text": pane_text,
            "cursor_column": cursor_column,
            "type_text": type_text,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaises(
            PROMPT_BLOCKED
        ):
            SEND("session-id", PROFILES["codex"], "ping")

        pane_text.assert_called_once()
        cursor_column.assert_not_called()
        type_text.assert_not_called()

    def test_cursor_refusal_writes_nothing(self) -> None:
        type_text = Mock()
        replacements = {
            "pane_text": Mock(
                return_value=f"» Ask Codex to do anything\n{CODEX_FOOTER}"
            ),
            "cursor_column": Mock(return_value=3),
            "type_text": type_text,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaises(
            PROMPT_BLOCKED
        ):
            SEND("session-id", PROFILES["codex"], "ping")

        type_text.assert_not_called()

    def test_full_width_codex_draft_at_column_two_is_refused(self) -> None:
        type_body = Mock()
        draft = "x" * 83
        replacements = {
            "pane_text": Mock(return_value=f"» {draft}\n{CODEX_FOOTER}"),
            "cursor_column": Mock(return_value=2),
            "type_body": type_body,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            PROMPT_BLOCKED, "composer contains text; nothing was typed"
        ):
            SEND("session-id", PROFILES["codex"], "ping")

        type_body.assert_not_called()

    def test_claude_draft_at_column_two_is_refused(self) -> None:
        type_body = Mock()
        replacements = {
            "pane_text": Mock(
                return_value=f"{RULE}\n❯ existing draft\n{RULE}"
            ),
            "cursor_column": Mock(return_value=2),
            "type_body": type_body,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            PROMPT_BLOCKED, "composer contains text; nothing was typed"
        ):
            SEND("session-id", CLAUDE_PROFILE, "ping")

        type_body.assert_not_called()

    def test_preflight_transport_failure_says_nothing_was_typed(self) -> None:
        type_body = Mock()
        replacements = {
            "pane_text": Mock(side_effect=ValueError("malformed JSON")),
            "type_body": type_body,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            RuntimeError, "pre-write check failed; nothing was typed: malformed JSON"
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

        type_body.assert_not_called()

    def test_long_message_then_return_are_separate_writes(self) -> None:
        pane_text = Mock(return_value=f"{RULE}\n❯ \n{RULE}")
        message = "opening " + "body " * 4_000 + "closing"
        expected = "Chat from Codex: " + " ".join(message.split())
        type_body = Mock(return_value=(expected, 12))
        type_text = Mock()
        calls = Mock()
        calls.attach_mock(type_body, "type_body")
        calls.attach_mock(type_text, "type_text")
        replacements = {
            "pane_text": pane_text,
            "cursor_column": Mock(return_value=2),
            "type_body": type_body,
            "composer_state": Mock(return_value=(expected, 12)),
            "type_text": type_text,
            "wait_for_accepted": Mock(return_value=True),
        }

        with patch.dict(SEND.__globals__, replacements):
            self.assertEqual(SEND("session-id", CLAUDE_PROFILE, message), len(message))

        self.assertEqual(
            calls.mock_calls,
            [
                call.type_body(
                    "session-id", CLAUDE_PROFILE, expected, ("", 2), None, ANY
                ),
                call.type_text("session-id", CLAUDE_PROFILE, "\n", None),
            ],
        )

    def test_codex_default_and_queued_submit_keys(self) -> None:
        pane_text = Mock(return_value=f"» Ask Codex to do anything\n{CODEX_FOOTER}")
        type_body = Mock(
            side_effect=[
                ("Chat from Claude: steer", 25),
                ("Chat from Claude: queued", 26),
            ]
        )
        type_text = Mock()
        replacements = {
            "pane_text": pane_text,
            "cursor_column": Mock(return_value=2),
            "type_body": type_body,
            "composer_state": Mock(
                side_effect=[
                    ("Chat from Claude: steer", 25),
                    ("Chat from Claude: queued", 26),
                ]
            ),
            "type_text": type_text,
            "wait_for_accepted": Mock(return_value=True),
        }

        with patch.dict(SEND.__globals__, replacements):
            SEND("session-id", TARGET_PROFILE("codex", None), "steer")
            SEND("session-id", TARGET_PROFILE("codex", None, queue=True), "queued")

        self.assertEqual(type_body.call_args_list[0].args[2], "Chat from Claude: steer")
        self.assertEqual(type_text.call_args_list[0].args[2], "\n")
        self.assertEqual(type_body.call_args_list[1].args[2], "Chat from Claude: queued")
        self.assertEqual(type_text.call_args_list[1].args[2], "\t")

    def test_interrupt_during_submit_reports_ambiguous_delivery(self) -> None:
        type_text = Mock(side_effect=KeyboardInterrupt())
        wait_for_accepted = Mock()
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(return_value=("Chat from Codex: body", 23)),
            "composer_state": Mock(return_value=("Chat from Codex: body", 23)),
            "type_text": type_text,
            "wait_for_accepted": wait_for_accepted,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            KeyboardInterrupt, "submit request.*delivery is ambiguous.*do not resend"
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

        wait_for_accepted.assert_not_called()

    def test_submit_value_error_reports_ambiguous_delivery(self) -> None:
        wait_for_accepted = Mock()
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(return_value=("Chat from Codex: body", 23)),
            "composer_state": Mock(return_value=("Chat from Codex: body", 23)),
            "type_text": Mock(side_effect=ValueError("malformed JSON")),
            "wait_for_accepted": wait_for_accepted,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            RuntimeError,
            "submit request failed.*delivery is ambiguous.*do not resend.*malformed JSON",
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

        wait_for_accepted.assert_not_called()

    def test_interrupt_during_acceptance_reports_ambiguous_delivery(self) -> None:
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(return_value=("Chat from Codex: body", 23)),
            "composer_state": Mock(return_value=("Chat from Codex: body", 23)),
            "type_text": Mock(),
            "wait_for_accepted": Mock(side_effect=KeyboardInterrupt()),
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            KeyboardInterrupt,
            "submission confirmation.*delivery is ambiguous.*do not resend",
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

    def test_acceptance_probe_failure_reports_ambiguous_delivery(self) -> None:
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(return_value=("Chat from Codex: body", 23)),
            "composer_state": Mock(return_value=("Chat from Codex: body", 23)),
            "type_text": Mock(),
            "wait_for_accepted": Mock(side_effect=ValueError("malformed JSON")),
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            RuntimeError,
            "submission confirmation failed.*delivery is ambiguous.*do not resend.*malformed JSON",
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

    def test_unconfirmed_chunk_withholds_submit(self) -> None:
        type_body = Mock(
            side_effect=COMPOSER_DIRTY(
                "chunk unconfirmed; submit withheld", "Chat from Codex: body"
            )
        )
        type_text = Mock()
        clear_composer = Mock(return_value=True)
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": type_body,
            "type_text": type_text,
            "clear_composer": clear_composer,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            COMPOSER_DIRTY, "submit withheld; composer cleared"
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

        type_body.assert_called_once_with(
            "session-id",
            CLAUDE_PROFILE,
            "Chat from Codex: body",
            ("", 2),
            None,
            ANY,
        )
        clear_composer.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, ("", 2), "Chat from Codex: body", None
        )
        type_text.assert_not_called()

    def test_transport_failure_after_a_confirmed_chunk_cleans_composer(self) -> None:
        message = "a" * (TYPE_CHUNK_BYTES * 2)
        typed = "Chat from Codex: " + message
        marker = COMPOSER_PROBE_MARKER(typed)
        chunks = TEXT_CHUNKS(
            typed, TYPE_CHUNK_BYTES - len(marker.encode("utf-8"))
        )
        first_chunk, second_chunk = chunks[:2]
        marked_state = (first_chunk + marker, 24)
        unmarked_state = (first_chunk, 24)
        type_text = Mock(
            side_effect=[None, None, ValueError("transport failed")]
        )
        clear_composer = Mock(return_value=True)
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_text": type_text,
            "wait_for_composer_change": Mock(
                side_effect=[marked_state, unmarked_state]
            ),
            "clear_composer": clear_composer,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            COMPOSER_DIRTY, "transport failed.*composer cleared"
        ):
            SEND("session-id", CLAUDE_PROFILE, message)

        self.assertEqual(type_text.call_count, 3)
        clear_composer.assert_called_once_with(
            "session-id",
            CLAUDE_PROFILE,
            ("", 2),
            first_chunk + second_chunk + marker,
            None,
        )

    def test_interrupt_after_a_confirmed_chunk_cleans_composer(self) -> None:
        message = "a" * (TYPE_CHUNK_BYTES * 2)
        typed = "Chat from Codex: " + message
        marker = COMPOSER_PROBE_MARKER(typed)
        chunks = TEXT_CHUNKS(
            typed, TYPE_CHUNK_BYTES - len(marker.encode("utf-8"))
        )
        first_chunk, second_chunk = chunks[:2]
        marked_state = (first_chunk + marker, 24)
        unmarked_state = (first_chunk, 24)
        type_text = Mock(side_effect=[None, None, KeyboardInterrupt()])
        clear_composer = Mock(return_value=True)
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_text": type_text,
            "wait_for_composer_change": Mock(
                side_effect=[marked_state, unmarked_state]
            ),
            "clear_composer": clear_composer,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            KeyboardInterrupt, "submit withheld; composer cleared"
        ):
            SEND("session-id", CLAUDE_PROFILE, message)

        self.assertEqual(type_text.call_count, 3)
        clear_composer.assert_called_once_with(
            "session-id",
            CLAUDE_PROFILE,
            ("", 2),
            first_chunk + second_chunk + marker,
            None,
        )

    def test_interrupt_during_marked_tail_check_cleans_marker(self) -> None:
        typed = "Chat from Codex: body"
        marker = COMPOSER_PROBE_MARKER(typed)
        marked = typed + marker
        type_text = Mock()
        clear_composer = Mock(return_value=True)
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_text": type_text,
            "wait_for_composer_change": Mock(return_value=(marked, 24)),
            "composer_has_expected_tail": Mock(side_effect=KeyboardInterrupt()),
            "clear_composer": clear_composer,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            KeyboardInterrupt, "submit withheld; composer cleared"
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

        clear_composer.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, ("", 2), marked, None
        )
        type_text.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, marked, None
        )

    def test_interrupt_during_unmarked_tail_check_cleans_body(self) -> None:
        typed = "Chat from Codex: body"
        marker = COMPOSER_PROBE_MARKER(typed)
        marked = typed + marker
        type_text = Mock()
        clear_composer = Mock(return_value=True)
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_text": type_text,
            "wait_for_composer_change": Mock(
                side_effect=[(marked, 24), (typed, 23)]
            ),
            "composer_has_expected_tail": Mock(
                side_effect=[True, KeyboardInterrupt()]
            ),
            "clear_composer": clear_composer,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            KeyboardInterrupt, "submit withheld; composer cleared"
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

        clear_composer.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, ("", 2), marked, None
        )
        self.assertEqual(
            type_text.call_args_list,
            [
                call("session-id", CLAUDE_PROFILE, marked, None),
                call(
                    "session-id",
                    CLAUDE_PROFILE,
                    "\x7f" * len(marker),
                    None,
                ),
            ],
        )

    def test_raw_body_transaction_interrupt_uses_guarded_cleanup(self) -> None:
        typed = "Chat from Codex: body"
        marker = COMPOSER_PROBE_MARKER(typed)
        partial = "Chat from Codex:" + marker
        type_text = Mock()
        clear_composer = Mock(return_value=True)

        def interrupt_with_partial_progress(*args: object) -> None:
            args[-1].owned_text = partial
            raise KeyboardInterrupt()

        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(side_effect=interrupt_with_partial_progress),
            "type_text": type_text,
            "clear_composer": clear_composer,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            KeyboardInterrupt,
            "body transaction started; submit withheld; composer cleared",
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

        clear_composer.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, ("", 2), partial, None
        )
        type_text.assert_not_called()

    def test_interrupt_during_cleanup_preserves_partial_body_warning(self) -> None:
        type_text = Mock()
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(
                side_effect=COMPOSER_DIRTY(
                    "message chunk failed; submit withheld",
                    "Chat from Codex: partial body",
                )
            ),
            "type_text": type_text,
            "clear_composer": Mock(side_effect=KeyboardInterrupt()),
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            KeyboardInterrupt,
            "submit withheld; composer cleanup interrupted",
        ):
            SEND("session-id", CLAUDE_PROFILE, "partial body")

        type_text.assert_not_called()

    def test_cleanup_value_error_reports_failure_without_submitting(self) -> None:
        type_text = Mock()
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(
                side_effect=COMPOSER_DIRTY(
                    "message chunk failed; submit withheld",
                    "Chat from Codex: partial body",
                )
            ),
            "type_text": type_text,
            "clear_composer": Mock(side_effect=ValueError("malformed JSON")),
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            COMPOSER_DIRTY,
            "submit withheld; composer cleanup failed",
        ):
            SEND("session-id", CLAUDE_PROFILE, "partial body")

        type_text.assert_not_called()

    def test_missing_middle_withholds_submit(self) -> None:
        type_text = Mock()
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(
                side_effect=COMPOSER_DIRTY(
                    "message chunk 2/3 is incomplete; submit withheld",
                    "Chat from Codex: opening missing",
                )
            ),
            "type_text": type_text,
            "clear_composer": Mock(return_value=True),
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            COMPOSER_DIRTY, "incomplete; submit withheld; composer cleared"
        ):
            SEND("session-id", CLAUDE_PROFILE, "opening missing middle closing")

        type_text.assert_not_called()

    def test_control_character_is_rejected_before_any_pane_write(self) -> None:
        pane_text = Mock()
        type_body = Mock()
        type_text = Mock()
        replacements = {
            "pane_text": pane_text,
            "type_body": type_body,
            "type_text": type_text,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            ValueError, "control character"
        ):
            SEND("session-id", CLAUDE_PROFILE, "safe prefix\0unsafe suffix")

        pane_text.assert_not_called()
        type_body.assert_not_called()
        type_text.assert_not_called()

    def test_unaccepted_submit_is_reported(self) -> None:
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(return_value=("Chat from Codex: body", 22)),
            "composer_state": Mock(return_value=("Chat from Codex: body", 22)),
            "type_text": Mock(),
            "wait_for_accepted": Mock(return_value=False),
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            RuntimeError,
            "did not confirm submission.*delivery is ambiguous.*do not resend",
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

    def test_changed_composer_before_submit_withholds_return(self) -> None:
        type_text = Mock()
        replacements = {
            "pane_text": Mock(return_value=f"{RULE}\n❯ \n{RULE}"),
            "cursor_column": Mock(return_value=2),
            "type_body": Mock(return_value=("Chat from Codex: body", 23)),
            "composer_state": Mock(return_value=None),
            "clear_composer": Mock(return_value=False),
            "type_text": type_text,
        }

        with patch.dict(SEND.__globals__, replacements), self.assertRaisesRegex(
            COMPOSER_DIRTY,
            "composer changed before submit; submit withheld; composer cleanup failed",
        ):
            SEND("session-id", CLAUDE_PROFILE, "body")

        type_text.assert_not_called()


class ComposerTransitionTests(unittest.TestCase):
    def test_unchanged_composer_through_deadline_rejects_the_event(self) -> None:
        composer_state = Mock(return_value=("same body", 18))
        clock = Mock(
            monotonic=Mock(side_effect=[0.0, 0.1, 3.1]),
            sleep=Mock(),
        )
        replacements = {
            "composer_state": composer_state,
            "time": clock,
        }

        with patch.dict(WAIT_FOR_COMPOSER_CHANGE.__globals__, replacements):
            self.assertIsNone(
                WAIT_FOR_COMPOSER_CHANGE(
                    "session-id",
                    PROFILES["codex"],
                    ("same body", 18),
                    CHUNK_SETTLE_DELAY,
                )
            )

        self.assertEqual(composer_state.call_count, 2)

    def test_change_waits_for_the_composer_only_to_settle(self) -> None:
        self.assertGreaterEqual(COMPOSER_SETTLE_DELAY, 0.5)
        composer_state = Mock(
            side_effect=[
                ("part 1", 2),
                ("part 2", 2),
                ("part 2", 2),
                ("part 2", 2),
            ]
        )
        clock = Mock(
            monotonic=Mock(side_effect=[0.0, 0.1, 0.4, 0.7, 0.9]),
            sleep=Mock(),
        )
        replacements = {
            "composer_state": composer_state,
            "time": clock,
        }

        with patch.dict(WAIT_FOR_COMPOSER_CHANGE.__globals__, replacements):
            self.assertEqual(
                WAIT_FOR_COMPOSER_CHANGE(
                    "session-id",
                    PROFILES["codex"],
                    ("part 1", 2),
                    COMPOSER_SETTLE_DELAY,
                ),
                ("part 2", 2),
            )

        self.assertEqual(composer_state.call_count, 4)
        self.assertEqual(clock.sleep.call_count, 3)

    def test_accepted_requires_changed_state_and_empty_cursor(self) -> None:
        replacements = {
            "composer_state": Mock(
                side_effect=[
                    ("reflowed body", 2),
                    ("Ask Codex to do anything", 2),
                    ("Ask Codex to do anything", 2),
                ]
            ),
            "time": stepping_time(),
        }

        with patch.dict(WAIT_FOR_ACCEPTED.__globals__, replacements):
            self.assertTrue(
                WAIT_FOR_ACCEPTED(
                    "session-id", PROFILES["codex"], ("body", 18)
                )
            )

        self.assertEqual(replacements["composer_state"].call_count, 3)

    def test_reflowed_unsent_body_at_column_two_is_not_accepted(self) -> None:
        replacements = {
            "composer_state": Mock(return_value=("reflowed unsent body", 2)),
            "time": Mock(
                monotonic=Mock(side_effect=[0.0, 3.1]), sleep=Mock()
            ),
        }

        with patch.dict(WAIT_FOR_ACCEPTED.__globals__, replacements):
            self.assertFalse(
                WAIT_FOR_ACCEPTED(
                    "session-id",
                    PROFILES["codex"],
                    ("original unsent body", 27),
                )
            )

    def test_cursor_reset_with_the_same_body_is_not_accepted(self) -> None:
        replacements = {
            "composer_state": Mock(return_value=("same body", 2)),
            "time": Mock(monotonic=Mock(side_effect=[0.0, 3.1]), sleep=Mock()),
        }

        with patch.dict(WAIT_FOR_ACCEPTED.__globals__, replacements):
            self.assertFalse(
                WAIT_FOR_ACCEPTED(
                    "session-id", PROFILES["codex"], ("same body", 18)
                )
            )

    def test_queued_placeholder_counts_as_accepted(self) -> None:
        replacements = {
            "composer_state": Mock(
                return_value=("Press up to edit queued messages", 2)
            ),
            "time": stepping_time(),
        }

        with patch.dict(WAIT_FOR_ACCEPTED.__globals__, replacements):
            self.assertTrue(
                WAIT_FOR_ACCEPTED(
                    "session-id", CLAUDE_PROFILE, ("Chat from Codex: body", 25)
                )
            )


class ComposerCleanupTests(unittest.TestCase):
    def test_clear_does_not_claim_an_unobserved_body_was_removed(self) -> None:
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(return_value=("", 2)),
            "time": Mock(
                monotonic=Mock(side_effect=[0.0, 3.1]), sleep=Mock()
            ),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertFalse(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), "queued body"
                )
            )

        type_text.assert_not_called()

    def test_clear_waits_for_body_after_the_initial_empty_state(self) -> None:
        owned = "delayed body"
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[("", 2), (owned, 14), (owned, 14), ("", 2)]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        type_text.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "\x7f" * len(owned), None
        )

    def test_clear_backspaces_without_interrupting_the_active_turn(self) -> None:
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[("partial body", 14), ("partial body", 14), ("", 2)]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), "partial body"
                )
            )

        type_text.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "\x7f" * len("partial body"), None
        )

    def test_clear_does_not_repeat_unchanged_periodic_text(self) -> None:
        repeated = ("a" * 80, 2)
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[repeated] * 10 + [("", 2)]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), "a" * 400
                )
            )

        type_text.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "\x7f" * 80, None
        )

    def test_clear_waits_for_a_lagging_backspace_batch(self) -> None:
        owned = " ".join(f"word-{index:03d}" for index in range(36))
        remaining = owned[:-TYPE_CHUNK_BYTES]
        full = (owned, 28)
        partial = (remaining, 17)
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[full] * 12 + [partial, partial, ("", 2)]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        self.assertEqual(
            [len(item.args[2]) for item in type_text.call_args_list],
            [TYPE_CHUNK_BYTES, len(remaining)],
        )

    def test_clear_does_not_repeat_a_stalled_backspace_batch(self) -> None:
        owned = " ".join(f"word-{index:03d}" for index in range(36))
        full = (owned, 28)
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(return_value=full),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertFalse(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        type_text.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "\x7f" * TYPE_CHUNK_BYTES, None
        )

    def test_clear_ignores_one_torn_unowned_sample(self) -> None:
        owned = " ".join(f"word-{index:03d}" for index in range(36))
        remaining = owned[:-TYPE_CHUNK_BYTES]
        full = (owned, 28)
        torn = (owned, 17)
        partial = (remaining, 17)
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[full, full, torn, partial, partial, ("", 2)]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        self.assertEqual(
            [len(item.args[2]) for item in type_text.call_args_list],
            [TYPE_CHUNK_BYTES, len(remaining)],
        )

    def test_clear_ignores_one_unrecognised_sample(self) -> None:
        owned = " ".join(f"word-{index:03d}" for index in range(36))
        remaining = owned[:-TYPE_CHUNK_BYTES]
        full = (owned, 28)
        partial = (remaining, 17)
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[full, full, None, partial, partial, ("", 2)]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        self.assertEqual(
            [len(item.args[2]) for item in type_text.call_args_list],
            [TYPE_CHUNK_BYTES, len(remaining)],
        )

    def test_clear_ignores_an_initial_unrecognised_sample(self) -> None:
        owned = "partial body"
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[None, (owned, 14), (owned, 14), ("", 2)]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        type_text.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "\x7f" * len(owned), None
        )

    def test_clear_continues_from_a_partly_applied_batch(self) -> None:
        owned = " ".join(f"word-{index:03d}" for index in range(36))
        after_partial = owned[:-120]
        after_second = after_partial[:-TYPE_CHUNK_BYTES]
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[
                    (owned, 28),
                    (owned, 28),
                    (after_partial, 19),
                    (after_partial, 19),
                    (after_second, 8),
                    (after_second, 8),
                    ("", 2),
                ]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        self.assertEqual(
            [len(item.args[2]) for item in type_text.call_args_list],
            [TYPE_CHUNK_BYTES, TYPE_CHUNK_BYTES, len(after_second)],
        )

    def test_clear_owns_a_distinct_scrolled_suffix(self) -> None:
        owned = " ".join(f"token-{index:03d}" for index in range(90))
        remaining_ends = list(range(len(owned), 0, -TYPE_CHUNK_BYTES))
        rendered = {
            end: (owned[max(0, end - 240) : end], 2)
            for end in remaining_ends
        }
        states = []
        for end in remaining_ends:
            states.extend([rendered[end]] * 2)
        states.append(("", 2))
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(side_effect=states),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        expected_sizes = [
            min(TYPE_CHUNK_BYTES, end) for end in remaining_ends
        ]
        self.assertEqual(
            [len(item.args[2]) for item in type_text.call_args_list],
            expected_sizes,
        )

    def test_clear_continues_while_small_batches_make_progress(self) -> None:
        owned = "".join(f"{index:04d}" for index in range(250))
        remaining = [len(owned)]

        def composer_state(*_args: object) -> tuple[str, int]:
            if not remaining[0]:
                return "", 2
            start = max(0, remaining[0] - 10)
            return owned[start : remaining[0]], 11

        def type_text(*args: object) -> None:
            typed = str(args[2])
            self.assertEqual(set(typed), {"\x7f"})
            remaining[0] -= len(typed)

        write = Mock(side_effect=type_text)
        replacements = {
            "type_text": write,
            "composer_state": Mock(side_effect=composer_state),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        self.assertEqual(remaining[0], 0)
        self.assertEqual(write.call_count, len(owned) // 10)

    def test_clear_accepts_a_parser_elided_trailing_space(self) -> None:
        remaining = "alpha beta gamma "
        owned = remaining + "x" * TYPE_CHUNK_BYTES

        def parsed(text: str) -> str:
            content = LIVE_PROMPT_TEXT(
                CLAUDE_PROFILE, f"{RULE}\n❯ {text}\n{RULE}"
            )
            self.assertIsNotNone(content)
            return content or ""

        full = (parsed(owned), 24)
        trimmed = (parsed(remaining), 18)
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[full, full, trimmed, trimmed, ("", 2)]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        self.assertEqual(
            [len(item.args[2]) for item in type_text.call_args_list],
            [TYPE_CHUNK_BYTES, len(remaining)],
        )

    def test_clear_stops_when_foreign_text_appears_after_one_batch(self) -> None:
        owned = "alpha beta gamma delta epsilon"
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[
                    ("delta epsilon", 14),
                    ("delta epsilon", 14),
                    ("alpha beta USER", 16),
                    ("alpha beta USER", 16),
                ]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertFalse(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        type_text.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "\x7f" * len("delta epsilon"), None
        )

    def test_clear_accepts_a_partially_written_marker_prefix(self) -> None:
        owned = "payload [peer-check:0]"
        partial = "payload [peer-ch"
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(
                side_effect=[(partial, 17), (partial, 17), ("", 2)]
            ),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertTrue(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), owned
                )
            )

        type_text.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "\x7f" * len(partial), None
        )

    def test_unrecognised_composer_is_never_backspaced(self) -> None:
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(return_value=None),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertFalse(
                CLEAR_COMPOSER(
                    "session-id", CLAUDE_PROFILE, ("", 2), "a" * 400
                )
            )

        type_text.assert_not_called()

    def test_foreign_suffix_is_never_backspaced(self) -> None:
        type_text = Mock()
        replacements = {
            "type_text": type_text,
            "composer_state": Mock(return_value=("script prefix USER DRAFT", 27)),
            "time": stepping_time(),
        }

        with patch.dict(CLEAR_COMPOSER.__globals__, replacements):
            self.assertFalse(
                CLEAR_COMPOSER(
                    "session-id",
                    CLAUDE_PROFILE,
                    ("", 2),
                    "script prefix",
                )
            )

        type_text.assert_not_called()


class WindowPropagationTests(unittest.TestCase):
    def test_composer_state_checks_target_once_per_sample(self) -> None:
        require_target = Mock(return_value="full-session-id")
        pane_text = Mock(return_value="screen")
        cursor_column = Mock(return_value=17)
        replacements = {
            "require_target": require_target,
            "_pane_text_unchecked": pane_text,
            "_cursor_column_unchecked": cursor_column,
            "live_prompt_text": Mock(return_value="body"),
        }

        with patch.dict(COMPOSER_STATE.__globals__, replacements):
            self.assertEqual(
                COMPOSER_STATE(
                    "session-prefix", CLAUDE_PROFILE, "stable-window-id"
                ),
                ("body", 17),
            )

        require_target.assert_called_once_with(
            "session-prefix", CLAUDE_PROFILE, "stable-window-id"
        )
        pane_text.assert_called_once_with(
            "full-session-id", CLAUDE_PROFILE, "stable-window-id"
        )
        cursor_column.assert_called_once_with(
            "full-session-id", CLAUDE_PROFILE, "stable-window-id"
        )

    def test_tree_read_is_window_scoped(self) -> None:
        ctl = Mock(return_value='{"result": {"tree": {}}}')

        with patch.dict(TREE.__globals__, {"ctl": ctl}):
            TREE("stable-window-id")

        ctl.assert_called_once_with(
            "tree", "--json", "--window", "stable-window-id"
        )

    def test_pane_read_is_window_scoped(self) -> None:
        require_target = Mock()
        ctl = Mock(return_value="screen")

        with patch.dict(
            PANE_TEXT.__globals__,
            {"require_target": require_target, "ctl": ctl},
        ):
            PANE_TEXT(
                "session-id", CLAUDE_PROFILE, "stable-window-id"
            )

        require_target.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "stable-window-id"
        )
        ctl.assert_called_once_with(
            "session",
            "text",
            "--pane",
            "left",
            "--target",
            "session-id",
            "--lines",
            str(SCRIPT["BOX_LINES"]),
            "--window",
            "stable-window-id",
        )

    def test_cursor_read_is_window_scoped(self) -> None:
        require_target = Mock()
        ctl = Mock(return_value="2\n")

        with patch.dict(
            CURSOR_COLUMN.__globals__,
            {"require_target": require_target, "ctl": ctl},
        ):
            self.assertEqual(
                CURSOR_COLUMN(
                    "session-id", CLAUDE_PROFILE, "stable-window-id"
                ),
                2,
            )

        require_target.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "stable-window-id"
        )
        ctl.assert_called_once_with(
            "surface",
            "cursor",
            "--target",
            "surface:session-id:left",
            "--window",
            "stable-window-id",
        )


class TypeTextTests(unittest.TestCase):
    def test_rechecks_target_then_writes_body_on_stdin(self) -> None:
        require_target = Mock()
        ctl = Mock(return_value="")
        calls = Mock()
        calls.attach_mock(require_target, "require_target")
        calls.attach_mock(ctl, "ctl")
        replacements = {"require_target": require_target, "ctl": ctl}

        with patch.dict(TYPE_TEXT.__globals__, replacements):
            TYPE_TEXT("session-id", CLAUDE_PROFILE, "body\n")

        self.assertEqual(
            calls.mock_calls,
            [
                call.require_target("session-id", CLAUDE_PROFILE, None),
                call.ctl(
                    "session",
                    "type",
                    "--stdin",
                    "--pane",
                    "left",
                    "--target",
                    "session-id",
                    input_text="body\n",
                ),
            ],
        )

    def test_window_is_pinned_for_the_recheck_and_write(self) -> None:
        require_target = Mock()
        ctl = Mock(return_value="")
        replacements = {"require_target": require_target, "ctl": ctl}

        with patch.dict(TYPE_TEXT.__globals__, replacements):
            TYPE_TEXT(
                "session-id", CLAUDE_PROFILE, "body", "stable-window-id"
            )

        require_target.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "stable-window-id"
        )
        ctl.assert_called_once_with(
            "session",
            "type",
            "--stdin",
            "--pane",
            "left",
            "--target",
            "session-id",
            "--window",
            "stable-window-id",
            input_text="body",
        )


class TypeBodyTests(unittest.TestCase):
    def test_probe_marker_is_absent_from_the_message(self) -> None:
        message = "body [peer-check:0] more body"

        marker = COMPOSER_PROBE_MARKER(message)

        self.assertEqual(marker, " [peer-check:1]")
        self.assertNotIn(marker, message)

    def test_chunks_preserve_utf8_without_exceeding_limit(self) -> None:
        message = "a" * (TYPE_CHUNK_BYTES - 1) + "€" + "b" * 901

        chunks = TEXT_CHUNKS(message)

        self.assertEqual("".join(chunks), message)
        self.assertTrue(
            all(len(chunk.encode("utf-8")) <= TYPE_CHUNK_BYTES for chunk in chunks)
        )

    def test_chunks_start_at_word_boundaries(self) -> None:
        message = "first " + "word " * 100 + "last"

        chunks = TEXT_CHUNKS(message)

        self.assertEqual("".join(chunks), message)
        self.assertTrue(all(chunk.startswith(" ") for chunk in chunks[1:]))

    def test_repeated_words_stay_in_bounded_events(self) -> None:
        message = "prefix " + "foo " * 300 + "suffix"

        chunks = TEXT_CHUNKS(message)

        self.assertEqual("".join(chunks), message)
        self.assertEqual(len(chunks), 7)
        self.assertTrue(
            all(len(chunk.encode("utf-8")) <= TYPE_CHUNK_BYTES for chunk in chunks)
        )

    def test_overlong_unicode_token_uses_utf8_safe_bounded_events(self) -> None:
        message = "ж" * TYPE_CHUNK_BYTES

        chunks = TEXT_CHUNKS(message)

        self.assertEqual("".join(chunks), message)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(
            all(len(chunk.encode("utf-8")) <= TYPE_CHUNK_BYTES for chunk in chunks)
        )

    def test_each_chunk_waits_for_an_observed_composer_transition(self) -> None:
        type_text = Mock()
        marker = COMPOSER_PROBE_MARKER("body")
        chunk_limit = TYPE_CHUNK_BYTES - len(marker.encode("utf-8"))
        message = "a" * (chunk_limit + 1)
        chunks = TEXT_CHUNKS(message, chunk_limit)
        first_marked = (chunks[0] + marker, 2)
        first_unmarked = (chunks[0], 2)
        final_marked = (message + marker, 3)
        final_unmarked = (message, 3)
        wait_for_change = Mock(
            side_effect=[
                first_marked,
                first_unmarked,
                final_marked,
                final_unmarked,
            ]
        )
        calls = Mock()
        calls.attach_mock(type_text, "type_text")
        calls.attach_mock(wait_for_change, "wait_for_change")
        replacements = {
            "type_text": type_text,
            "wait_for_composer_change": wait_for_change,
        }
        with patch.dict(TYPE_BODY.__globals__, replacements):
            self.assertEqual(
                TYPE_BODY("session-id", CLAUDE_PROFILE, message, ("", 2)),
                final_unmarked,
            )

        self.assertEqual(
            calls.mock_calls,
            [
                call.type_text(
                    "session-id", CLAUDE_PROFILE, chunks[0] + marker, None
                ),
                call.wait_for_change(
                    "session-id",
                    CLAUDE_PROFILE,
                    ("", 2),
                    CHUNK_SETTLE_DELAY,
                    None,
                ),
                call.type_text(
                    "session-id",
                    CLAUDE_PROFILE,
                    "\x7f" * len(marker),
                    None,
                ),
                call.wait_for_change(
                    "session-id",
                    CLAUDE_PROFILE,
                    first_marked,
                    CHUNK_SETTLE_DELAY,
                    None,
                ),
                call.type_text(
                    "session-id", CLAUDE_PROFILE, chunks[1] + marker, None
                ),
                call.wait_for_change(
                    "session-id",
                    CLAUDE_PROFILE,
                    first_unmarked,
                    CHUNK_SETTLE_DELAY,
                    None,
                ),
                call.type_text(
                    "session-id",
                    CLAUDE_PROFILE,
                    "\x7f" * len(marker),
                    None,
                ),
                call.wait_for_change(
                    "session-id",
                    CLAUDE_PROFILE,
                    final_marked,
                    COMPOSER_SETTLE_DELAY,
                    None,
                ),
            ],
        )
        body_events = [
            item.args[2]
            for item in type_text.call_args_list
            if not item.args[2].startswith("\x7f")
        ]
        self.assertTrue(
            all(len(item.encode("utf-8")) <= TYPE_CHUNK_BYTES for item in body_events)
        )

    def test_periodic_viewport_ambiguity_fails_before_submit(self) -> None:
        marker = COMPOSER_PROBE_MARKER("body")
        chunk_limit = TYPE_CHUNK_BYTES - len(marker.encode("utf-8"))
        message = "x" * (chunk_limit * 3)
        chunks = TEXT_CHUNKS(message, chunk_limit)
        visible = chunk_limit + CHUNK_VERIFY_OVERLAP
        expected = ""
        states = []
        for chunk in chunks:
            expected += chunk
            states.extend(
                [
                    ((expected + marker)[-(visible + len(marker)) :], 2),
                    (expected[-visible:], 2),
                ]
            )
        type_text = Mock()
        wait_for_change = Mock(side_effect=states)
        replacements = {
            "type_text": type_text,
            "wait_for_composer_change": wait_for_change,
        }

        with (
            patch.dict(TYPE_BODY.__globals__, replacements),
            self.assertRaisesRegex(RuntimeError, "chunk 2/3 is incomplete"),
        ):
            TYPE_BODY("session-id", CLAUDE_PROFILE, message, ("", 2))

        self.assertEqual(wait_for_change.call_count, 3)
        self.assertEqual(len(type_text.call_args_list), 3)
        self.assertTrue(type_text.call_args_list[-1].args[2].endswith(marker))

    def test_missing_chunk_transition_stops_before_later_chunks(self) -> None:
        type_text = Mock()
        marker = COMPOSER_PROBE_MARKER("body")
        chunk_limit = TYPE_CHUNK_BYTES - len(marker.encode("utf-8"))
        message = "a" * chunk_limit + "b" * (chunk_limit - 1) + "Zc"
        chunks = TEXT_CHUNKS(message, chunk_limit)
        first_marked = (chunks[0] + marker, 2)
        first_unmarked = (chunks[0], 2)
        wait_for_change = Mock(side_effect=[first_marked, first_unmarked, None])
        replacements = {
            "type_text": type_text,
            "wait_for_composer_change": wait_for_change,
        }
        with (
            patch.dict(TYPE_BODY.__globals__, replacements),
            self.assertRaisesRegex(RuntimeError, "chunk 2/3"),
        ):
            TYPE_BODY("session-id", CLAUDE_PROFILE, message, ("", 2))

        self.assertEqual(
            type_text.call_args_list,
            [
                call(
                    "session-id",
                    CLAUDE_PROFILE,
                    chunks[0] + marker,
                    None,
                ),
                call(
                    "session-id",
                    CLAUDE_PROFILE,
                    "\x7f" * len(marker),
                    None,
                ),
                call(
                    "session-id",
                    CLAUDE_PROFILE,
                    chunks[1] + marker,
                    None,
                ),
            ],
        )

    def test_incomplete_changed_chunk_stops_before_later_chunks(self) -> None:
        type_text = Mock()
        marker = COMPOSER_PROBE_MARKER("body")
        chunk_limit = TYPE_CHUNK_BYTES - len(marker.encode("utf-8"))
        message = "a" * chunk_limit + "b" * (chunk_limit - 1) + "Zc"
        chunks = TEXT_CHUNKS(message, chunk_limit)
        first_marked = (chunks[0] + marker, 2)
        first_unmarked = (chunks[0], 2)
        incomplete_second = (chunks[0] + chunks[1][:-1] + marker, 2)
        wait_for_change = Mock(
            side_effect=[first_marked, first_unmarked, incomplete_second]
        )
        replacements = {
            "type_text": type_text,
            "wait_for_composer_change": wait_for_change,
        }
        with (
            patch.dict(TYPE_BODY.__globals__, replacements),
            self.assertRaisesRegex(RuntimeError, "chunk 2/3 is incomplete"),
        ):
            TYPE_BODY("session-id", CLAUDE_PROFILE, message, ("", 2))

        self.assertEqual(len(type_text.call_args_list), 3)


class ComposerTailTests(unittest.TestCase):
    def test_terminal_wrapping_is_ignored(self) -> None:
        typed = "Chat from Claude: one two three"
        rendered = "Chat from Claude: one tw\no three"

        self.assertTrue(
            COMPOSER_HAS_EXPECTED_TAIL(rendered, typed, typed)
        )

    def test_space_loss_at_visual_wrap_is_unobservable(self) -> None:
        typed = "a" * 64 + " beta [peer-check:0]"
        rendered = "a" * 64 + "\nbeta [peer-check:0]"

        self.assertTrue(
            COMPOSER_HAS_EXPECTED_TAIL(rendered, typed, typed)
        )

    def test_missing_space_on_one_visual_row_is_rejected(self) -> None:
        typed = "Chat from Claude: alpha beta"

        self.assertFalse(
            COMPOSER_HAS_EXPECTED_TAIL(
                "Chat from Claude: alphabeta", typed, typed
            )
        )

    def test_separator_anchor_rejects_a_missing_first_word_character(self) -> None:
        expected = "a" * 400 + " alpha beta"
        chunk = " alpha beta"
        corrupted = "a" * 400 + " lpha beta"

        self.assertFalse(
            COMPOSER_HAS_EXPECTED_TAIL(corrupted[-100:], expected, chunk)
        )

    def test_missing_middle_is_rejected_even_when_tail_is_present(self) -> None:
        typed = "Chat from Claude: opening missing middle closing"
        rendered = "Chat from Claude: opening closing"

        self.assertFalse(
            COMPOSER_HAS_EXPECTED_TAIL(rendered, typed, typed)
        )

    def test_truncated_periodic_chunk_is_ambiguous(self) -> None:
        marker = " [peer-check:0]"
        previous = "a" * 64
        chunk = "a" * 50 + marker
        expected = previous + chunk
        missing_chunk_prefix = "a" * 104 + marker

        self.assertFalse(
            COMPOSER_HAS_EXPECTED_TAIL(
                missing_chunk_prefix, expected, chunk
            )
        )

    def test_scrolled_prefix_is_not_required_after_earlier_chunks_passed(self) -> None:
        earlier = "old " * 300
        latest = " ".join(["latest"] * 30)
        expected = earlier + latest
        visible = expected[-(len(latest) + CHUNK_VERIFY_OVERLAP) :]
        visible = visible.replace(" latest", "\nlatest", 2)

        self.assertTrue(
            COMPOSER_HAS_EXPECTED_TAIL(visible, expected, latest)
        )


class ArgumentTests(unittest.TestCase):
    def test_queue_is_available_for_codex(self) -> None:
        args = PARSE_ARGS(["--to", "codex", "--queue", "--stdin"])

        self.assertTrue(args.queue)

    def test_queue_is_refused_for_claude(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            PARSE_ARGS(["--to", "claude", "--queue", "--stdin"])

    def test_explicit_window_is_available_outside_the_target_window(self) -> None:
        args = PARSE_ARGS(
            ["--to", "claude", "--window", "window-id", "--stdin"]
        )

        self.assertEqual(args.window, "window-id")

    def test_blank_explicit_selectors_are_refused(self) -> None:
        for option in ("--session", "--window"):
            with (
                self.subTest(option=option),
                redirect_stderr(io.StringIO()),
                self.assertRaises(SystemExit),
            ):
                PARSE_ARGS(["--to", "claude", option, "", "--stdin"])


class WindowResolutionTests(unittest.TestCase):
    def test_blank_explicit_window_does_not_fall_back_to_active(self) -> None:
        with (
            patch.dict(os.environ, {}, clear=True),
            self.assertRaisesRegex(RuntimeError, "window selector is empty"),
        ):
            RESOLVE_WINDOW("")

    def test_blank_environment_window_does_not_fall_back_to_active(self) -> None:
        with (
            patch.dict(os.environ, {"AGTERM_WINDOW_ID": ""}, clear=True),
            self.assertRaisesRegex(RuntimeError, "window selector is empty"),
        ):
            RESOLVE_WINDOW(None)

    def test_environment_window_is_resolved_to_a_stable_id(self) -> None:
        payload = {
            "result": {
                "windows": [
                    {
                        "id": "environment-window-full-id",
                        "open": True,
                        "active": False,
                    }
                ]
            }
        }
        ctl = Mock(return_value=json.dumps(payload))

        with (
            patch.dict(os.environ, {"AGTERM_WINDOW_ID": "environment-window"}),
            patch.dict(RESOLVE_WINDOW.__globals__, {"ctl": ctl}),
        ):
            self.assertEqual(
                RESOLVE_WINDOW(None), "environment-window-full-id"
            )

        ctl.assert_called_once_with("window", "list", "--json")

    def test_active_window_is_snapshotted_when_the_environment_is_absent(self) -> None:
        payload = {
            "result": {
                "windows": [
                    {"id": "closed", "open": False, "active": False},
                    {"id": "active-window", "open": True, "active": True},
                ]
            }
        }
        replacements = {"ctl": Mock(return_value=json.dumps(payload))}

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(RESOLVE_WINDOW.__globals__, replacements),
        ):
            self.assertEqual(RESOLVE_WINDOW(None), "active-window")

    def test_explicit_active_selector_is_snapshotted(self) -> None:
        payload = {
            "result": {
                "windows": [
                    {"id": "first", "open": True, "active": False},
                    {"id": "second", "open": True, "active": True},
                ]
            }
        }

        with patch.dict(
            RESOLVE_WINDOW.__globals__,
            {"ctl": Mock(return_value=json.dumps(payload))},
        ):
            self.assertEqual(RESOLVE_WINDOW("active"), "second")

    def test_closed_explicit_window_is_refused(self) -> None:
        payload = {
            "result": {
                "windows": [
                    {"id": "closed-window", "open": False, "active": False}
                ]
            }
        }

        with (
            patch.dict(
                RESOLVE_WINDOW.__globals__,
                {"ctl": Mock(return_value=json.dumps(payload))},
            ),
            self.assertRaisesRegex(RuntimeError, "not open"),
        ):
            RESOLVE_WINDOW("closed")

    def test_environment_session_without_window_finds_its_open_owner(self) -> None:
        target = {
            "id": "session-full-id",
            "hasSplit": True,
            "foreground": ["claude"],
            "splitForeground": ["codex"],
        }
        replacements = {
            "open_window_ids": Mock(return_value=["window-a", "window-b"]),
            "tree": Mock(side_effect=[{"sessions": [target]}, {"sessions": []}]),
        }

        with (
            patch.dict(
                os.environ, {"AGTERM_SESSION_ID": "session-full"}, clear=True
            ),
            patch.dict(RESOLVE_TARGET.__globals__, replacements),
        ):
            self.assertEqual(
                RESOLVE_TARGET(None, None, CLAUDE_PROFILE),
                ("window-a", "session-full-id"),
            )

    def test_explicit_session_ignores_the_ambient_window(self) -> None:
        target = {
            "id": "session-b-full-id",
            "hasSplit": True,
            "foreground": ["claude"],
            "splitForeground": ["codex"],
        }
        resolve_window = Mock()
        replacements = {
            "resolve_window": resolve_window,
            "open_window_ids": Mock(return_value=["window-a", "window-b"]),
            "tree": Mock(side_effect=[{"sessions": []}, {"sessions": [target]}]),
        }

        with (
            patch.dict(
                os.environ, {"AGTERM_WINDOW_ID": "window-a"}, clear=True
            ),
            patch.dict(RESOLVE_TARGET.__globals__, replacements),
        ):
            self.assertEqual(
                RESOLVE_TARGET("session-b", None, CLAUDE_PROFILE),
                ("window-b", "session-b-full-id"),
            )

        resolve_window.assert_not_called()

    def test_blank_session_selectors_do_not_fall_back(self) -> None:
        for explicit, environment in (("", {}), (None, {"AGTERM_SESSION_ID": ""})):
            with (
                self.subTest(explicit=explicit, environment=environment),
                patch.dict(os.environ, environment, clear=True),
                self.assertRaisesRegex(RuntimeError, "session selector is empty"),
            ):
                RESOLVE_TARGET(explicit, None, CLAUDE_PROFILE)

    def test_explicit_window_constrains_session_lookup(self) -> None:
        resolve_session = Mock(side_effect=RuntimeError("no such session"))
        replacements = {
            "resolve_window": Mock(return_value="window-b"),
            "resolve_session": resolve_session,
        }

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(RESOLVE_TARGET.__globals__, replacements),
            self.assertRaisesRegex(RuntimeError, "no such session"),
        ):
            RESOLVE_TARGET("session-id", "window-b", CLAUDE_PROFILE)

        resolve_session.assert_called_once_with(
            "session-id", CLAUDE_PROFILE, "window-b"
        )

    def test_session_prefix_ambiguous_across_windows_is_refused(self) -> None:
        first = {
            "id": "session-one",
            "hasSplit": True,
            "foreground": ["claude"],
        }
        second = {
            "id": "session-two",
            "hasSplit": True,
            "foreground": ["claude"],
        }
        replacements = {
            "open_window_ids": Mock(return_value=["window-a", "window-b"]),
            "tree": Mock(
                side_effect=[{"sessions": [first]}, {"sessions": [second]}]
            ),
        }

        with (
            patch.dict(os.environ, {}, clear=True),
            patch.dict(RESOLVE_TARGET.__globals__, replacements),
            self.assertRaisesRegex(RuntimeError, "ambiguous session prefix"),
        ):
            RESOLVE_TARGET("session-", None, CLAUDE_PROFILE)


class MainWindowFlowTests(unittest.TestCase):
    @staticmethod
    def args() -> argparse.Namespace:
        return argparse.Namespace(
            prepare_message=None,
            stdin=True,
            message_file=None,
            to="claude",
            session="session-prefix",
            window="active",
            target_command=None,
            queue=False,
        )

    def replacements(self, send_with_retry: Mock) -> dict[str, object]:
        return {
            "parse_args": Mock(return_value=self.args()),
            "target_profile": Mock(return_value=CLAUDE_PROFILE),
            "resolve_target": Mock(
                return_value=("stable-window-id", "stable-session-id")
            ),
            "read_message": Mock(return_value="body"),
            "send_with_retry": send_with_retry,
        }

    def test_resolved_window_id_reaches_session_and_send(self) -> None:
        profile = CLAUDE_PROFILE
        resolve_target = Mock(
            return_value=("stable-window-id", "stable-session-id")
        )
        send_with_retry = Mock(return_value=4)
        replacements = {
            "parse_args": Mock(return_value=self.args()),
            "target_profile": Mock(return_value=profile),
            "resolve_target": resolve_target,
            "read_message": Mock(return_value="body"),
            "send_with_retry": send_with_retry,
        }

        with (
            patch.dict(MAIN.__globals__, replacements),
            patch("sys.stdout", new=io.StringIO()),
        ):
            self.assertEqual(MAIN(), 0)

        resolve_target.assert_called_once_with(
            "session-prefix", "active", profile
        )
        send_with_retry.assert_called_once_with(
            "stable-session-id", profile, "body", "stable-window-id", ANY
        )

    def test_interrupt_before_return_is_unsafe_to_resend(self) -> None:
        def interrupt_after_start(
            _sid: str,
            _profile: object,
            _message: str,
            _window: str,
            progress: object,
        ) -> None:
            progress.phase = "started"
            raise KeyboardInterrupt()

        replacements = self.replacements(Mock(side_effect=interrupt_after_start))
        stderr = io.StringIO()

        with patch.dict(MAIN.__globals__, replacements), redirect_stderr(stderr):
            self.assertEqual(MAIN(), 130)

        self.assertIn(
            "delivery status is unavailable; do not resend", stderr.getvalue()
        )

    def test_detailed_delivery_interrupt_is_preserved(self) -> None:
        replacements = self.replacements(
            Mock(
                side_effect=KeyboardInterrupt(
                    "submit request was interrupted; delivery is ambiguous; "
                    "do not resend"
                )
            )
        )
        stderr = io.StringIO()

        with patch.dict(MAIN.__globals__, replacements), redirect_stderr(stderr):
            self.assertEqual(MAIN(), 130)

        self.assertIn("submit request was interrupted", stderr.getvalue())

    def test_interrupt_during_success_report_confirms_delivery(self) -> None:
        replacements = self.replacements(Mock(return_value=4))
        replacements["report_success"] = Mock(side_effect=KeyboardInterrupt())
        stderr = io.StringIO()

        with patch.dict(MAIN.__globals__, replacements), redirect_stderr(stderr):
            self.assertEqual(MAIN(), 130)

        self.assertIn(
            "delivery was confirmed; do not resend; success report interrupted",
            stderr.getvalue(),
        )

    def test_broken_success_report_confirms_delivery(self) -> None:
        replacements = self.replacements(Mock(return_value=4))
        replacements["report_success"] = Mock(
            side_effect=BrokenPipeError("stdout closed")
        )
        stderr = io.StringIO()

        with patch.dict(MAIN.__globals__, replacements), redirect_stderr(stderr):
            self.assertEqual(MAIN(), 1)

        self.assertIn(
            "delivery was confirmed; do not resend; success report failed",
            stderr.getvalue(),
        )

    def test_interrupt_on_successful_inner_return_confirms_delivery(self) -> None:
        replacements = self.replacements(Mock(return_value=4))
        stdout = io.StringIO()
        stderr = io.StringIO()

        def interrupt_on_return(frame: object, event: str, _arg: object) -> object:
            if getattr(frame, "f_code", None) is RUN_MAIN.__code__ and event == "return":
                sys.settrace(None)
                raise KeyboardInterrupt()
            return interrupt_on_return

        previous_trace = sys.gettrace()
        try:
            with (
                patch.dict(MAIN.__globals__, replacements),
                patch("sys.stdout", new=stdout),
                redirect_stderr(stderr),
            ):
                sys.settrace(interrupt_on_return)
                self.assertEqual(MAIN(), 130)
        finally:
            sys.settrace(previous_trace)

        self.assertEqual(stdout.getvalue(), '{"sent": 4}\n')
        self.assertIn(
            "delivery was confirmed; do not resend; success report interrupted",
            stderr.getvalue(),
        )


class RetryTests(unittest.TestCase):
    def test_transport_failure_is_not_retried(self) -> None:
        send = Mock(side_effect=RuntimeError("transport failed"))
        sleep = Mock()
        replacements = {"send": send, "time": Mock(sleep=sleep)}

        with patch.dict(SEND_WITH_RETRY.__globals__, replacements), self.assertRaises(
            RuntimeError
        ):
            SEND_WITH_RETRY("session-id", PROFILES["codex"], "ping")

        send.assert_called_once_with(
            "session-id",
            PROFILES["codex"],
            "ping",
            None,
            "Chat from Claude: ping",
            ANY,
        )
        sleep.assert_not_called()

    def test_interrupt_during_normalisation_reports_no_write(self) -> None:
        send = Mock()
        progress = DELIVERY_PROGRESS()
        replacements = {
            "normalize": Mock(side_effect=KeyboardInterrupt()),
            "send": send,
        }

        with (
            patch.dict(SEND_WITH_RETRY.__globals__, replacements),
            self.assertRaisesRegex(KeyboardInterrupt, "nothing was typed"),
        ):
            SEND_WITH_RETRY(
                "session-id", PROFILES["codex"], "ping", progress=progress
            )

        send.assert_not_called()
        self.assertEqual(progress.phase, "not_started")

    def test_real_preflight_transport_failure_is_not_retried(self) -> None:
        pane_text = Mock(side_effect=RuntimeError("control socket is unavailable"))
        type_text = Mock()
        sleep = Mock()
        replacements = {
            "pane_text": pane_text,
            "type_text": type_text,
            "time": Mock(sleep=sleep),
        }

        with (
            patch.dict(SEND_WITH_RETRY.__globals__, replacements),
            self.assertRaisesRegex(RuntimeError, "nothing was typed"),
        ):
            SEND_WITH_RETRY("session-id", PROFILES["codex"], "ping")

        pane_text.assert_called_once()
        type_text.assert_not_called()
        sleep.assert_not_called()

    def test_interrupt_during_retry_wait_reports_no_write(self) -> None:
        send = Mock(side_effect=PROMPT_BLOCKED("occupied"))
        sleep = Mock(side_effect=KeyboardInterrupt())
        replacements = {"send": send, "time": Mock(sleep=sleep)}

        with (
            patch.dict(SEND_WITH_RETRY.__globals__, replacements),
            redirect_stderr(io.StringIO()),
            self.assertRaisesRegex(KeyboardInterrupt, "nothing was typed"),
        ):
            SEND_WITH_RETRY("session-id", PROFILES["codex"], "ping")

    def test_interrupt_during_retry_diagnostic_reports_no_write(self) -> None:
        progress = DELIVERY_PROGRESS()
        send = Mock(side_effect=PROMPT_BLOCKED("occupied"))
        replacements = {
            "send": send,
            "print": Mock(side_effect=KeyboardInterrupt()),
        }

        with (
            patch.dict(SEND_WITH_RETRY.__globals__, replacements),
            self.assertRaisesRegex(KeyboardInterrupt, "nothing was typed"),
        ):
            SEND_WITH_RETRY(
                "session-id",
                PROFILES["codex"],
                "ping",
                progress=progress,
            )

        send.assert_called_once()
        self.assertEqual(progress.phase, "not_started")

    def test_interrupt_across_pre_write_retry_handler_reports_no_write(self) -> None:
        source, first_line = inspect.getsourcelines(SEND_WITH_RETRY)
        loop_index = next(
            index
            for index, line in enumerate(source)
            if line.strip().startswith("for attempt in range(")
        )
        handler_index = next(
            index
            for index, line in enumerate(source)
            if line.strip() == "if attempt == RETRY_ATTEMPTS:"
        )
        outer_try_index = max(
            index
            for index, line in enumerate(source[:loop_index])
            if line.strip() == "try:"
        )
        attempt_try_index = next(
            index
            for index, line in enumerate(source[loop_index + 1 :], loop_index + 1)
            if line.strip() == "try:"
        )

        for name, target_index, target_hit, expected_sends in (
            ("outer try header", outer_try_index, 1, 0),
            ("attempt try header", attempt_try_index, 1, 0),
            ("handler entry", handler_index, 1, 1),
            ("loop hand-off", loop_index, 2, 1),
        ):
            with self.subTest(boundary=name):
                target_line = first_line + target_index
                send = Mock(side_effect=PROMPT_BLOCKED("occupied"))
                observed_progress: list[object] = []
                hits = 0

                def run_retry(
                    progress: object,
                    _observed_progress: list[object] = observed_progress,
                ) -> int:
                    _observed_progress.append(progress)
                    return SEND_WITH_RETRY(
                        "session-id",
                        PROFILES["codex"],
                        "ping",
                        progress=progress,
                    )

                def interrupt_at_boundary(
                    frame: object,
                    event: str,
                    _arg: object,
                    _target_line: int = target_line,
                    _target_hit: int = target_hit,
                ) -> object:
                    nonlocal hits
                    if (
                        getattr(frame, "f_code", None) is SEND_WITH_RETRY.__code__
                        and event == "line"
                        and getattr(frame, "f_lineno", None) == _target_line
                    ):
                        hits += 1
                        if hits == _target_hit:
                            sys.settrace(None)
                            raise KeyboardInterrupt()
                    return interrupt_at_boundary

                previous_trace = sys.gettrace()
                stderr = io.StringIO()
                try:
                    with (
                        patch.dict(
                            MAIN.__globals__,
                            {
                                "run_main": run_retry,
                                "send": send,
                                "time": Mock(sleep=Mock()),
                            },
                        ),
                        redirect_stderr(stderr),
                    ):
                        sys.settrace(interrupt_at_boundary)
                        self.assertEqual(MAIN(), 130)
                finally:
                    sys.settrace(previous_trace)

                self.assertIn("nothing was typed", stderr.getvalue())
                self.assertEqual(send.call_count, expected_sends)
                self.assertEqual(len(observed_progress), 1)
                self.assertEqual(
                    vars(observed_progress[0])["phase"], "not_started"
                )


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

    def test_oversized_stdin_message_is_rejected(self) -> None:
        stream = io.TextIOWrapper(
            io.BytesIO(b"x" * (MAX_MESSAGE_BYTES + 2)), encoding="utf-8"
        )

        with (
            patch.object(sys, "stdin", stream),
            self.assertRaisesRegex(ValueError, str(MAX_MESSAGE_BYTES)),
        ):
            READ_MESSAGE(True, None)

        self.assertEqual(stream.buffer.tell(), MAX_MESSAGE_BYTES + 1)

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
                    window=None,
                    target_command=None,
                    queue=False,
                )
                resolve_target = Mock(side_effect=RuntimeError("no target"))
                main_replacements = {
                    "parse_args": Mock(return_value=args),
                    "target_profile": Mock(return_value=CLAUDE_PROFILE),
                    "resolve_target": resolve_target,
                }

                with (
                    patch.dict(MAIN.__globals__, main_replacements),
                    redirect_stderr(io.StringIO()),
                ):
                    self.assertEqual(MAIN(), 1)

                resolve_target.assert_called_once_with(
                    None, None, CLAUDE_PROFILE
                )
                self.assertEqual(path.read_text(encoding="utf-8"), "message to retry")


if __name__ == "__main__":
    unittest.main()
