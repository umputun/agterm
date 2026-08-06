#!/usr/bin/env python3
"""Pick a past Claude Code conversation of THIS session's directory and resume it in the pane the
chord fired from.

Runs as an agterm keymap custom command, so the runner exports $AGT_* and starts it in the session's
directory. No arguments.

    claude already running in the pane -> types "/resume <id>" into the TUI
    bare shell prompt                  -> types "$CLAUDE_RESUME_CMD --resume <id>"

/resume is claude's own picker: the id filters it down, and whether a single match auto-selects is
undocumented, so the typed Return may land on a one-row picker that wants a second one. Resuming a
conversation another pane has open is refused by claude itself ("currently running as a background
agent"), which is why this does not try to detect that case.

Rows are named by a model before the picker opens. The cache under ~/.cache/agterm/claude-resume keys
a name to the transcript's mtime, so a press only pays for conversations that changed since the last
one, usually one and often none. That naming pass is the whole cold start, so it runs behind a
session hud.

    CLAUDE_RESUME_DRY=1       print the rows instead of opening the picker
    CLAUDE_RESUME_NAME_MAX    how many of the newest conversations get a name (default 20)
    CLAUDE_RESUME_CMD         what to type at a shell prompt (default claude)
    CLAUDE_FG_MATCH           argv pattern that means "claude runs here". The default matches a direct
                              run; add your own alias or wrapper script to match those too, e.g.
                              '(^|/)(claude|mywrapper)$'
    CLAUDE_RESUME_PANE_POINTER  file template naming the conversation open in a pane (default off)
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, ClassVar

AGTERMCTL = os.environ.get("AGTERMCTL", "agtermctl")
# a custom command is spawned by the app, which carries launchd's PATH rather than a login shell's,
# so every tool is resolved rather than assumed
CLAUDE_BIN = os.environ.get("CLAUDE_BIN") or shutil.which("claude") or str(Path.home() / ".local/bin/claude")
# the full id, not the "haiku" alias: that is not a recognized alias and silently falls back to the
# default model
NAME_MODEL = os.environ.get("CLAUDE_RESUME_MODEL", "claude-haiku-4-5-20251001")
RESUME_CMD = os.environ.get("CLAUDE_RESUME_CMD", "claude")
FG_MATCH = re.compile(os.environ.get("CLAUDE_FG_MATCH", r"(^|/)claude$"))
MAX_ROWS = int(os.environ.get("CLAUDE_RESUME_MAX", "80"))
NAME_MAX = int(os.environ.get("CLAUDE_RESUME_NAME_MAX", "20"))
# how far a named conversation may move on before its name is regenerated: an hour of new activity,
# or a transcript that grew by this much. The size rule is what catches a session that changed
# subject in one long sitting, which the clock alone misses.
NAME_TTL = int(os.environ.get("CLAUDE_RESUME_NAME_TTL", "3600"))
NAME_GROWTH = int(os.environ.get("CLAUDE_RESUME_NAME_GROWTH", "150000"))
CACHE_DIR = Path(os.environ.get("CLAUDE_RESUME_CACHE") or Path.home() / ".cache/agterm/claude-resume")
LOG = Path(os.environ.get("CLAUDE_RESUME_LOG", "/tmp/claude-pick-conversation.log"))
DRY = bool(os.environ.get("CLAUDE_RESUME_DRY"))
# a file holding the conversation id open in one pane, as {sid} and {pane} placeholders. Claude Code
# does not publish this, so it is empty unless your own statusline hook writes such a file
PANE_POINTER = os.environ.get("CLAUDE_RESUME_PANE_POINTER", "")

# the digest windows: the opening prompts say what the conversation was for, the closing ones say
# where it got to. A single assistant entry can be tens of KB, hence the generous tail.
HEAD_BYTES, TAIL_BYTES = 300_000, 1_500_000
HEAD_PROMPTS, TAIL_ENTRIES, ENTRY_CHARS = 2, 16, 350
LATEST_MARK = "--- latest ---"

# the progress panel: pinned at the top of the pane and held at a fixed width, so a step that names a
# longer count does not resize it mid-run
HUD_POSITION, HUD_WIDTH = "top", "45"
# how long the naming process may take to exit once its output has ended, before it is killed
EXIT_GRACE = 10

SYSTEM_PROMPT = (
    "You label development session transcripts so a developer can spot the one he wants. Each ### <id> "
    "block holds that session's first prompts, then a --- latest --- marker, then its most recent "
    "exchanges (user: what he asked, did: what the assistant did). A long session drifts, so the work "
    "AFTER the marker is what it is currently about: name it from there, and use the opening only when "
    "nothing later is substantive. Return the id with a name of at most 6 words naming the concrete "
    "subject in the developer's own terms (the feature, file, bug, or PR), and a summary of at most 14 "
    "words saying where the work now stands. Never echo a bare command or slash-command as the name: "
    "say what it turned out to be about. Lowercase, no trailing period, no filler."
)
SCHEMA = json.dumps({
    "type": "object",
    "properties": {"items": {"type": "array", "items": {
        "type": "object",
        "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "summary": {"type": "string"}},
        "required": ["id", "name", "summary"]}}},
    "required": ["items"],
})


def log(message: str) -> None:
    """log appends a line to the run log; a keybinding has no stdout anyone reads."""
    try:
        with LOG.open("a") as fh:
            fh.write(f"{time.strftime('%F %T')}  {message}\n")
    except OSError:
        pass


def slug_of(path: str) -> str:
    """slug_of renders a directory the way Claude Code files it: every non-alphanumeric char a dash."""
    return re.sub(r"[^a-zA-Z0-9]", "-", path)


def age_label(seconds: float) -> str:
    """age_label renders an age the picker subtitle way: 12m, 3h, 2d."""
    minutes = int(seconds // 60)
    if minutes < 60:
        return f"{minutes}m"
    if minutes < 1440:
        return f"{minutes // 60}h"
    return f"{minutes // 1440}d"


class Agt:
    """Agt is the agterm control channel: agtermctl plus this session's addressing."""

    def __init__(self) -> None:
        self.bin = AGTERMCTL
        self.socket = os.environ.get("AGT_SOCKET", "")
        self.sid = os.environ.get("AGT_SESSION_ID", "")
        self.window = os.environ.get("AGT_WINDOW_ID", "active")
        self.hud_up = False

    def run(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        """run invokes agtermctl with the socket appended, never raising on a nonzero exit."""
        cmd = [self.bin, *args]
        if self.socket:
            cmd += ["--socket", self.socket]
        return subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)

    def hud(self, detail: str) -> None:
        """hud posts or updates the progress panel; a failure here must never take the picker down.

        The panel floats over the session without taking its focus, which is the point: the naming
        pass holds the picker back for seconds and the press would otherwise look like it did nothing.
        """
        if not self.sid:
            return
        verb = "update" if self.hud_up else "open"
        res = self.run("session", "hud", verb, "resume claude", "--detail", detail,
                       "--spinner-style", "braille", "--position", HUD_POSITION,
                       "--size-percent", HUD_WIDTH, "--target", self.sid)
        self.hud_up = self.hud_up or res.returncode == 0

    def hud_close(self) -> None:
        """hud_close takes the panel down, leaving the slot free for the picker.

        One session-wide slot holds either a HUD or an overlay, and the native picker is a cover of
        its own: leaving the panel up is how a press ends with a panel and no picker.
        """
        if not self.hud_up:
            return
        self.run("session", "hud", "close", "--target", self.sid)
        self.hud_up = False

    def foreground(self, pane: str) -> list[str]:
        """foreground returns the pane's live argv; the tree reports main and split only, so a scratch
        pane reads as a shell."""
        field = {"left": "foreground", "right": "splitForeground"}.get(pane, "")
        if not field or not self.sid:
            return []
        try:
            tree = json.loads(self.run("tree", "--json").stdout)["result"]["tree"]
        except (ValueError, KeyError):
            return []
        for workspace in tree.get("workspaces", []):
            for session in workspace.get("sessions", []):
                if session.get("id") == self.sid:
                    argv = session.get(field) or []
                    return [str(part) for part in argv]
        return []

    def pick(self, items: list[dict[str, str]]) -> str:
        """pick opens the native picker and returns the chosen id, "" when cancelled or nothing came
        back. Exit 2 is the picker's own "cancelled", a normal way out rather than a failure."""
        res = self.run("pick", "--prompt", "resume claude", "--window", self.window,
                       stdin=json.dumps(items))
        if res.returncode == 2:
            return ""
        if res.returncode != 0:
            fail(self, f"picker failed (exit {res.returncode})")
        try:
            choice = json.loads(res.stdout)
        except ValueError:
            return ""
        return str(choice.get("id", "")) if choice.get("result") == "picked" else ""

    def type_line(self, line: str, pane: str) -> None:
        """type_line sends the resume command into the pane the chord fired from, Return included."""
        self.run("session", "type", line + "\n", "--target", self.sid or "active", "--pane", pane)

    def notify(self, message: str) -> None:
        """notify is the only channel a keybinding has: its stdout goes to /dev/null."""
        self.run("notify", message, "--title", "Resume Claude")


def fail(agt: Agt, message: str) -> None:
    """fail reports through the only channels a keybinding has, then exits."""
    agt.hud_close()
    log(message)
    if DRY:
        print(f"fail: {message}", file=sys.stderr)
        sys.exit(1)
    agt.notify(message)
    sys.exit(1)


def transcripts(directory: Path) -> list[Path]:
    """transcripts returns the conversation files newest first, capped: the picker is for recent work
    and every file below costs a read."""
    try:
        files = [p for p in directory.glob("*.jsonl") if p.is_file()]
    except OSError:
        return []
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files[:MAX_ROWS]


def first_prompt(path: Path) -> tuple[str, str]:
    """first_prompt returns (session id, opening prompt) from the file's first last-prompt entry.

    That one entry is both the label and the key, and it sits near the top, so the scan stops there
    rather than reading the whole transcript.
    """
    try:
        with path.open(errors="replace") as fh:
            for line in fh:
                if '"type":"last-prompt"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                return str(entry.get("sessionId") or ""), str(entry.get("lastPrompt") or "")
    except OSError:
        pass
    return "", ""


def rows(directory: Path) -> list[dict[str, Any]]:
    """rows builds the conversation list, newest first."""
    out: list[dict[str, Any]] = []
    for path in transcripts(directory):
        sid, prompt = first_prompt(path)
        if not sid or not prompt:
            continue
        stat = path.stat()
        out.append({"id": sid, "first": prompt, "mtime": int(stat.st_mtime), "size": stat.st_size})
    return out


def needs_name(row: dict[str, Any], cache: dict[str, Any]) -> bool:
    """needs_name decides whether a conversation is worth a model call.

    An exact-mtime key would re-name the conversation you are sitting in on every press: its
    transcript grows while this script runs. So a name survives an hour of new activity, or a bounded
    amount of growth.
    """
    entry = cache.get(str(row["id"]), {})
    if not entry.get("name"):
        return True
    return (int(row["mtime"]) - int(entry.get("mtime", 0)) > NAME_TTL
            or int(row["size"]) - int(entry.get("size", 0)) > NAME_GROWTH)


def entry_text(entry: dict[str, Any]) -> str:
    """entry_text flattens a transcript entry's content, string or content-block array alike."""
    content = entry.get("message", {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(str(part.get("text", "")) for part in content
                        if isinstance(part, dict) and part.get("type") == "text")
    return ""


def window_lines(path: Path) -> list[dict[str, Any]]:
    """window_lines returns the entries of one transcript's two digest windows, in order.

    Only the ends are read: a conversation's opening says what it was for, its tail says where it got
    to, and everything between is what makes these files large. A window can cut a line in half, so
    unparseable lines are dropped rather than failing the whole digest.
    """
    entries: list[dict[str, Any]] = []
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            head = fh.read(HEAD_BYTES)
            fh.seek(max(0, size - TAIL_BYTES))
            tail = fh.read()
    except OSError:
        return []

    def parsed(chunk: bytes, types: tuple[str, ...], limit: int, newest: bool) -> list[dict[str, Any]]:
        found: list[dict[str, Any]] = []
        for line in chunk.decode(errors="replace").splitlines():
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict) and entry.get("type") in types:
                found.append(entry)
                if not newest and len(found) >= limit:
                    break
        return found[-limit:] if newest else found

    entries += parsed(head, ("user",), HEAD_PROMPTS, newest=False)
    entries.append({"type": "__mark"})
    entries += parsed(tail, ("user", "assistant"), TAIL_ENTRIES, newest=True)
    return entries


def digest(path: Path, sid: str) -> str:
    """digest renders one conversation into the block the naming model reads, "" when too thin."""
    lines: list[str] = []
    for entry in window_lines(path):
        if entry.get("type") == "__mark":
            lines.append(LATEST_MARK)
            continue
        if entry.get("isSidechain") or entry.get("isMeta"):
            continue
        prefix = {"user": "user: ", "assistant": "did: "}.get(str(entry.get("type")), "")
        if prefix:
            lines.append(prefix + entry_text(entry))

    kept: list[str] = []
    for line in lines:
        # a tool-result user turn opens with a tag, not with anything the developer typed
        if len(line) <= 8 or line.startswith("user: <") or line in kept:
            continue
        kept.append(line)
    if len(kept) < 2:
        return ""
    return f"### {sid}\n" + "\n".join(line[:ENTRY_CHARS] for line in kept)


class Naming:
    """Naming runs the model call and reports the names as the model writes them.

    The call is the whole cold start, and a spinner over a second counter says nothing about what it
    is doing. Streaming costs nothing here: the schema output arrives as ordinary text deltas, so a
    name can be shown the moment it is complete, and the run's own `result` event still carries the
    finished object (`structured_output`), which is what gets parsed. The reader runs on its own
    thread so the panel keeps ticking through the model's first seconds, when nothing is emitted yet.
    """

    STREAM_ARGS: ClassVar[list[str]] = ["--output-format", "stream-json", "--verbose",
                                        "--include-partial-messages"]
    NAME_RE = re.compile(r'"name"\s*:\s*"((?:[^"\\]|\\.)*)"')

    def __init__(self, count: int) -> None:
        self.count = count
        self.lock = threading.Lock()
        self.buffer = ""
        self.names: list[str] = []
        self.items: list[dict[str, Any]] | None = None

    def consume(self, stream: Any) -> None:
        """consume reads the event stream, collecting finished names and the final object.

        This thread is the pipe's only drain, so it has to keep reading whatever it meets. Stopping
        early fills the pipe buffer, blocks the model process on its next write and leaves it running
        with the panel pinned, on a process spawned from a keybinding that has no terminal to
        interrupt. The stream is therefore read as bytes and decoded per line, which cannot raise on
        malformed output, and a line that fails to parse costs that line rather than the rest of the
        run. The event schema belongs to another CLI and changes between its releases, so the guard
        is on the shape of the failure, not on the shapes seen so far.
        """
        try:
            for raw in stream:
                try:
                    self.absorb(raw.decode("utf-8", "replace"))
                except Exception as err:  # noqa: BLE001 - any malformed event, never the whole stream
                    log(f"naming stream: dropped a line: {err}")
        except OSError as err:
            log(f"naming stream: read failed: {err}")

    def absorb(self, line: str) -> None:
        """absorb folds one event line into the collected names or the final object."""
        try:
            event = json.loads(line)
        except ValueError:
            return
        if not isinstance(event, dict):
            return
        if event.get("type") == "result":
            structured = event.get("structured_output")
            if not isinstance(structured, dict):
                try:
                    structured = json.loads(event.get("result", ""))
                except (ValueError, TypeError):
                    structured = {}
            items = structured.get("items") if isinstance(structured, dict) else None
            with self.lock:
                self.items = [i for i in items if isinstance(i, dict)] if isinstance(items, list) else None
            return
        event_body = event.get("event")
        delta = event_body.get("delta") if isinstance(event_body, dict) else None
        chunk = (delta.get("text") or delta.get("partial_json") or "") if isinstance(delta, dict) else ""
        if not isinstance(chunk, str) or not chunk:
            return
        with self.lock:
            self.buffer += chunk
            self.names = self.NAME_RE.findall(self.buffer)

    def detail(self, elapsed: int) -> str:
        """detail is the panel's second line: the newest name once there is one, else the wait."""
        with self.lock:
            names = list(self.names)
        if not names:
            return f"naming {self.count} conversation{'' if self.count == 1 else 's'} · {elapsed}s"
        return f"named {len(names)} of {self.count} · {names[-1][:44]}"

    def run(self, agt: Agt, body: str) -> list[dict[str, Any]] | None:
        """run drives the call to completion, returning None on any failure so the picker still opens."""
        try:
            proc = subprocess.Popen(
                [CLAUDE_BIN, "-p", "--model", NAME_MODEL, "--safe-mode", "--no-session-persistence",
                 "--tools", "", *self.STREAM_ARGS, "--system-prompt", SYSTEM_PROMPT,
                 "--json-schema", SCHEMA, body],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                env={**os.environ, "MAX_THINKING_TOKENS": "0"})
        except (OSError, subprocess.SubprocessError) as err:
            log(f"naming failed to start: {err}")
            return None

        reader = threading.Thread(target=self.consume, args=(proc.stdout,), daemon=True)
        reader.start()
        started = time.monotonic()
        while reader.is_alive():
            agt.hud(self.detail(int(time.monotonic() - started)))
            reader.join(timeout=0.7)
        # its output has ended, so this is a formality, but an unbounded wait here is the one place
        # left where a stuck child would hold the panel up with no way to clear it
        try:
            proc.wait(timeout=EXIT_GRACE)
        except subprocess.TimeoutExpired:
            log("naming did not exit after its output ended; killing it")
            proc.kill()
            proc.wait()
        with self.lock:
            items = self.items
        if items is None:
            log("naming returned nothing usable")
        return items


def name_rows(agt: Agt, directory: Path, cache_file: Path, all_rows: list[dict[str, Any]]) -> dict[str, Any]:
    """name_rows names whatever moved since the last press and returns the updated cache.

    A model that fails or times out leaves the row on its opening prompt rather than blocking the
    picker, so every failure path returns the cache unchanged.
    """
    try:
        cache = json.loads(cache_file.read_text())
    except (OSError, ValueError):
        cache = {}
    if not isinstance(cache, dict):
        cache = {}

    todo = [row for row in all_rows[:NAME_MAX] if needs_name(row, cache)]
    if not todo:
        return cache

    # the digests read up to NAME_MAX transcripts, a visible wait of its own before the model call
    # even starts, so the panel goes up here rather than around the call alone, and each file it
    # opens is a step of its own: this phase is silent otherwise and the counts say how much is left
    blocks: list[str] = []
    for index, row in enumerate(todo, start=1):
        agt.hud(f"reading conversation {index} of {len(todo)} · {len(all_rows)} in this directory")
        block = digest(directory / f"{row['id']}.jsonl", str(row["id"]))
        if block:
            blocks.append(block)
    if not blocks:
        return cache

    named = Naming(len(todo)).run(agt, "\n".join(blocks))
    if named is None:
        return cache

    by_id = {str(row["id"]): row for row in todo}
    for item in named:
        target = by_id.get(str(item.get("id", "")))
        if target:
            cache[str(target["id"])] = {"mtime": target["mtime"], "size": target["size"],
                                        "name": item.get("name", ""), "summary": item.get("summary", "")}
    try:
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache_file.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(cache))
        tmp.replace(cache_file)
    except OSError as err:
        log(f"cache write failed: {err}")
    return cache


def naming_candidates(all_rows: list[dict[str, Any]], skip: str) -> list[dict[str, Any]]:
    """naming_candidates drops the row the picker will not show, so no model call is spent on it.

    Order is preserved, because name_rows spends its budget on the newest rows.
    """
    return [row for row in all_rows if str(row["id"]) != skip]


def picker_items(all_rows: list[dict[str, Any]], cache: dict[str, Any], skip: str) -> list[dict[str, str]]:
    """picker_items renders the rows for the native picker, named where a name is known."""
    now = time.time()
    items: list[dict[str, str]] = []
    for row in all_rows:
        rid = str(row["id"])
        if rid == skip:
            continue
        age = age_label(now - float(row["mtime"]))
        entry = cache.get(rid, {})
        if entry.get("name"):
            items.append({"id": rid, "label": str(entry["name"]),
                          "subtitle": f"{age} ago · {entry.get('summary', '')}"})
        else:
            items.append({"id": rid, "label": str(row["first"])[:110], "subtitle": f"{age} ago"})
    return items


def live_conversation(sid: str, pane: str, running: bool) -> str:
    """live_conversation returns the id open in this pane, "" when none or when unconfigured.

    Resuming what you are already in is a no-op, so that row is dropped. Claude Code publishes no
    such pointer, so this reads a file your own statusline hook writes, named by
    CLAUDE_RESUME_PANE_POINTER, and is off until you set it. The pointer goes stale once claude
    exits, so it is trusted only while claude runs here.
    """
    if not PANE_POINTER or not running or not sid:
        return ""
    try:
        path = Path(PANE_POINTER.format(sid=sid, pane=pane))
        return Path(path.read_text().splitlines()[0]).stem
    except (OSError, IndexError, KeyError):
        return ""


def main() -> int:
    agt = Agt()
    cwd = os.environ.get("AGT_SESSION_PWD") or os.getcwd()
    pane = os.environ.get("AGT_PANE", "left")

    launcher = next((part for part in agt.foreground(pane) if FG_MATCH.search(part)), "")
    root = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")

    directory = root / "projects" / slug_of(cwd)
    if not directory.is_dir():
        fail(agt, f"no Claude Code conversations for {cwd} under {root}")

    all_rows = rows(directory)
    if not all_rows:
        fail(agt, f"no Claude Code conversations for {cwd}")

    # resolved before the naming pass, not after: the conversation open in this pane is the one whose
    # transcript is growing, so it is almost always the only candidate a warm cache still finds
    # stale, and it is the one row the picker then drops. Naming it costs a model call per press and
    # shows nothing for it
    skip = live_conversation(agt.sid, pane, bool(launcher))

    try:
        cache = name_rows(agt, directory, CACHE_DIR / f"{root.name}-{slug_of(cwd)}.json",
                          naming_candidates(all_rows, skip))
    finally:
        agt.hud_close()

    items = picker_items(all_rows, cache, skip)
    if not items:
        fail(agt, f"no Claude Code conversations for {cwd}")

    if DRY:
        print(f"cwd={cwd} pane={pane} root={root} running={'yes' if launcher else 'no'} "
              f"skip={skip or 'none'}")
        for item in items[:8]:
            print(f"{item['label']}\n    {item['subtitle']}")
        print(f"{len(items)} rows")
        return 0

    chosen = agt.pick(items)
    if not chosen:
        return 0
    agt.type_line(f"/resume {chosen}" if launcher else f"{RESUME_CMD} --resume {chosen}", pane)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
