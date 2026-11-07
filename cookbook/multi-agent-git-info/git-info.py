#!/usr/bin/env python3
"""Publish one Git snapshot for the top-level agents in an agterm session."""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def run(args: list[str]) -> str:
    """Bound external reads and keep hook output out of the conversation."""
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=1).stdout


def owner() -> tuple[int, str] | None:
    """Reject nested agents and an ancestry that cannot establish ownership."""
    pid = os.getppid()
    agents = []
    for _ in range(16):
        parent, command = run(["ps", "-p", str(pid), "-o", "ppid=,comm="]).strip().split(None, 1)
        name = Path(command).name
        if name in {"claude", "codex"}:
            agents.append((pid, name))
        if name in {"login", "agterm", "agterm-session-host"} or int(parent) <= 1:
            break
        pid = int(parent)
    else:
        return None
    return agents[0] if len(agents) == 1 else None


def plain(text: str, limit: int) -> str:
    """Keep Git-controlled names within the sidebar's text and byte constraints."""
    text = "".join(char for char in text if char.isprintable())
    encoded = text.encode()
    return text if len(encoded) <= limit else encoded[: limit - 3].decode(errors="ignore") + "…"


def codex_root(event: dict[str, Any]) -> bool:
    # In-process subagents have the same ancestry as their parent, but a different session source.
    if not event.get("transcript_path"):
        return False
    with Path(event["transcript_path"]).open() as transcript:
        metadata = json.loads(transcript.readline())
    payload = metadata.get("payload", {})
    return (
        metadata.get("type") == "session_meta"
        and payload.get("source") == "cli"
        and payload.get("id") == event.get("session_id")
    )


def parse_status(records: list[str]) -> tuple[dict[str, str], int]:
    headers = {}
    changed = 0
    entries = iter(records)
    for record in entries:
        if record.startswith("# "):
            key, _, value = record[2:].partition(" ")
            headers[key] = value
        elif record.startswith(("1 ", "2 ", "u ", "? ")):
            changed += 1
            if record.startswith("2 "):
                next(entries, None)
    return headers, changed


def snapshot(cwd: str) -> tuple[str, str] | None:
    """Count porcelain records without treating rename paths as changed files."""
    try:
        root = run(["git", "-C", cwd, "rev-parse", "--show-toplevel"]).removesuffix("\n")
        records = run([
            "git",
            "--no-optional-locks",
            "-C",
            root,
            "status",
            "--porcelain=v2",
            "--branch",
            "--untracked-files=all",
            "-z",
        ]).split("\0")
    except subprocess.CalledProcessError:
        return None
    headers, changed = parse_status(records)
    head = headers.get("branch.head", "")
    if head == "(detached)":
        head = headers.get("branch.oid", "")[:7] + " detached"
    line = plain(head, 80) + (f" ● {changed}" if changed else " ✓ clean")
    if "branch.ab" in headers:
        ahead, behind = headers["branch.ab"].split()
        if int(ahead):
            line += f" ↑{int(ahead)}"
        if int(behind):
            line += f" ↓{abs(int(behind))}"
    if "branch.upstream" not in headers and headers.get("branch.head") != "(detached)":
        line += " local only"
    return os.path.realpath(root), line


def session_node(ctl: list[str], sid: str, socket: str) -> dict[str, Any] | None:
    windows = json.loads(run([*ctl, "window", "list", "--json", "--socket", socket]))
    preferred = os.environ.get("AGTERM_WINDOW_ID")
    for window in sorted(windows["result"]["windows"], key=lambda w: w["id"] != preferred):
        if not window.get("open"):
            continue
        tree = json.loads(
            run([*ctl, "tree", "--json", "--window", window["id"], "--socket", socket])
        )["result"]["tree"]
        for workspace in tree["workspaces"]:
            for node in workspace["sessions"]:
                if node["id"] == sid:
                    return node
    return None


def escape(text: str) -> str:
    return re.sub(r"([\\`*_\[\]{}()<>#+!|~^&.-])", r"\\\1", text)


def colorize(line: str) -> str:
    head, _, tail = line.partition(" ")
    parts = [f"**{escape(head)}**"]
    colors = {"✓": "green", "●": "yellow", "↑": "blue", "↓": "purple"}
    for token in re.split(r"(✓ clean|● \d+|↑\d+|↓\d+|local only|detached)", tail):
        if not token:
            continue
        if token[0] in colors:
            parts.append(f'^[{token}](color: "{colors[token[0]]}")')
        elif token in {"local only", "detached"}:
            parts.append(f"^[{token}](dim: true)")
        else:
            parts.append(escape(token))
    return parts[0] + " " + "".join(parts[1:])


def format_summaries(summaries: dict[str, Any]) -> tuple[str, list[str]]:
    lines = []
    colored = []
    for root, summary in sorted(summaries.items(), key=lambda item: min(item[1]["panes"])):
        prefix = ""
        if len(summaries) > 1:
            roles = "/".join("L" if role == "left" else "R" for role in sorted(summary["panes"]))
            prefix = f"{roles} {plain(Path(root).name, 48)}: "
        lines.append(prefix + summary["line"])
        colored.append(escape(prefix) + colorize(summary["line"]))
    markup = " | ".join(colored)
    # Truncating markup can leave an unterminated span, so keep long rows as plain text.
    if len(markup.encode()) > 512:
        return plain(" | ".join(lines), 512), []
    return markup, ["--markdown"]


def refresh(event: dict[str, Any], pid: int, agent: str) -> None:
    """Serialize registration, Git reads, and publication across both panes."""
    sid = os.environ["AGTERM_SESSION_ID"]
    pane = os.environ["AGTERM_PANE_ID"]
    socket = os.environ["AGTERM_SOCKET"]
    ctl = [os.environ.get("AGTERMCTL", "agtermctl")]
    state_dir = Path(tempfile.gettempdir()) / f"agterm-git-info-{os.getuid()}"
    state_dir.mkdir(mode=0o700, exist_ok=True)
    key = hashlib.sha256(f"{socket}\0{sid}".encode()).hexdigest()
    state = state_dir / f"{key}.json"
    with (state_dir / f"{key}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        node = session_node(ctl, sid, socket)
        if node is None or node.get("remoteHost"):
            return
        panes = {
            surface["paneID"]: surface["kind"]
            for surface in node["surfaces"]
            if surface["kind"] in {"left", "right"}
        }
        if pane not in panes:
            return
        # A previous hook may have been killed while writing its state.
        try:
            participants = json.loads(state.read_text())
        except (FileNotFoundError, ValueError):
            participants = {}
        thread = event.get("session_id")
        if event["hook_event_name"] == "SessionEnd":
            previous = participants.get(pane, {})
            if previous.get("pid") == pid and previous.get("thread") == thread:
                participants.pop(pane)
        else:
            participants[pane] = {"pid": pid, "agent": agent, "thread": thread, "cwd": event["cwd"]}
        summaries = {}
        for token, participant in list(participants.items()):
            try:
                command = run(["ps", "-p", str(participant["pid"]), "-o", "comm="]).strip()
            except subprocess.CalledProcessError:
                participants.pop(token)
                continue
            kind = panes.get(token)
            if kind is None or Path(command).name != participant["agent"]:
                participants.pop(token)
                continue
            result = snapshot(participant["cwd"])
            if result:
                root, line = result
                summaries.setdefault(root, {"line": line, "panes": []})["panes"].append(kind)
        state.write_text(json.dumps(participants))
        line, options = format_summaries(summaries)
        args = [line, *options, "--hide-after", "86400"] if line else ["--clear"]
        run([*ctl, "session", "info", *args, "--target", sid, "--socket", socket])


def main() -> None:
    """Ignore unavailable integration state without interrupting an agent."""
    if not all(
        os.environ.get(key) for key in ("AGTERM_SESSION_ID", "AGTERM_PANE_ID", "AGTERM_SOCKET")
    ):
        return
    event = json.load(sys.stdin)
    if not isinstance(event, dict):
        return
    if event.get("hook_event_name") not in {"SessionStart", "PostToolUse", "Stop", "SessionEnd"}:
        return
    identity = owner()
    if identity is None:
        return
    _, agent = identity
    if (
        (
            agent == "claude"
            and (os.environ.get("CLAUDE_CODE_ENTRYPOINT") != "cli" or event.get("agent_id"))
        )
        or (agent == "codex" and not codex_root(event))
        or not event.get("cwd")
    ):
        return
    refresh(event, *identity)


if __name__ == "__main__":
    with contextlib.suppress(OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        main()
