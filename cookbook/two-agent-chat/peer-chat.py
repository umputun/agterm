#!/usr/bin/env python3
"""Send one peer-chat message between Claude Code and Codex in an agterm split."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
from collections.abc import Iterator
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

# Live reproduction accepted 1,627 bytes and began losing 1,022-byte windows at
# 1,663 bytes. A narrow Claude composer also scrolls the opening of a 512-byte
# event out of its visible box, so keep each independently observed event small
# enough to remain readable by the post-write check.
TYPE_CHUNK_BYTES = 197
CHUNK_VERIFY_OVERLAP = 32
CHUNK_SETTLE_DELAY = 0.1
COMPOSER_SETTLE_DELAY = 0.5
PROBE_TIMEOUT = 3.0
PROBE_INTERVAL = 0.05
RETRY_ATTEMPTS = 5
RETRY_DELAY = 10.0
BOX_LINES = 80
EMPTY_CURSOR_COLUMN = 2
MAX_MESSAGE_BYTES = 64 * 1024
# Claude can put a short context label inside the top composer rule, for example `e2e`.
RULE_RE = re.compile(r"^\s*[─\u2014-]{10,}(?:\s+[^─\u2014-].*?\s+[─\u2014-]+)?\s*$")
# Codex draws the composer prompt as `›`; with reasoning effort set to ultra it upgrades
# the glyph to `»` (codex-rs/tui/src/bottom_pane/effort_ignition.rs). Both prompt patterns
# are anchored at column zero so prompt-shaped output cannot be mistaken for live input.
# Shell mode shows `!` and is deliberately not matched, so nothing is ever typed there.
CODEX_PROMPT_RE = re.compile(r"^[›»][\s ]*(.*?)\s*$")
CODEX_SHELL_PROMPT_RE = re.compile(r"^![\s ]*(.*?)\s*$")
CODEX_CHOICE_RE = re.compile(r"^\d+\.\s")
CODEX_EMPTY_PROMPT = "Ask Codex to do anything"
# Codex prefixes footer rows with two spaces. Only the final row is stripped: a
# multi-row shortcut overlay is indistinguishable from indented modal choices and
# therefore fails closed instead of weakening the live-prompt guard.
CODEX_FOOTER_RE = re.compile(r"^ {2}\S.*$")
CLAUDE_PROMPT_RE = re.compile(r"^\s*❯[\s ]*(.*?)\s*$")
CLAUDE_FOOTER_RE = re.compile(r"^ {2}\S.*$")
CLAUDE_EMPTY_PROMPTS = {
    "",
    "Press up to edit queued messages",
    "Press up to edit queued messages, Enter to send them immediately",
}
MESSAGE_NAME_RE = re.compile(r"peer-chat-[a-z0-9][a-z0-9-]{2,48}\.txt")
MESSAGE_SPOOL = Path(tempfile.gettempdir()) / f"agterm-peer-chat-{os.getuid()}"


@dataclass(frozen=True)
class Profile:
    pane: str
    agent: str
    command: str
    label: str
    submit: str


@dataclass
class BodyProgress:
    """Exact composer text owned at the latest body transaction boundary."""

    owned_text: str = ""


@dataclass
class DeliveryProgress:
    """Conservative delivery state shared with the outer CLI boundary."""

    phase: str = "not_started"


PROFILES = {
    "claude": Profile("left", "claude", "claude", "Chat from Codex: ", "\n"),
    "codex": Profile("right", "codex", "codex", "Chat from Claude: ", "\n"),
}


class PromptBlocked(RuntimeError):
    """The target prompt is occupied before any text was written."""


class ComposerDirty(RuntimeError):
    """A body write started but could not be verified before submission."""

    def __init__(
        self, message: str, owned_text: str, interrupted: bool = False
    ) -> None:
        super().__init__(message)
        self.owned_text = owned_text
        self.interrupted = interrupted


class DeliveryAmbiguous(RuntimeError):
    """Submission may have started, so the caller must not resend."""


def ctl(*args: str, input_text: str | None = None) -> str:
    command = os.environ.get("AGTERMCTL", "agtermctl")
    result = subprocess.run(
        [command, *args],
        capture_output=True,
        check=False,
        input=input_text,
        text=True,
        timeout=30,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"agtermctl {' '.join(args)} failed: {detail}")
    return result.stdout


def window_option(window: str | None) -> tuple[str, ...]:
    return ("--window", window) if window else ()


def configured_selector(
    explicit: str | None,
    environment: str,
    label: str,
    default: str | None = None,
) -> str | None:
    """Resolve one explicit or environment selector without blank fallback."""
    raw = explicit if explicit is not None else os.environ.get(environment)
    if raw is None:
        return default
    value = raw.strip()
    if not value:
        raise RuntimeError(f"{label} selector is empty")
    return value


def tree(window: str | None = None) -> Any:
    return json.loads(ctl("tree", "--json", *window_option(window)))


def resolve_window(explicit: str | None) -> str:
    target = configured_selector(
        explicit, "AGTERM_WINDOW_ID", "window", "active"
    )
    assert target is not None
    payload = json.loads(ctl("window", "list", "--json"))
    windows = payload.get("result", {}).get("windows", [])
    if target.lower() == "active":
        matches = [item for item in windows if item.get("active")]
    else:
        exact = [
            item
            for item in windows
            if str(item.get("id", "")).lower() == target.lower()
        ]
        matches = exact or [
            item
            for item in windows
            if str(item.get("id", "")).lower().startswith(target.lower())
        ]
    if len(matches) != 1 or not matches[0].get("id"):
        detail = "ambiguous" if len(matches) > 1 else "not found"
        raise RuntimeError(f"agterm window {target!r} is {detail}")
    if not matches[0].get("open"):
        raise RuntimeError(f"agterm window {target!r} is not open")
    return str(matches[0]["id"])


def open_window_ids() -> list[str]:
    """Return every open window id for an explicit-session lookup."""
    payload = json.loads(ctl("window", "list", "--json"))
    return [
        str(item["id"])
        for item in payload.get("result", {}).get("windows", [])
        if item.get("open") and item.get("id")
    ]


def checkout_key(path: str) -> str:
    command = [
        "git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"
    ]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            check=False,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return os.path.realpath(path)
    if result.returncode == 0 and result.stdout.strip():
        return os.path.realpath(result.stdout.strip())
    return os.path.realpath(path)


def walk(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        if "id" in value and ("foreground" in value or "splitForeground" in value):
            yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def command_name(value: str) -> str:
    name = os.path.basename(value.strip())
    if not name or name in {".", ".."} or any(char.isspace() for char in name):
        raise ValueError("target command must be one executable name or path")
    return name


def target_profile(
    target: str, explicit_command: str | None, queue: bool = False
) -> Profile:
    profile = PROFILES[target]
    env_name = f"PEER_CHAT_{profile.agent.upper()}_COMMAND"
    configured = explicit_command or os.environ.get(env_name) or profile.command
    submit = "\t" if queue else profile.submit
    return replace(profile, command=command_name(configured), submit=submit)


def runs(foreground: Any, command: str) -> bool:
    if not isinstance(foreground, list):
        return False
    pattern = re.compile(rf"(?:^|[/\s]){re.escape(command)}(?:$|\s)")
    return any(pattern.search(str(part)) for part in foreground)


def has_target(info: dict[str, Any], profile: Profile) -> bool:
    if not info.get("hasSplit"):
        return False
    field = "foreground" if profile.pane == "left" else "splitForeground"
    return runs(info.get(field), profile.command)


def find_node(sid: str, window: str | None = None) -> dict[str, Any]:
    needle = sid.lower()
    matches = [
        info
        for info in walk(tree(window))
        if str(info.get("id", "")).lower().startswith(needle)
    ]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise RuntimeError(f"no such session: {sid}")
    raise RuntimeError(f"ambiguous session prefix {sid!r}")


def require_target(
    sid: str, profile: Profile, window: str | None = None
) -> str:
    info = find_node(sid, window)
    if not info.get("hasSplit"):
        raise RuntimeError(f"session {sid} has no split")
    if not has_target(info, profile):
        raise RuntimeError(
            f"{profile.agent} target pane is not running {profile.command!r}; "
            "for a wrapper, pass --target-command NAME"
        )
    return str(info["id"])


def resolve_session(
    explicit: str | None, profile: Profile, window: str | None = None
) -> str:
    sid = configured_selector(explicit, "AGTERM_SESSION_ID", "session")
    if sid:
        return require_target(sid, profile, window)
    wanted = checkout_key(os.getcwd())
    matches = [
        str(info["id"])
        for info in walk(tree(window))
        if has_target(info, profile)
        and info.get("cwd")
        and checkout_key(str(info["cwd"])) == wanted
    ]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise RuntimeError(
            "this checkout maps to no session running the expected "
            f"{profile.agent}-{profile.pane} layout; "
            "for a wrapper, pass --target-command NAME"
        )
    raise RuntimeError(
        "more than one session shares this checkout; pass --session ID or launch "
        "Codex with shell_environment_policy.set.AGTERM_SESSION_ID"
    )


def resolve_target(
    explicit_session: str | None,
    explicit_window: str | None,
    profile: Profile,
) -> tuple[str, str]:
    """Resolve one session and pin its owning window before any pane read."""
    session = configured_selector(
        explicit_session, "AGTERM_SESSION_ID", "session"
    )
    window_selector = (
        configured_selector(explicit_window, "AGTERM_WINDOW_ID", "window")
        if explicit_window is not None or explicit_session is None
        else None
    )
    if window_selector is not None:
        window = resolve_window(window_selector)
        return window, resolve_session(explicit_session, profile, window)
    if not session:
        window = resolve_window(None)
        return window, resolve_session(None, profile, window)

    needle = session.lower()
    matches: list[tuple[str, dict[str, Any]]] = []
    for window in open_window_ids():
        matches.extend(
            (window, info)
            for info in walk(tree(window))
            if str(info.get("id", "")).lower().startswith(needle)
        )
    if len(matches) > 1:
        raise RuntimeError(f"ambiguous session prefix {session!r}")
    if not matches:
        raise RuntimeError(f"no such session: {session}")
    window, info = matches[0]
    sid = str(info["id"])
    if not info.get("hasSplit"):
        raise RuntimeError(f"session {sid} has no split")
    if not has_target(info, profile):
        raise RuntimeError(
            f"{profile.agent} target pane is not running {profile.command!r}; "
            "for a wrapper, pass --target-command NAME"
        )
    return window, sid


def pane_text(
    sid: str, profile: Profile, window: str | None = None
) -> str:
    require_target(sid, profile, window)
    return _pane_text_unchecked(sid, profile, window)


def _pane_text_unchecked(
    sid: str, profile: Profile, window: str | None = None
) -> str:
    return ctl(
        "session",
        "text",
        "--pane",
        profile.pane,
        "--target",
        sid,
        "--lines",
        str(BOX_LINES),
        *window_option(window),
    )


def cursor_column(
    sid: str, profile: Profile, window: str | None = None
) -> int:
    require_target(sid, profile, window)
    return _cursor_column_unchecked(sid, profile, window)


def _cursor_column_unchecked(
    sid: str, profile: Profile, window: str | None = None
) -> int:
    value = ctl(
        "surface",
        "cursor",
        "--target",
        f"surface:{sid}:{profile.pane}",
        *window_option(window),
    ).strip()
    try:
        return int(value)
    except ValueError as err:
        raise RuntimeError(f"surface cursor returned {value!r}") from err


def type_text(
    sid: str, profile: Profile, text: str, window: str | None = None
) -> None:
    require_target(sid, profile, window)
    ctl(
        "session",
        "type",
        "--stdin",
        "--pane",
        profile.pane,
        "--target",
        sid,
        *window_option(window),
        input_text=text,
    )


def text_chunks(text: str, max_bytes: int = TYPE_CHUNK_BYTES) -> list[str]:
    """Split normalised text into independently observable input events."""
    max_bytes = max(4, min(TYPE_CHUNK_BYTES, max_bytes))
    chunks: list[str] = []
    current = ""
    tokens = re.findall(r" ?[^ ]+", text)
    for token in tokens:
        if len((current + token).encode("utf-8")) <= max_bytes:
            current += token
            continue
        if current:
            chunks.append(current)
            current = ""
        if len(token.encode("utf-8")) <= max_bytes:
            current = token
            continue

        piece: list[str] = []
        piece_bytes = 0
        for char in token:
            char_bytes = len(char.encode("utf-8"))
            if piece and piece_bytes + char_bytes > max_bytes:
                chunks.append("".join(piece))
                piece = []
                piece_bytes = 0
            piece.append(char)
            piece_bytes += char_bytes
        if piece:
            chunks.append("".join(piece))
    if current:
        chunks.append(current)
    return chunks


def composer_probe_marker(text: str) -> str:
    """Choose a short visible marker that cannot occur in this message."""
    index = 0
    while True:
        marker = f" [peer-check:{index:x}]"
        if marker not in text:
            return marker
        index += 1


def trailing_input_block(text: str) -> list[str]:
    lines = text.splitlines()[-BOX_LINES:]
    while lines and not lines[-1].strip():
        lines.pop()
    if lines and CODEX_FOOTER_RE.match(lines[-1]):
        lines.pop()
        while lines and not lines[-1].strip():
            lines.pop()
    start = len(lines)
    while start and lines[start - 1].strip():
        start -= 1
    return lines[start:]


def codex_live_prompt_text(text: str) -> str | None:
    block = trailing_input_block(text)
    if not block or any(CODEX_SHELL_PROMPT_RE.match(line) for line in block):
        return None
    match = CODEX_PROMPT_RE.match(block[0])
    if (
        not match
        or CODEX_CHOICE_RE.match(match.group(1))
        or any(not line[:1].isspace() for line in block[1:])
    ):
        return None
    content = [match.group(1), *(line.strip() for line in block[1:])]
    return "\n".join(part for part in content if part)


def claude_live_prompt_text(text: str) -> str | None:
    lines = text.splitlines()[-BOX_LINES:]
    for index in range(len(lines) - 1, -1, -1):
        match = CLAUDE_PROMPT_RE.match(lines[index])
        if not match:
            continue
        content = [match.group(1)]
        for offset, line in enumerate(lines[index + 1 :], start=index + 1):
            if RULE_RE.match(line):
                trailing = [item for item in lines[offset + 1 :] if item.strip()]
                if any(
                    not CLAUDE_FOOTER_RE.match(item)
                    or CODEX_CHOICE_RE.match(item.strip())
                    for item in trailing
                ):
                    return None
                return "\n".join(part for part in content if part)
            content.append(line.strip())
        if index == len(lines) - 1:
            return match.group(1)
        return None
    return None


def live_prompt_text(profile: Profile, text: str) -> str | None:
    if profile.agent == "codex":
        return codex_live_prompt_text(text)
    return claude_live_prompt_text(text)


def composer_is_empty(profile: Profile, content: str) -> bool:
    """Recognise the empty input content instead of inferring it from the caret."""
    if profile.agent == "codex":
        return " ".join(content.splitlines()) == CODEX_EMPTY_PROMPT
    return " ".join(content.splitlines()) in CLAUDE_EMPTY_PROMPTS


def composer_state(
    sid: str, profile: Profile, window: str | None = None
) -> tuple[str, int] | None:
    resolved = require_target(sid, profile, window)
    content = live_prompt_text(
        profile, _pane_text_unchecked(resolved, profile, window)
    )
    if content is None:
        return None
    return content, _cursor_column_unchecked(resolved, profile, window)


def wait_for_composer_change(
    sid: str,
    profile: Profile,
    previous: tuple[str, int],
    settle_delay: float,
    window: str | None = None,
) -> tuple[str, int] | None:
    """Wait for a changed composer state to remain stable."""
    deadline = time.monotonic() + PROBE_TIMEOUT
    stable_state: tuple[str, int] | None = None
    stable_since: float | None = None
    while True:
        state = composer_state(sid, profile, window)
        now = time.monotonic()
        if state is not None and state != previous:
            if state != stable_state:
                stable_state = state
                stable_since = now
            elif stable_since is not None and now - stable_since >= settle_delay:
                return state
        else:
            stable_state = None
            stable_since = None
        if now >= deadline:
            return None
        time.sleep(PROBE_INTERVAL)


def type_body(
    sid: str,
    profile: Profile,
    text: str,
    initial: tuple[str, int],
    window: str | None = None,
    progress: BodyProgress | None = None,
) -> tuple[str, int]:
    """Type bounded marked chunks, removing each marker before continuing."""
    if progress is None:
        progress = BodyProgress()
    marker = composer_probe_marker(text)
    chunks = text_chunks(text, TYPE_CHUNK_BYTES - len(marker.encode("utf-8")))
    state = initial
    expected = ""
    for index, chunk in enumerate(chunks):
        attempted = expected + chunk
        marked = attempted + marker
        progress.owned_text = marked
        try:
            try:
                type_text(sid, profile, chunk + marker, window)
                changed = wait_for_composer_change(
                    sid, profile, state, CHUNK_SETTLE_DELAY, window
                )
                if changed is None:
                    raise ComposerDirty(
                        f"message chunk {index + 1}/{len(chunks)} was typed but the "
                        "target composer did not confirm it; submit withheld",
                        marked,
                    )
                if not composer_has_expected_tail(
                    changed[0], marked, chunk + marker
                ):
                    raise ComposerDirty(
                        f"message chunk {index + 1}/{len(chunks)} is incomplete in "
                        "the target composer; submit withheld",
                        marked,
                    )
                type_text(sid, profile, "\x7f" * len(marker), window)
                settle_delay = (
                    COMPOSER_SETTLE_DELAY
                    if index == len(chunks) - 1
                    else CHUNK_SETTLE_DELAY
                )
                unmarked = wait_for_composer_change(
                    sid, profile, changed, settle_delay, window
                )
                if unmarked is None or marker in unmarked[0]:
                    raise ComposerDirty(
                        f"message marker after chunk {index + 1}/{len(chunks)} was "
                        "not confirmably removed; submit withheld",
                        marked,
                    )
                if not composer_has_expected_tail(unmarked[0], attempted, chunk):
                    raise ComposerDirty(
                        f"message chunk {index + 1}/{len(chunks)} changed during "
                        "marker removal; submit withheld",
                        marked,
                    )
                progress.owned_text = attempted
            except ComposerDirty:
                raise
            except (
                OSError,
                subprocess.SubprocessError,
                ValueError,
                RuntimeError,
            ) as err:
                raise ComposerDirty(
                    f"message chunk {index + 1}/{len(chunks)} failed after its body "
                    f"write started: {err}; submit withheld",
                    marked,
                ) from err
        except KeyboardInterrupt as err:
            raise ComposerDirty(
                f"interrupted during message chunk {index + 1}/{len(chunks)}; "
                "submit withheld",
                marked,
                interrupted=True,
            ) from err
        expected = attempted
        state = unmarked
    return state


def composer_has_expected_tail(
    content: str,
    expected: str,
    chunk: str,
) -> bool:
    """Match a source suffix while allowing visual line wrapping."""
    positions = {len(expected)}
    rows = content.splitlines() or [content]
    for index in range(len(rows) - 1, -1, -1):
        row = rows[index]
        matched = {
            end - len(row)
            for end in positions
            if end >= len(row) and expected[end - len(row) : end] == row
        }
        if not matched:
            return False
        if index:
            # Plain screen text omits a source space consumed by visual wrapping.
            positions = matched | {
                start - 1
                for start in matched
                if start and expected[start - 1] == " "
            }
        else:
            positions = matched
    probe_start = max(0, len(expected) - len(chunk) - CHUNK_VERIFY_OVERLAP)
    matching_starts = {start for start in positions if start <= probe_start}
    if not matching_starts:
        return False
    if 0 in matching_starts:
        return True
    return not chunk_tail_is_ambiguous(expected, chunk)


def chunk_tail_is_ambiguous(expected: str, chunk: str) -> bool:
    """Reject a clipped tail that could hide a deletion from this chunk."""
    if not chunk:
        return False
    expected_length = len(expected)
    chunk_length = len(chunk)
    visible_length = min(
        expected_length, chunk_length + CHUNK_VERIFY_OVERLAP
    )
    chunk_start = expected_length - chunk_length
    for missing_start in range(chunk_start, expected_length):
        for missing_end in range(missing_start + 1, expected_length + 1):
            missing_length = missing_end - missing_start
            earlier_start = expected_length - missing_length - visible_length
            if earlier_start < 0:
                continue
            if (
                expected[earlier_start:missing_start]
                == expected[expected_length - visible_length : missing_end]
            ):
                return True
    return False


def composer_owned_spans(
    content: str, owned_text: str, allowed_ends: set[int]
) -> set[tuple[int, int]]:
    """Locate visible contiguous owned text ending at an allowed prefix boundary."""
    if not content:
        return {
            (end - 1, end)
            for end in allowed_ends
            if end == 1 and owned_text[:end] == " "
        }
    valid_ends = {end for end in allowed_ends if 0 < end <= len(owned_text)}
    positions = {(end, end) for end in valid_ends}
    positions.update(
        (end - 1, end) for end in valid_ends if owned_text[end - 1] == " "
    )
    rows = content.splitlines() or [content]
    for index in range(len(rows) - 1, -1, -1):
        row = rows[index]
        matched = {
            (position - len(row), end)
            for position, end in positions
            if position >= len(row)
            and owned_text[position - len(row) : position] == row
        }
        if not matched:
            return set()
        if index:
            positions = matched | {
                (start - 1, end)
                for start, end in matched
                if start and owned_text[start - 1] == " "
            }
        else:
            positions = matched
    return positions


def wait_for_cleanup_state(
    sid: str,
    profile: Profile,
    previous: tuple[str, int] | None,
    owned_text: str,
    allowed_ends: set[int],
    window: str | None = None,
    accept_empty: bool = True,
) -> tuple[tuple[str, int], set[tuple[int, int]]] | None:
    """Wait for a backspace batch to reach a stable observable state."""
    deadline = time.monotonic() + PROBE_TIMEOUT
    stable: tuple[
        tuple[str, int] | None, frozenset[tuple[int, int]]
    ] | None = None
    stable_since: float | None = None
    while True:
        state = composer_state(sid, profile, window)
        now = time.monotonic()
        is_empty = state is not None and (
            state[1] == EMPTY_CURSOR_COLUMN
            and composer_is_empty(profile, state[0])
        )
        if is_empty and accept_empty:
            return state, set()
        spans = (
            composer_owned_spans(state[0], owned_text, allowed_ends)
            if state is not None
            else set()
        )
        if state == previous or (is_empty and not accept_empty):
            stable = None
            stable_since = None
        else:
            candidate = state, frozenset(spans)
            if candidate != stable:
                stable = candidate
                stable_since = now
            elif (
                stable_since is not None
                and now - stable_since >= CHUNK_SETTLE_DELAY
            ):
                if state is None:
                    return None
                return state, spans
        if now >= deadline:
            return None
        time.sleep(PROBE_INTERVAL)


def clear_composer(
    sid: str,
    profile: Profile,
    initial: tuple[str, int],
    owned_text: str,
    window: str | None = None,
) -> bool:
    """Backspace text owned by this send without interrupting an active turn."""
    allowed_ends = set(range(1, len(owned_text) + 1))
    settled = wait_for_cleanup_state(
        sid,
        profile,
        initial,
        owned_text,
        allowed_ends,
        window,
        accept_empty=False,
    )
    if settled is None:
        return False
    state, spans = settled
    while True:
        if state == initial or (
            state[1] == EMPTY_CURSOR_COLUMN
            and composer_is_empty(profile, state[0])
        ):
            return True
        if not spans:
            return False
        previous_end = max(end for _, end in spans)
        delete_count = min(
            TYPE_CHUNK_BYTES, min(end - start for start, end in spans)
        )
        if not delete_count:
            return False
        type_text(sid, profile, "\x7f" * delete_count, window)
        next_ends = {
            candidate
            for _, end in spans
            for candidate in range(end - delete_count, end)
        }
        settled = wait_for_cleanup_state(
            sid, profile, state, owned_text, next_ends, window
        )
        if settled is None:
            return False
        state, spans = settled
        if (
            state[1] == EMPTY_CURSOR_COLUMN
            and composer_is_empty(profile, state[0])
        ):
            return True
        if not spans:
            return False
        if max(end for _, end in spans) >= previous_end:
            return False
        allowed_ends = {end for _, end in spans}


def wait_for_accepted(
    sid: str,
    profile: Profile,
    composed: tuple[str, int],
    window: str | None = None,
) -> bool:
    """Wait until submission clears the composed state and restores column 2."""
    deadline = time.monotonic() + PROBE_TIMEOUT
    stable_state: tuple[str, int] | None = None
    stable_since: float | None = None
    while True:
        state = composer_state(sid, profile, window)
        now = time.monotonic()
        accepted = (
            state is not None
            and state[1] == EMPTY_CURSOR_COLUMN
            and state[0] != composed[0]
            and composer_is_empty(profile, state[0])
        )
        if accepted:
            if state != stable_state:
                stable_state = state
                stable_since = now
            elif (
                stable_since is not None
                and now - stable_since >= CHUNK_SETTLE_DELAY
            ):
                return True
        else:
            stable_state = None
            stable_since = None
        if now >= deadline:
            return False
        time.sleep(PROBE_INTERVAL)


def normalize(profile: Profile, message: str) -> str:
    line = " ".join(message.split())
    if any(unicodedata.category(char) == "Cc" for char in line):
        raise ValueError("chat message contains a control character")
    prefix = profile.label.strip()
    while line.lower().startswith(prefix.lower()):
        line = line[len(prefix) :].lstrip(": ").strip()
    if not line:
        raise ValueError("chat message is empty")
    return profile.label + line


def raise_after_composer_dirty(
    sid: str,
    profile: Profile,
    initial: tuple[str, int],
    dirty: ComposerDirty,
    window: str | None = None,
) -> None:
    """Attempt guarded cleanup, then raise with the resulting composer state."""
    try:
        cleared = clear_composer(
            sid, profile, initial, dirty.owned_text, window
        )
    except KeyboardInterrupt as cleanup_err:
        raise KeyboardInterrupt(
            f"{dirty}; composer cleanup interrupted"
        ) from cleanup_err
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError):
        cleared = False
    detail = "composer cleared" if cleared else "composer cleanup failed"
    if dirty.interrupted:
        raise KeyboardInterrupt(f"{dirty}; {detail}") from dirty
    raise ComposerDirty(f"{dirty}; {detail}", dirty.owned_text) from dirty


def send(
    sid: str,
    profile: Profile,
    message: str,
    window: str | None = None,
    prepared: str | None = None,
    delivery: DeliveryProgress | None = None,
) -> int:
    if prepared is None:
        try:
            typed = normalize(profile, message)
        except KeyboardInterrupt as err:
            raise KeyboardInterrupt(
                "interrupted during message normalisation; nothing was typed"
            ) from err
    else:
        typed = prepared
    try:
        pane = pane_text(sid, profile, window)
        empty_text = live_prompt_text(profile, pane)
        if empty_text is None:
            raise PromptBlocked(
                "target composer prompt is not recognisable (shell mode, disabled "
                "input, a trailing modal or status row, or an unknown prompt glyph); "
                "nothing was typed"
            )
        if not composer_is_empty(profile, empty_text):
            raise PromptBlocked(
                "target composer contains text; nothing was typed"
            )
        if cursor_column(sid, profile, window) != EMPTY_CURSOR_COLUMN:
            raise PromptBlocked(
                "target composer is not confirmably empty; nothing was typed"
            )
    except PromptBlocked:
        raise
    except KeyboardInterrupt as err:
        raise KeyboardInterrupt(
            "interrupted during pre-write checks; nothing was typed"
        ) from err
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as err:
        raise RuntimeError(
            f"pre-write check failed; nothing was typed: {err}"
        ) from err

    initial = (empty_text, EMPTY_CURSOR_COLUMN)
    if delivery is not None:
        delivery.phase = "started"
    phase = "body"
    progress = BodyProgress()
    try:
        try:
            composed = type_body(
                sid, profile, typed, initial, window, progress
            )
            before_submit = composer_state(sid, profile, window)
            if before_submit != composed:
                raise ComposerDirty(
                    "target composer changed before submit; submit withheld",
                    typed,
                )
            # Enter the ambiguous phase before Return, so an interrupt at either call
            # boundary cannot be mistaken for a safe pre-submit failure.
            phase = "submit"
            type_text(sid, profile, profile.submit, window)
            phase = "accept"
            accepted = wait_for_accepted(sid, profile, composed, window)
            if not accepted:
                raise DeliveryAmbiguous(
                    "target did not confirm submission; delivery is ambiguous; "
                    "do not resend"
                )
            return len(message)
        except ComposerDirty as err:
            raise_after_composer_dirty(sid, profile, initial, err, window)
        except DeliveryAmbiguous:
            raise
        except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as err:
            if phase == "body":
                dirty = ComposerDirty(
                    f"final composer check failed: {err}; submit withheld",
                    progress.owned_text,
                )
                raise_after_composer_dirty(
                    sid, profile, initial, dirty, window
                )
            if phase == "submit":
                detail = "submit request failed"
            else:
                detail = "submission confirmation failed"
            raise RuntimeError(
                f"{detail}; delivery is ambiguous; do not resend: {err}"
            ) from err
    except KeyboardInterrupt as err:
        if phase == "body":
            if "; composer " in str(err):
                raise
            dirty = ComposerDirty(
                "interrupted after the message body transaction started; "
                "submit withheld",
                progress.owned_text,
                interrupted=True,
            )
            raise_after_composer_dirty(sid, profile, initial, dirty, window)
        if phase == "submit":
            detail = "submit request was interrupted"
        else:
            detail = "submission confirmation was interrupted"
        raise KeyboardInterrupt(
            f"{detail}; delivery is ambiguous; do not resend"
        ) from err


def send_with_retry(
    sid: str,
    profile: Profile,
    message: str,
    window: str | None = None,
    progress: DeliveryProgress | None = None,
) -> int:
    """Retry only a pre-write occupied-composer refusal."""
    delivery = progress if progress is not None else DeliveryProgress()
    try:
        prepared = normalize(profile, message)
    except KeyboardInterrupt as err:
        raise KeyboardInterrupt(
            "interrupted during message normalisation; nothing was typed"
        ) from err
    try:
        for attempt in range(1, RETRY_ATTEMPTS + 1):
            try:
                return send(sid, profile, message, window, prepared, delivery)
            except PromptBlocked as err:
                if attempt == RETRY_ATTEMPTS:
                    raise PromptBlocked(
                        f"{err} after {RETRY_ATTEMPTS} attempts"
                    ) from err
                print(
                    f"peer-chat: attempt {attempt}/{RETRY_ATTEMPTS} blocked; "
                    f"retrying in {RETRY_DELAY:g}s: {err}",
                    file=sys.stderr,
                    flush=True,
                )
                time.sleep(RETRY_DELAY)
        raise AssertionError("unreachable")
    except KeyboardInterrupt as wait_err:
        if delivery.phase == "not_started":
            raise KeyboardInterrupt(
                "interrupted while handling a pre-write refusal; "
                "nothing was typed"
            ) from wait_err
        raise


def message_name(value: str) -> str:
    if not MESSAGE_NAME_RE.fullmatch(value):
        raise argparse.ArgumentTypeError(
            "message name must match peer-chat-<sender>-<suffix>.txt"
        )
    return value


def selector_argument(value: str) -> str:
    selector = value.strip()
    if not selector:
        raise argparse.ArgumentTypeError("selector must not be empty")
    return selector


def private_spool_fd(create: bool) -> int:
    if create:
        try:
            MESSAGE_SPOOL.mkdir(mode=0o700)
        except FileExistsError:
            pass
    spool_fd = os.open(
        MESSAGE_SPOOL,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    info = os.fstat(spool_fd)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        os.close(spool_fd)
        raise ValueError("message spool must be a private directory owned by this user")
    if stat.S_IMODE(info.st_mode) & 0o077:
        os.close(spool_fd)
        raise ValueError(
            f"message spool is accessible by other users; run chmod 700 {MESSAGE_SPOOL}"
        )
    return spool_fd


def prepare_message(name: str) -> Path:
    spool_fd = private_spool_fd(create=True)
    try:
        message_fd = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=spool_fd,
        )
        os.fchmod(message_fd, 0o600)
        os.close(message_fd)
    finally:
        os.close(spool_fd)
    return MESSAGE_SPOOL / name


def read_message(use_stdin: bool, message_file: str | None) -> str:
    if use_stdin:
        binary = getattr(sys.stdin, "buffer", None)
        if binary is not None:
            body = binary.read(MAX_MESSAGE_BYTES + 1)
            if len(body) > MAX_MESSAGE_BYTES:
                raise ValueError(f"stdin message exceeds {MAX_MESSAGE_BYTES} bytes")
            return body.decode("utf-8")

        message = sys.stdin.read(MAX_MESSAGE_BYTES + 1)
        if len(message.encode("utf-8")) > MAX_MESSAGE_BYTES:
            raise ValueError(f"stdin message exceeds {MAX_MESSAGE_BYTES} bytes")
        return message
    if message_file is None:
        raise ValueError("provide --stdin or --message-file NAME")

    spool_fd = private_spool_fd(create=False)
    message_fd = -1
    try:
        message_fd = os.open(
            message_file,
            os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=spool_fd,
        )
        info = os.fstat(message_fd)
        entry = os.stat(message_file, dir_fd=spool_fd, follow_symlinks=False)
        same_entry = (entry.st_dev, entry.st_ino) == (info.st_dev, info.st_ino)
        is_owned_regular = (
            same_entry
            and stat.S_ISREG(info.st_mode)
            and info.st_uid == os.getuid()
            and info.st_nlink == 1
        )
        if is_owned_regular:
            os.unlink(message_file, dir_fd=spool_fd)
        if not is_owned_regular:
            raise ValueError("message file must be an owned regular file with one link")
        if stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError(
                "message file is accessible by other users and was consumed; "
                "run --prepare-message again"
            )
        if info.st_size > MAX_MESSAGE_BYTES:
            raise ValueError(
                f"message file exceeds {MAX_MESSAGE_BYTES} bytes and was consumed; "
                "run --prepare-message again"
            )

        with os.fdopen(message_fd, encoding="utf-8") as stream:
            message_fd = -1
            message = stream.read(MAX_MESSAGE_BYTES + 1)
        if len(message.encode("utf-8")) > MAX_MESSAGE_BYTES:
            raise ValueError(
                f"message file exceeds {MAX_MESSAGE_BYTES} bytes and was consumed; "
                "run --prepare-message again"
            )
        return message
    finally:
        if message_fd >= 0:
            os.close(message_fd)
        os.close(spool_fd)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--to", choices=PROFILES)
    parser.add_argument("--session", type=selector_argument)
    parser.add_argument(
        "--window",
        type=selector_argument,
        help="agterm window id or prefix (defaults to AGTERM_WINDOW_ID)",
    )
    parser.add_argument(
        "--target-command",
        type=command_name,
        metavar="NAME",
        help="target agent executable or wrapper name",
    )
    parser.add_argument(
        "--queue",
        action="store_true",
        help="queue a Codex message with Tab instead of steering with Return",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--stdin", action="store_true")
    source.add_argument(
        "--message-file",
        type=message_name,
        metavar="NAME",
        help="consume a prepared UTF-8 message from the private spool",
    )
    source.add_argument(
        "--prepare-message",
        type=message_name,
        metavar="NAME",
        help="create a private one-shot message file and print its path",
    )
    args = parser.parse_args(argv)
    if args.prepare_message:
        if args.to or args.session or args.window or args.target_command or args.queue:
            parser.error("--prepare-message does not accept target options")
    elif not args.to:
        parser.error("--to is required when sending")
    elif args.queue and args.to != "codex":
        parser.error("--queue is available only with --to codex")
    return args


def report_success(sent: int) -> None:
    """Emit the machine-readable receipt after delivery was confirmed."""
    print(json.dumps({"sent": sent}), flush=True)


def run_main(progress: DeliveryProgress) -> int:
    """Run one CLI operation inside main's outer signal boundary."""
    args = parse_args()
    if args.prepare_message:
        path = prepare_message(args.prepare_message)
        print(json.dumps({"messageFile": str(path)}))
        return 0
    profile = target_profile(args.to, args.target_command, args.queue)
    window, sid = resolve_target(args.session, args.window, profile)
    message = read_message(args.stdin, args.message_file)
    sent = send_with_retry(sid, profile, message, window, progress)
    progress.phase = "confirmed"
    report_success(sent)
    return 0


def main() -> int:
    progress = DeliveryProgress()
    try:
        return run_main(progress)
    except KeyboardInterrupt as err:
        detail_text = str(err)
        if not detail_text and progress.phase == "confirmed":
            detail_text = (
                "delivery was confirmed; do not resend; success report interrupted"
            )
        elif not detail_text and progress.phase == "started":
            detail_text = "delivery status is unavailable; do not resend"
        elif not detail_text and progress.phase == "not_started":
            detail_text = "nothing was typed"
        detail = f": {detail_text}" if detail_text else ""
        print(f"peer-chat: interrupted{detail}", file=sys.stderr)
        return 130
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as err:
        if progress.phase == "confirmed":
            print(
                "peer-chat: delivery was confirmed; do not resend; "
                f"success report failed: {err}",
                file=sys.stderr,
            )
            return 1
        print(f"peer-chat: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
