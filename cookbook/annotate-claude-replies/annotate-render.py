#!/usr/bin/env python3
"""Turn revdiff's annotation output into a notes file that reads on its own.

revdiff reports `## <file>:<line>[-<end>] (<type>)` followed by the comment. On its own that tells the
agent a line number in a file it never saw, so each note here carries the quoted source line with it.
All the replies sit in one markdown file under their own headings, so a line number alone does not say
which reply was marked. replies.json records where each section starts, which turns a note into
"11:04, the reply you just read" instead.

Usage: annotate-render.py <replies-dir> <notes.raw> <notes.md>
Exits 1 when the raw file holds no parseable annotation, which the caller treats as "nothing to send".
"""

import json
import re
import sys
from pathlib import Path

HEADER = re.compile(r"^##\s+(?P<file>.+?):(?P<start>\d+)(?:-(?P<end>\d+))?\s+\((?P<kind>[^)]*)\)\s*$")


def parse(raw: str) -> list[dict]:
    notes: list[dict] = []
    current: dict | None = None
    for line in raw.splitlines():
        match = HEADER.match(line)
        if match:
            current = {
                "file": Path(match.group("file")).name,
                "start": int(match.group("start")),
                "end": int(match.group("end") or match.group("start")),
                "body": [],
            }
            notes.append(current)
            continue
        if current is not None:
            current["body"].append(line)
    for note in notes:
        note["body"] = "\n".join(note["body"]).strip()
    return [n for n in notes if n["body"]]


def section_for(line: int, sections: list[dict]) -> str:
    """The last section starting at or before this line is the one the note landed in."""
    found = ""
    for entry in sections:
        if entry.get("line", 1) <= line:
            found = entry.get("title", "")
        else:
            break
    return found


def render(notes: list[dict], sources: dict[str, list[str]], sections: list[dict]) -> str:
    count = len(notes)
    plural = "note" if count == 1 else "notes"
    out = [
        "# Notes on your replies",
        "",
        f"{count} {plural}. Each one quotes the lines I marked, then says what I want from you.",
        "",
    ]
    for index, note in enumerate(notes, start=1):
        start, end = note["start"], note["end"]
        span = f"line {start}" if start == end else f"lines {start}-{end}"
        where = section_for(start, sections)
        out.append(f"## Note {index} — {where or note['file']}, {span}")
        out.append("")
        source = sources.get(note["file"], [])
        quoted = source[start - 1 : end] or ["(line not found in the saved reply)"]
        out.extend(f"> {line}" if line.strip() else ">" for line in quoted)
        out.append("")
        out.append(note["body"])
        out.append("")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    replies, raw, dest = (Path(p) for p in argv[1:])

    notes = parse(raw.read_text(encoding="utf-8", errors="replace"))
    if not notes:
        return 1

    sources = {
        path.name: path.read_text(encoding="utf-8", errors="replace").splitlines()
        for path in replies.glob("*.md")
        if path.name not in ("notes.md", "description.md")
    }
    try:
        sections = json.loads((replies / "replies.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        sections = []
    dest.write_text(render(notes, sources, sections), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
