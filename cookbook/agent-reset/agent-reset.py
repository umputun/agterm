#!/usr/bin/env python3
"""Reset the coding agent running in an agterm pane, and nothing else.

Run as an agterm keymap custom command: the runner exports $AGT_SESSION_ID, $AGT_PANE and
$AGT_SOCKET, and spawns this under the app's launch PATH rather than a shell's.

The agent is read from the pane's live foreground argv rather than assumed, so the chord is inert
in a shell or another TUI. A reset is a slash command, which means something to a coding agent and
noise to anything else. Both agents take the same command; they differ in how it is submitted, so
each pane is matched on its own argv.

Fired from the PRIMARY pane it also resets the split's agent and clears the session's title-bar
context, because the primary agent owns the session: resetting it ends what the session was doing.
From the split it resets that one pane, since one of two agents finishing is not the session
finishing. The context clear is gated on the primary write succeeding - a failed write leaves that
agent still holding its task, so the line must keep describing it.

Usage: agent-reset.py
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

AGTERMCTL = os.environ.get("AGTERMCTL", "agtermctl")

# a wrapper script is the common case: match any argv element so `sh /usr/local/bin/mywrapper`
# counts. Override to add your own launcher, e.g. CLAUDE_FG_MATCH='(^|/)(claude|mywrapper)$'
CLAUDE_FG_MATCH = re.compile(os.environ.get("CLAUDE_FG_MATCH", r"(^|/)claude$"))
CODEX_FG_MATCH = re.compile(os.environ.get("CODEX_FG_MATCH", r"(^|/)codex$"))

# both agents take /clear. On codex it also wipes the pane's scrollback, so anything reading the
# screen back with `session text` finds only codex's fresh banner after a reset.
RESET_COMMAND = "/clear"

# codex does not act on an Enter that shares a write with the text: the command stays in the
# composer. Sent as its own write it submits, so the submit is a second `session type` call.
SUBMIT = "\n"


def is_claude(argv: list[str]) -> bool:
    """is_claude reports whether a pane's foreground argv is a Claude Code launcher."""
    return any(CLAUDE_FG_MATCH.search(part) for part in argv)


def is_codex(argv: list[str]) -> bool:
    """is_codex reports whether a pane's foreground argv is a codex launcher."""
    return any(CODEX_FG_MATCH.search(part) for part in argv)


def inputs_for(argv: list[str]) -> tuple[str, ...]:
    """inputs_for returns the writes that reset the agent in argv, or nothing when none matches."""
    if is_claude(argv):
        return (RESET_COMMAND + SUBMIT,)
    if is_codex(argv):
        return (RESET_COMMAND, SUBMIT)
    return ()


def run(args: list[str], socket: str) -> subprocess.CompletedProcess:
    """run calls agtermctl against the app that fired the chord rather than whichever is on PATH."""
    cmd = [AGTERMCTL] + args + (["--socket", socket] if socket else [])
    return subprocess.run(cmd, capture_output=True, check=False)


def foreground(socket: str, sid: str, pane: str) -> list[str]:
    """foreground returns a pane's live argv; the tree reports the main and split panes only."""
    field = {"left": "foreground", "right": "splitForeground"}.get(pane, "")
    if not field or not sid:
        return []
    try:
        tree = json.loads(run(["tree", "--json"], socket).stdout)["result"]["tree"]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError):
        return []
    for workspace in tree.get("workspaces", []):
        for session in workspace.get("sessions", []):
            if session.get("id") == sid:
                return [str(part) for part in (session.get(field) or [])]
    return []


def is_primary(pane: str) -> bool:
    """is_primary reports whether the chord fired from the pane that owns the session."""
    return pane != "right"


def send(socket: str, sid: str, pane: str, inputs: tuple[str, ...]) -> bool:
    """send types one agent's reset into a pane, reporting whether every write succeeded."""
    typed = True
    for text in inputs:
        res = run(["session", "type", text, "--target", sid, "--pane", pane], socket)
        typed = typed and res.returncode == 0
    return typed


def main() -> int:
    sid = os.environ.get("AGT_SESSION_ID", "")
    pane = os.environ.get("AGT_PANE", "left")
    socket = os.environ.get("AGT_SOCKET", "")

    inputs = inputs_for(foreground(socket, sid, pane))
    if not inputs:
        return 0

    typed = send(socket, sid, pane, inputs)
    if not is_primary(pane):
        return 0 if typed else 1

    # an absent splitForeground is both "no split" and "split at a shell prompt", neither an agent
    peer = inputs_for(foreground(socket, sid, "right"))
    if peer:
        send(socket, sid, "right", peer)

    if not typed:
        return 1
    run(["session", "context", "--clear", "--target", sid], socket)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
