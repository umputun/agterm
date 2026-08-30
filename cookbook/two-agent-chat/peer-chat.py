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
from collections.abc import Iterator
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

SUBMIT_DELAY = 0.15
# A long body takes longer than half a second to land and render in the composer.
PROBE_TIMEOUT = 2.0
RETRY_ATTEMPTS = 5
RETRY_DELAY = 10.0
BOX_LINES = 40
EMPTY_CURSOR_COLUMN = 2
MIN_WRAPPED_PROBE = 40
MAX_MESSAGE_BYTES = 64 * 1024
# Claude can put a short context label inside the top composer rule, for example `e2e`.
RULE_RE = re.compile(r"^\s*[─\u2014-]{10,}(?:\s+[^─\u2014-].*?\s+[─\u2014-]+)?\s*$")
# Codex draws the composer prompt as `›`; with reasoning effort set to ultra it upgrades
# the glyph to `»` (codex-rs/tui/src/bottom_pane/effort_ignition.rs). Both prompt patterns
# are anchored at column zero so prompt-shaped output cannot be mistaken for live input.
# Shell mode shows `!` and is deliberately not matched, so nothing is ever typed there.
CODEX_PROMPT_RE = re.compile(r"^[›»][\s ]*(.*?)\s*$")
CODEX_SHELL_PROMPT_RE = re.compile(r"^![\s ]*(.*?)\s*$")
# Codex prefixes footer rows with two spaces. Only the final row is stripped: a
# multi-row shortcut overlay is indistinguishable from indented modal choices and
# therefore fails closed instead of weakening the live-prompt guard.
CODEX_FOOTER_RE = re.compile(r"^ {2}\S.*$")
CLAUDE_PROMPT_RE = re.compile(r"^\s*❯[\s ]*(.*?)\s*$")
PASTED_RE = re.compile(r"\[Pasted Content \d+ chars?\]")
# loose on purpose: Claude draws "[Pasted text #16]" and "[Pasted text #1 +12 lines]", and a
# precise pattern would refuse an unseen variant. The body fragment below is what proves
# whose content the box holds.
PASTED_TEXT_RE = re.compile(r"^\[Pasted text #\d+[^\]]*\]")
MESSAGE_FRAGMENT = 20
MESSAGE_NAME_RE = re.compile(r"peer-chat-[a-z0-9][a-z0-9-]{2,48}\.txt")
MESSAGE_SPOOL = Path(tempfile.gettempdir()) / f"agterm-peer-chat-{os.getuid()}"


@dataclass(frozen=True)
class Profile:
    pane: str
    agent: str
    command: str
    label: str
    submit: str


PROFILES = {
    "claude": Profile("left", "claude", "claude", "Chat from Codex: ", "\n"),
    "codex": Profile("right", "codex", "codex", "Chat from Claude: ", "\t"),
}


class PromptBlocked(RuntimeError):
    """The target prompt is occupied before any text was written."""


def ctl(*args: str) -> str:
    command = os.environ.get("AGTERMCTL", "agtermctl")
    result = subprocess.run(
        [command, *args],
        capture_output=True,
        check=False,
        text=True,
        timeout=30,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"agtermctl {' '.join(args)} failed: {detail}")
    return result.stdout


def tree() -> Any:
    return json.loads(ctl("tree", "--json"))


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


def target_profile(target: str, explicit_command: str | None) -> Profile:
    profile = PROFILES[target]
    env_name = f"PEER_CHAT_{profile.agent.upper()}_COMMAND"
    configured = explicit_command or os.environ.get(env_name) or profile.command
    return replace(profile, command=command_name(configured))


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


def find_node(sid: str) -> dict[str, Any]:
    needle = sid.lower()
    matches = [
        info
        for info in walk(tree())
        if str(info.get("id", "")).lower().startswith(needle)
    ]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise RuntimeError(f"no such session: {sid}")
    raise RuntimeError(f"ambiguous session prefix {sid!r}")


def require_target(sid: str, profile: Profile) -> str:
    info = find_node(sid)
    if not info.get("hasSplit"):
        raise RuntimeError(f"session {sid} has no split")
    if not has_target(info, profile):
        raise RuntimeError(
            f"{profile.agent} target pane is not running {profile.command!r}; "
            "for a wrapper, pass --target-command NAME"
        )
    return str(info["id"])


def resolve_session(explicit: str | None, profile: Profile) -> str:
    sid = explicit or os.environ.get("AGTERM_SESSION_ID")
    if sid:
        return require_target(sid, profile)
    wanted = checkout_key(os.getcwd())
    matches = [
        str(info["id"])
        for info in walk(tree())
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


def pane_text(sid: str, profile: Profile) -> str:
    require_target(sid, profile)
    return ctl(
        "session",
        "text",
        "--pane",
        profile.pane,
        "--target",
        sid,
        "--lines",
        str(BOX_LINES),
    )


def cursor_column(sid: str, profile: Profile) -> int:
    require_target(sid, profile)
    value = ctl(
        "surface",
        "cursor",
        "--target",
        f"surface:{sid}:{profile.pane}",
    ).strip()
    try:
        return int(value)
    except ValueError as err:
        raise RuntimeError(f"surface cursor returned {value!r}") from err


def type_text(sid: str, profile: Profile, text: str) -> None:
    require_target(sid, profile)
    ctl(
        "session",
        "type",
        text,
        "--pane",
        profile.pane,
        "--target",
        sid,
    )


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


def codex_prompt_text(text: str) -> str | None:
    content = None
    for line in trailing_input_block(text):
        if CODEX_SHELL_PROMPT_RE.match(line):
            content = None
        if match := CODEX_PROMPT_RE.match(line):
            content = match.group(1)
    return content


def codex_live_prompt_text(text: str) -> str | None:
    block = trailing_input_block(text)
    if not block or any(CODEX_SHELL_PROMPT_RE.match(line) for line in block):
        return None
    match = CODEX_PROMPT_RE.match(block[-1])
    return match.group(1) if match else None


def claude_prompt_text(text: str) -> str | None:
    lines = text.splitlines()[-BOX_LINES:]
    for index in range(len(lines) - 1, -1, -1):
        match = CLAUDE_PROMPT_RE.match(lines[index])
        if not match:
            continue
        content = [match.group(1)]
        for line in lines[index + 1 :]:
            if RULE_RE.match(line):
                break
            content.append(line.strip())
        return " ".join(part for part in content if part)
    return None


def claude_live_prompt_text(text: str) -> str | None:
    lines = text.splitlines()[-BOX_LINES:]
    for index in range(len(lines) - 1, -1, -1):
        match = CLAUDE_PROMPT_RE.match(lines[index])
        if not match:
            continue
        content = [match.group(1)]
        for line in lines[index + 1 :]:
            if RULE_RE.match(line):
                return " ".join(part for part in content if part)
            content.append(line.strip())
        if index == len(lines) - 1:
            return match.group(1)
        return None
    return None


def prompt_text(profile: Profile, text: str) -> str | None:
    if profile.agent == "codex":
        return codex_prompt_text(text)
    return claude_prompt_text(text)


def live_prompt_text(profile: Profile, text: str) -> str | None:
    if profile.agent == "codex":
        return codex_live_prompt_text(text)
    return claude_live_prompt_text(text)


def normalize(profile: Profile, message: str) -> str:
    line = " ".join(message.split())
    prefix = profile.label.strip()
    while line.lower().startswith(prefix.lower()):
        line = line[len(prefix) :].lstrip(": ").strip()
    if not line:
        raise ValueError("chat message is empty")
    return profile.label + line


def composer_has_message(profile: Profile, content: str, typed: str) -> bool:
    pasted = bool(PASTED_RE.fullmatch(content))
    if profile.agent == "claude":
        shown = " ".join(content.split())
        sent = " ".join(typed.split())
        label = profile.label.strip()
        if not sent.startswith(label):
            return False
        if not (shown.startswith(label) or PASTED_TEXT_RE.match(shown)):
            return False

        body = sent[len(label) :].lstrip()
        if not body:
            return False
        if shown.startswith(label):
            return body[:MESSAGE_FRAGMENT] in shown

        fragment_len = min(MESSAGE_FRAGMENT, len(body))
        return any(
            body[start : start + fragment_len] in shown
            for start in range(len(body) - fragment_len + 1)
        )
    required = min(len(typed), MIN_WRAPPED_PROBE)
    literal = typed.startswith(content) and len(content) >= required
    return literal or pasted


def wait_for_composed(sid: str, profile: Profile, typed: str) -> str | None:
    deadline = time.monotonic() + PROBE_TIMEOUT
    while True:
        content = prompt_text(profile, pane_text(sid, profile))
        if content and composer_has_message(profile, content, typed):
            return content
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.1)


def wait_for_accepted(sid: str, profile: Profile, held: str) -> bool:
    deadline = time.monotonic() + PROBE_TIMEOUT
    while True:
        content = prompt_text(profile, pane_text(sid, profile))
        if content is None or content != held:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)


def send(sid: str, profile: Profile, message: str) -> int:
    typed = normalize(profile, message)
    pane = pane_text(sid, profile)
    if live_prompt_text(profile, pane) is None:
        raise PromptBlocked(
            "target composer prompt is not recognisable (shell mode, disabled input, a "
            "trailing modal or status row, or an unknown prompt glyph); nothing was typed"
        )
    if cursor_column(sid, profile) != EMPTY_CURSOR_COLUMN:
        raise PromptBlocked("target composer is not confirmably empty; nothing was typed")

    if profile.agent == "claude":
        # Type the routing label on its own so it stays visible when Claude compacts the
        # body into a paste marker.
        type_text(sid, profile, profile.label)
        type_text(sid, profile, typed[len(profile.label) :])
    else:
        type_text(sid, profile, typed)
    held = wait_for_composed(sid, profile, typed)
    if held is None:
        raise RuntimeError(
            "message was typed but not verified in the target composer; submit withheld"
        )

    time.sleep(SUBMIT_DELAY)
    type_text(sid, profile, profile.submit)
    if not wait_for_accepted(sid, profile, held):
        raise RuntimeError("target did not accept the message; it may remain composed")
    return len(message)


def send_with_retry(sid: str, profile: Profile, message: str) -> int:
    """Retry only a pre-write occupied-composer refusal."""
    for attempt in range(1, RETRY_ATTEMPTS + 1):
        try:
            return send(sid, profile, message)
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


def message_name(value: str) -> str:
    if not MESSAGE_NAME_RE.fullmatch(value):
        raise argparse.ArgumentTypeError(
            "message name must match peer-chat-<sender>-<suffix>.txt"
        )
    return value


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
        return sys.stdin.read()
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
    parser.add_argument("--session")
    parser.add_argument(
        "--target-command",
        type=command_name,
        metavar="NAME",
        help="target agent executable or wrapper name",
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
        if args.to or args.session or args.target_command:
            parser.error("--prepare-message does not accept target options")
    elif not args.to:
        parser.error("--to is required when sending")
    return args


def main() -> int:
    args = parse_args()
    try:
        if args.prepare_message:
            path = prepare_message(args.prepare_message)
            print(json.dumps({"messageFile": str(path)}))
            return 0
        profile = target_profile(args.to, args.target_command)
        sid = resolve_session(args.session, profile)
        message = read_message(args.stdin, args.message_file)
        sent = send_with_retry(sid, profile, message)
        print(json.dumps({"sent": sent}))
        return 0
    except KeyboardInterrupt:
        print("peer-chat: interrupted", file=sys.stderr)
        return 130
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as err:
        print(f"peer-chat: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
