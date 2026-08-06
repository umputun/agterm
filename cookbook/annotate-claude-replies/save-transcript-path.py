#!/usr/bin/env python3
"""Claude Code Stop hook: record where an agterm pane's Claude transcript lives.

The transcript path is the valuable part. A hook only runs when a turn ends, so a copy of the message
is stale the moment one is missed, while the transcript keeps whatever Claude actually wrote —
`annotate-extract.py` reads it fresh when the chord fires. The message is stored too, as the
fallback for a transcript that was rotated by a resume or never recorded.

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

    message = payload.get("last_assistant_message") or ""
    transcript = payload.get("transcript_path") or ""
    if not isinstance(message, str):
        message = ""
    if not message.strip() and not transcript:
        return 0

    # Only what is read back. The transcript path is the point of the hook; the message is the fallback
    # for a transcript rotated by a resume. Nothing needs the session id or the working directory, and
    # this file already holds enough of a conversation without them.
    record = {
        "transcript_path": transcript,
        "last_assistant_message": message,
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
