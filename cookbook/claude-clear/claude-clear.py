#!/usr/bin/env python3
"""Send a line to the Claude Code run in the pane a chord fired from, and nowhere else.

The line is typed and submitted, trailing newline included, exactly as if it had been entered by hand.

Runs as an agterm keymap custom command, so the runner exports $AGT_SESSION_ID, $AGT_PANE and
$AGT_SOCKET, and the app spawns it with launchd's PATH.

Whether Claude is running is read from the pane's live foreground argv in `tree --json`, keyed by the
pane the chord fired from. Any argv element matching the launcher pattern counts, so a wrapper script
that execs claude is recognized too. When nothing matches this types nothing at all: the line is a
Claude Code slash command and only a Claude Code run has any use for it.

Usage: claude-clear.py [line...]     the line to send, default /clear; several words are joined
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

AGTERMCTL = os.environ.get("AGTERMCTL") or "agtermctl"
# The launcher, as it appears in the pane's argv. Override to recognize a wrapper you start claude
# through, e.g. CLAUDE_FG_MATCH='(^|/)(claude|mywrapper)$'.
FG_MATCH = re.compile(os.environ.get("CLAUDE_FG_MATCH") or r"(^|/)claude$")
# The tree reports the argv of the main and split panes; there is no field for the scratch pane.
FIELD = {"left": "foreground", "right": "splitForeground"}


def ctl(args: list[str]) -> subprocess.CompletedProcess[str]:
    """Run agtermctl against the instance the chord came from, never whichever one holds the default socket."""
    socket = os.environ.get("AGT_SOCKET") or ""
    cmd = [AGTERMCTL] + args + (["--socket", socket] if socket else [])
    return subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=False)


def is_claude(argv: list[str]) -> bool:
    """Report whether a pane's foreground argv is a claude launcher, wrapper included."""
    return any(FG_MATCH.search(part) for part in argv)


def foreground(sid: str, pane: str) -> list[str]:
    """Return the pane's live foreground argv, empty when it sits at a prompt or cannot be read."""
    field = FIELD.get(pane, "")
    if not field or not sid:
        return []
    try:
        tree = json.loads(ctl(["tree", "--json"]).stdout)["result"]["tree"]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError):
        return []
    for workspace in tree.get("workspaces", []):
        for session in workspace.get("sessions", []):
            if session.get("id") == sid:
                return [str(part) for part in (session.get(field) or [])]
    return []


def main() -> int:
    # sh word-splits an unquoted keymap line, so a multi-word command arrives as several arguments.
    line = " ".join(sys.argv[1:]) or "/clear"
    sid = os.environ.get("AGT_SESSION_ID") or ""
    pane = os.environ.get("AGT_PANE") or "left"
    if not is_claude(foreground(sid, pane)):
        return 0
    # a nonzero exit is the only report of a failed write: the runner turns it into a visible notice.
    try:
        res = ctl(["session", "type", line + "\n", "--target", sid, "--pane", pane])
    except (OSError, subprocess.SubprocessError):
        return 1
    return 0 if res.returncode == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
