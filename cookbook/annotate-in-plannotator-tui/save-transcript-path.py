#!/usr/bin/env python3
"""Claude Code Stop hook: record where an agterm pane's Claude transcript lives.

`annotate.py replies` hands the path to plannotator-tui, which reads the transcript fresh when the
chord fires. Only the path is kept: a hook runs when a turn ends, so a copy of the message would be
stale the moment one is missed, while the transcript keeps whatever Claude actually wrote.

The file is keyed by session AND pane because a split session shares one session id while running an
agent in each pane.

A hook that raises shows an error in the session, so every failure here is swallowed.
"""

import json
import os
import sys
from datetime import datetime
from pathlib import Path


def cache_dir() -> Path:
    override = os.environ.get("AGTERM_ANNOTATE_DIR")
    return Path(override) if override else Path.home() / ".cache" / "agterm-annotate"


def main() -> int:
    session = os.environ.get("AGTERM_SESSION_ID")
    if not session:
        return 0
    pane = os.environ.get("AGTERM_PANE") or "left"

    try:
        payload = json.load(sys.stdin)
    except Exception:  # noqa: BLE001 - a Stop hook must never fail a turn, whatever arrives on stdin
        return 0
    if not isinstance(payload, dict):
        return 0

    transcript = payload.get("transcript_path") or ""
    if not isinstance(transcript, str) or not transcript:
        return 0

    record = {
        "transcript_path": transcript,
        "updated": datetime.now().astimezone().isoformat(timespec="seconds"),
    }

    try:
        target = cache_dir()
        target.mkdir(parents=True, exist_ok=True)
        (target / f"{session}.{pane}.json").write_text(
            json.dumps(record, indent=2), encoding="utf-8"
        )
    except OSError:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
