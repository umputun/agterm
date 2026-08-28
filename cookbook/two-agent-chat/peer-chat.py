#!/usr/bin/env python3
"""Send one peer-chat message between Claude Code and Codex in an agterm split."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Iterator
from dataclasses import dataclass, replace
from typing import Any

SUBMIT_DELAY = 0.15
PROBE_TIMEOUT = 0.6
RETRY_ATTEMPTS = 5
RETRY_DELAY = 10.0
BOX_LINES = 40
EMPTY_CURSOR_COLUMN = 2
MIN_WRAPPED_PROBE = 40
# Claude can put a short context label inside the top composer rule, for example `e2e`.
RULE_RE = re.compile(r"^\s*[─\u2014-]{10,}(?:\s+[^─\u2014-].*?\s+[─\u2014-]+)?\s*$")
CODEX_PROMPT_RE = re.compile(r"^\s*›[\s ]*(.*?)\s*$")
CLAUDE_PROMPT_RE = re.compile(r"^\s*❯[\s ]*(.*?)\s*$")
PASTED_RE = re.compile(r"\[Pasted Content \d+ chars?\]")


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


def codex_prompt_text(text: str) -> str | None:
    for line in reversed(text.splitlines()[-BOX_LINES:]):
        if match := CODEX_PROMPT_RE.match(line):
            return match.group(1)
    return None


def claude_prompt_text(text: str) -> str | None:
    lines = text.splitlines()[-BOX_LINES:]
    for index in range(len(lines) - 1, 0, -1):
        match = CLAUDE_PROMPT_RE.match(lines[index])
        if not match or not RULE_RE.match(lines[index - 1]):
            continue
        if any(RULE_RE.match(line) for line in lines[index + 1 :]):
            return match.group(1)
    return None


def prompt_text(profile: Profile, text: str) -> str | None:
    if profile.agent == "codex":
        return codex_prompt_text(text)
    return claude_prompt_text(text)


def normalize(profile: Profile, message: str) -> str:
    line = " ".join(message.split())
    prefix = profile.label.strip()
    while line.lower().startswith(prefix.lower()):
        line = line[len(prefix) :].lstrip(": ").strip()
    if not line:
        raise ValueError("chat message is empty")
    return profile.label + line


def composer_has_message(profile: Profile, content: str, typed: str) -> bool:
    if profile.agent == "claude":
        return content.startswith(profile.label)
    required = min(len(typed), MIN_WRAPPED_PROBE)
    literal = typed.startswith(content) and len(content) >= required
    return literal or bool(PASTED_RE.fullmatch(content))


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
    if cursor_column(sid, profile) != EMPTY_CURSOR_COLUMN:
        raise PromptBlocked("target composer is not confirmably empty; nothing was typed")

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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--to", choices=PROFILES, required=True)
    parser.add_argument("--session")
    parser.add_argument(
        "--target-command",
        type=command_name,
        metavar="NAME",
        help="target agent executable or wrapper name",
    )
    parser.add_argument("--stdin", action="store_true", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        profile = target_profile(args.to, args.target_command)
        sid = resolve_session(args.session, profile)
        sent = send_with_retry(sid, profile, sys.stdin.read())
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
