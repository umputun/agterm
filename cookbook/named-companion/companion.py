#!/usr/bin/env python3
"""Duplicate the session as a tinted companion named from a dialog.

Run as an agterm keymap custom command: the runner exports $AGT_SESSION_ID, $AGT_WINDOW_ID and
$AGT_SOCKET. A blank name takes the parent's and leaves a marker in ~/.cache/agterm/companion-names,
which the session-context-nudge hook reads to have the companion's Claude Code rename it once.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

AGTERMCTL = os.environ.get("AGTERMCTL", "agtermctl")
MARKERS = Path.home() / ".cache" / "agterm" / "companion-names"
TINT = "gray"


class Fail(Exception):
    """Fail carries a message for the binding's --error-hud."""


def agt(*args: str) -> subprocess.CompletedProcess:
    socket = os.environ.get("AGT_SOCKET", "")
    cmd = [AGTERMCTL, *args] + (["--socket", socket] if socket else [])
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def asked_name(rc: int, out: str) -> str | None:
    """asked_name returns the typed name, "" for a blank one, None when dismissed.

    ask exits 3 on esc and 2 on a cancellation, both answers; only 1 means no dialog.
    """
    if rc in (2, 3):
        return None
    if rc != 0:
        raise Fail(f"cannot open the dialog: {out.strip()}")
    data = json.loads(out)
    if data.get("result") != "answered" or data.get("id") != "ok":
        return None
    return str(data.get("text", "")).strip()


def session_name(tree: dict, sid: str) -> str:
    for ws in tree.get("result", {}).get("tree", {}).get("workspaces", []):
        for s in ws.get("sessions", []):
            if s.get("id", "").upper() == sid.upper():
                return s.get("name", "")
    raise Fail(f"session {sid} not in the tree")


def run() -> None:
    sid = os.environ.get("AGT_SESSION_ID", "")
    if not sid:
        raise Fail("not inside an agterm session (AGT_SESSION_ID unset)")
    window = os.environ.get("AGT_WINDOW_ID", "") or "active"

    res = agt("ask", "New companion", "--style", "gui", "--input", "line", "--window", window,
              "--placeholder", "empty: parent's name, renamed from its context later")
    typed = asked_name(res.returncode, res.stdout or res.stderr)
    if typed is None:
        return

    res = agt("session", "duplicate", "--companion", "--target", sid, "--json")
    if res.returncode != 0:
        raise Fail(res.stderr.strip() or res.stdout.strip())
    dup = json.loads(res.stdout)["result"]
    cid, parent = dup["id"], dup["parent"]

    # the copy is created without a name, so a blank answer still needs the parent's spelled out
    name = typed
    if not name:
        res = agt("tree", "--json", "--window", window)
        if res.returncode != 0:
            raise Fail(f"cannot read the tree: {res.stderr.strip()}")
        name = session_name(json.loads(res.stdout), parent)

    for args in (("session", "rename", name, "--target", cid),
                 ("session", "tint", TINT, "--on", "icon,name", "--target", cid)):
        res = agt(*args)
        if res.returncode != 0:
            raise Fail(f"{' '.join(args[:2])}: {res.stderr.strip()}")

    if not typed:
        MARKERS.mkdir(parents=True, exist_ok=True)
        (MARKERS / cid.upper()).write_text(name)


def main() -> int:
    try:
        run()
    except Fail as err:
        print(f"companion: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
