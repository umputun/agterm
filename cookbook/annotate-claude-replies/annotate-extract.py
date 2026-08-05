#!/usr/bin/env python3
"""Write out every answer Claude gave in an agterm pane since the last thing the person typed.

The Stop hook records where the transcript is; this reads it at the moment the chord fires. That is the
whole point of the split. The hook only runs when a turn ends, so anything it copies out goes stale the
moment it misses one, while the transcript is whatever Claude has actually written.

A transcript holds one content block per line, and the blocks of a single reply share `message.id`. One
exchange often produces several such replies — text, then tool calls, then more text — and only the
last is on screen when the chord fires. Each becomes its own file so revdiff can show them as a tree.

They go into ONE markdown file, each under its own heading, because revdiff builds a table of contents
from a markdown file's headings. A section heading can say "11:04, the reply you just read" where a
filename could only say `11-04.md`. Oldest first, opening with the prompt that started the exchange.

Usage: annotate-extract.py <pointer.json> <outdir> <slug> [prompts-back]
Prints the file path. Exits 1 when there is nothing to show.
"""

import json
import re
import sys
from datetime import datetime
from pathlib import Path

MAX_ANSWERS = 12
# Records the agent injects into the user side of the transcript: peer sessions, background task
# notifications, slash-command output. They are user records, but nobody typed them, so treating one
# as the start of an exchange puts the boundary in the wrong place and hides everything before it.
INJECTED = re.compile(
    r"<(teammate-message|agent-message|task-notification|task-name"
    r"|local-command-stdout|local-command-caveat)\b"
)
# Appended to a real prompt rather than being one, so strip it from what is shown instead of rejecting.
REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL)
# A pasted wall of text as the prompt would bury the replies it opened.
PROMPT_LIMIT = 4000


def load_pointer(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def is_typed_prompt(record: dict) -> bool:
    """A turn the person actually typed.

    Three things masquerade as one. Tool results come back as user records. So do messages from peer
    sessions and background task notifications. And `isMeta` marks some injected records but not all —
    it was false on a real `<teammate-message>` — so the tag has to be checked as well.

    Bias towards rejecting: a wrongly accepted record cuts the exchange short and hides replies, while a
    wrongly rejected one only reaches further back than asked.
    """
    if record.get("type") != "user" or record.get("isSidechain") or record.get("isMeta"):
        return False
    content = (record.get("message") or {}).get("content")
    if isinstance(content, list) and any(b.get("type") == "tool_result" for b in content):
        return False
    text = prompt_text(record)
    return bool(text) and not INJECTED.search(text[:4000])


def prompt_text(record: dict) -> str:
    """What the person actually typed, whether the record stores it as a string or as text blocks."""
    content = (record.get("message") or {}).get("content")
    if isinstance(content, str):
        raw = content
    elif isinstance(content, list):
        raw = "\n".join(b.get("text") or "" for b in content if b.get("type") == "text")
    else:
        return ""
    return REMINDER.sub("", raw).strip()


def exchange_since(transcript: Path, prompts_back: int) -> tuple[tuple[str, str], list[tuple[str, str]]]:
    """The typed prompt that opened the exchange, and every reply after it, oldest first."""
    groups: dict[str, list[str]] = {}
    stamps: dict[str, str] = {}
    order: list[str] = []
    boundaries: list[int] = []
    prompts: list[tuple[str, str]] = []

    with transcript.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue

            if is_typed_prompt(record):
                boundaries.append(len(order))
                prompts.append((prompt_text(record), record.get("timestamp") or ""))
                continue
            if record.get("type") != "assistant" or record.get("isSidechain"):
                continue

            message = record.get("message") or {}
            key = message.get("id")
            if not key:
                continue
            for block in message.get("content") or []:
                if block.get("type") != "text":
                    continue
                text = block.get("text") or ""
                if not text.strip():
                    continue
                if key not in groups:
                    groups[key] = []
                    order.append(key)
                groups[key].append(text)
                stamps[key] = record.get("timestamp") or stamps.get(key, "")

    if not order:
        return ("", ""), []
    start = boundaries[-prompts_back] if len(boundaries) >= prompts_back else 0
    opening = prompts[-prompts_back] if len(prompts) >= prompts_back else ("", "")
    # No fallback to an earlier reply. A prompt Claude has not answered yet would otherwise be paired
    # with the previous exchange's answer, which reads as a reply to the wrong question.
    picked = order[start:]
    if not picked:
        return ("", ""), []
    replies = [("".join(groups[k]).strip(), stamps.get(k, "")) for k in picked][-MAX_ANSWERS:]
    return opening, replies


def local_time(raw: str) -> datetime:
    """Transcript times are UTC. A person reads the filename, so it goes in their own clock."""
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return datetime.now().astimezone()


def demote_headings(body: str) -> list[str]:
    """Push every heading down one level so only the section titles are h1.

    A reply, and especially a pasted prompt, can carry its own `#` heading. Left alone it would sit
    beside the section titles in the contents and read as another turn. Fenced code is left alone: a
    `#` there is a comment or a shell prompt, not a heading.
    """
    out, fenced = [], False
    for line in body.splitlines():
        stripped = line.lstrip()
        if stripped.startswith(("```", "~~~")):
            fenced = not fenced
        elif not fenced and stripped.startswith("#"):
            hashes = len(stripped) - len(stripped.lstrip("#"))
            if 1 <= hashes <= 5 and stripped[hashes:hashes + 1] in (" ", ""):
                line = line.replace("#" * hashes, "#" * (hashes + 1), 1)
        out.append(line)
    return out


def shape(position: int, total: int) -> str:
    """What to call a reply in the contents. Sections run oldest first, so the last one is on screen."""
    last = position == total - 1
    if total == 1:
        return "the reply you just read"
    if last:
        return f"reply {position + 1}, the one you just read"
    return f"reply {position + 1}"


def slugify(text: str) -> str:
    import re

    return re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-")[:40] or "replies"


def main(argv: list[str]) -> int:
    if len(argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    pointer, outdir, slug = Path(argv[1]), Path(argv[2]), argv[3]
    prompts_back = max(1, int(argv[4])) if len(argv) == 5 else 1

    info = load_pointer(pointer)
    transcript = info.get("transcript_path")
    answers: list[tuple[str, str]] = []

    opening = ("", "")
    readable = bool(transcript) and Path(transcript).is_file()
    if readable:
        opening, answers = exchange_since(Path(transcript), prompts_back)

    # The hook also carries the message it saw, but it is only right when the transcript could not be
    # read -- rotated by a resume, or never recorded. When the transcript IS readable and this exchange
    # has no reply yet, that stored message is the PREVIOUS exchange's answer, and pairing it with the
    # new question reads as a reply to the wrong thing. Show nothing instead.
    if not answers and not readable:
        fallback = (info.get("last_assistant_message") or "").strip()
        if fallback:
            answers = [(fallback, info.get("updated") or "")]
    if not answers:
        return 1

    outdir.mkdir(parents=True, exist_ok=True)
    # Earlier versions wrote a file per reply. Clear them so a stale one cannot be mistaken for a source.
    for stale in outdir.glob("*.md"):
        if stale.name not in ("notes.md", "description.md"):
            stale.unlink()

    # Oldest first, the order the exchange happened in. The prompt that started it opens the file, so
    # the replies have something to be answers to.
    moments = [local_time(raw) for _, raw in answers]
    spans_days = len({m.date() for m in moments}) > 1
    fmt = "%m-%d %H:%M" if spans_days else "%H:%M"

    lines: list[str] = []
    manifest: list[dict] = []

    def section(title: str, body: str, clock: str) -> None:
        # Sections open at h1 so a body's own ## and ### nest under them in the contents.
        manifest.append({"title": title, "when": clock, "line": len(lines) + 1})
        lines.append(f"# {title}")
        lines.append("")
        lines.extend(demote_headings(body))
        lines.append("")

    if opening[0]:
        clock = local_time(opening[1]).strftime(fmt)
        section(f"{clock} · what you asked", opening[0][:PROMPT_LIMIT], clock)

    for position, ((text, _), moment) in enumerate(zip(answers, moments)):
        clock = moment.strftime(fmt)
        section(f"{clock} · {shape(position, len(answers))}", text, clock)

    path = outdir / f"{slugify(slug)}.md"
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    (outdir / "replies.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
