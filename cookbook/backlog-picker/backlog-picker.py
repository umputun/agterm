#!/usr/bin/env python3
"""Pick a backlog item of THIS session's repo and hand it to the Claude Code run in the pane.

Runs as an agterm keymap custom command, so the runner exports $AGT_* and the app spawns it with
launchd's PATH and stdout on /dev/null.

    claude already running in the pane -> types "/backlog <slug>" into the TUI
    bare shell prompt                  -> types "claude \\"/backlog <slug>\\""

Items are docs/backlog/*.md at the repo root, one file per item, newest first. The slug is the file
name, which is what the backlog skill takes as its argument.

Whether claude is running here is read from the pane's live foreground argv, so a wrapper counts as
long as BACKLOG_FG_MATCH matches it.

Environment:
    AGTERMCTL           agtermctl to use, taken as given, when the one on PATH is not the right one
    BACKLOG_DIR         item directory relative to the repo root (default docs/backlog)
    BACKLOG_CLAUDE_CMD  launcher typed at a bare prompt (default claude)
    BACKLOG_FG_MATCH    argv pattern that means "claude runs here" (default (^|/)claude$)
    BACKLOG_PICKER_LOG  run log (default /tmp/backlog-picker.log)

Usage: backlog-picker.py [--list] [--test]
    --list  print the parsed items and exit, without opening the picker
    --test  run the self-tests
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import unittest
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, NamedTuple

BACKLOG_DIR = os.environ.get("BACKLOG_DIR", "docs/backlog")
CLAUDE_CMD = os.environ.get("BACKLOG_CLAUDE_CMD", "claude")
FG_MATCH = re.compile(os.environ.get("BACKLOG_FG_MATCH", r"(^|/)claude$"))
LOG = Path(os.environ.get("BACKLOG_PICKER_LOG", "/tmp/backlog-picker.log"))

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
FIELD_RE = re.compile(r"^(\w+):\s*(.*)$", re.MULTILINE)
H1_RE = re.compile(r"^#\s+(.+?)\s*$", re.MULTILINE)
# `worth` is the triage call, so it leads the subtitle. It orders nothing: the skill reports
# yes-then-later-then-no, while this picker is newest-first. The bare frontmatter value reads as
# nothing in a subtitle ("yes" answers a question the row does not ask), so spell it out; an
# unrecognized value passes through verbatim rather than being dropped.
WORTH_LABELS = {"yes": "worth fixing", "later": "worth fixing later", "no": "not worth fixing"}


class Item(NamedTuple):
    """Item is one docs/backlog/<slug>.md file."""

    slug: str
    title: str
    worth: str
    where: str
    added: str   # the frontmatter's ISO date, "" when absent or unparseable
    mtime: float


def log(message: str) -> None:
    """log appends a line to the run log; a keybinding has no stdout anyone reads."""
    try:
        with LOG.open("a") as fh:
            fh.write(f"{time.strftime('%F %T')}  {message}\n")
    except OSError:
        pass


def parse_item(path: Path, text: str, mtime: float) -> Item:
    """parse_item reads one item file; a missing field costs that field, never the item.

    The backlog format writes its three fields once and rewrites them only when a later sighting
    changes the call, so a file that predates a field or omits `where` for an unanchored item is
    normal input, not an error. A plain markdown note with no frontmatter at all still lists, under
    its H1 or its file name.

    An `added` that is not an ISO date is dropped rather than kept verbatim, because it is the
    primary sort key: `2026-8-5` compares above every well-formed `2026-...` and would park a typo
    at the top of a newest-first list, with no age in its subtitle to explain why.
    """
    fields: dict[str, str] = {}
    front = FRONTMATTER_RE.match(text)
    if front:
        fields = {m.group(1): m.group(2).strip() for m in FIELD_RE.finditer(front.group(1))}
    title = H1_RE.search(text)
    added = fields.get("added", "")
    try:
        date.fromisoformat(added)
    except ValueError:
        added = ""
    return Item(slug=path.stem,
                title=title.group(1) if title else path.stem,
                worth=fields.get("worth", ""),
                where=fields.get("where", ""),
                added=added,
                mtime=mtime)


def age_label(added: str, today: date) -> str:
    """age_label turns the `added` date into how old the item is; "" when there is no usable date.

    An item's age is information the skill relies on - a year-old entry says something the title does
    not - and the frontmatter date is never updated, so this is honest.
    """
    try:
        when = date.fromisoformat(added)
    except ValueError:
        return ""
    days = (today - when).days
    if days <= 0:
        return "today"
    if days < 31:
        return f"{days}d"
    if days < 365:
        return f"{days // 31}mo"
    return f"{days // 365}y"


def local_today() -> date:
    """local_today is today in the machine's own zone; an item's age is read in local terms."""
    return datetime.now(timezone.utc).astimezone().date()


def load_items(root: Path) -> list[Item]:
    """load_items reads the repo's backlog newest first.

    Sorted by the `added` date and then by mtime, because a day's granularity cannot separate two
    items written in one session and the newest is what the user is coming back to.

    A file name carrying a control character is refused: the slug is typed into the pane, and a
    newline in it would submit a second line of its own to whatever is running there. `glob` needs
    no guard of its own - it reports a missing, unreadable or non-directory path as no matches, which
    ends in the same "no backlog items" as an empty directory.
    """
    directory = root / BACKLOG_DIR
    items: list[Item] = []
    for path in sorted(directory.glob("*.md")):
        if any(ch < " " or ch == "\x7f" for ch in path.stem):
            log(f"skipped {path!r}: control character in the file name")
            continue
        try:
            items.append(parse_item(path, path.read_text(errors="replace"), path.stat().st_mtime))
        except OSError as err:
            log(f"skipped {path}: {err}")
    return sorted(items, key=lambda i: (i.added, i.mtime), reverse=True)


def items_of(items: list[Item], today: date) -> list[dict[str, str]]:
    """items_of renders the picker rows: the triage call, the age, then where the item lives."""
    rows = []
    for item in items:
        worth = WORTH_LABELS.get(item.worth, item.worth)
        parts = [p for p in (worth, age_label(item.added, today), item.where) if p]
        rows.append({"id": item.slug, "label": item.title, "subtitle": " · ".join(parts)})
    return rows


class Agt:
    """Agt is the agterm control channel: the resolved agtermctl plus this session's addressing."""

    def __init__(self) -> None:
        self.bin = self.resolve_bin()
        self.socket = os.environ.get("AGT_SOCKET", "")
        self.sid = os.environ.get("AGT_SESSION_ID", "")
        self.window = os.environ.get("AGT_WINDOW_ID", "active")

    @staticmethod
    def resolve_bin() -> str:
        """resolve_bin finds an agtermctl carrying `pick`, preferring the app actually running.

        Existence is not enough. Several installs can coexist, and a PATH lookup can land on an old
        "Install Command Line Tool..." symlink pointing at an app that is not the one holding the
        socket. So the running app's own bundle is asked first and the rest are probed for the
        subcommand rather than trusted by version, since two builds can report the same version and
        differ in what they carry. AGTERMCTL skips all of it and is taken as given: the probe reads a
        help layout a wrapper script does not reproduce, so probing the reader's explicit choice would
        discard exactly the binary the override exists to name.
        """
        override = os.environ.get("AGTERMCTL", "")
        if override:
            return override if os.access(override, os.X_OK) else ""
        candidates = [running_app_ctl(),
                      f"{os.environ.get('GHOSTTY_BIN_DIR', '')}/agtermctl",
                      "/usr/local/bin/agtermctl",
                      "/Applications/agterm.app/Contents/MacOS/agtermctl",
                      str(Path.home() / "Applications/agterm.app/Contents/MacOS/agtermctl"),
                      shutil.which("agtermctl") or ""]
        for candidate in candidates:
            if candidate and os.access(candidate, os.X_OK) and probe(candidate, "pick"):
                return candidate
        return ""

    def run(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        """run invokes agtermctl with the socket appended, never raising on a nonzero exit."""
        cmd = [self.bin, *args]
        if self.socket:
            cmd += ["--socket", self.socket]
        return subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)

    def foreground(self, pane: str) -> list[str]:
        """foreground returns the pane's live argv; the tree reports main and split only, so a
        scratch pane reads as a shell."""
        field = {"left": "foreground", "right": "splitForeground"}.get(pane, "")
        if not field or not self.sid:
            return []
        try:
            tree = json.loads(self.run("tree", "--json", "--window", self.window).stdout)["result"]["tree"]
        except (ValueError, KeyError) as err:
            log(f"tree read failed, so the pane reads as a shell: {err}")
            return []
        for workspace in tree.get("workspaces", []):
            for session in workspace.get("sessions", []):
                if session.get("id") == self.sid:
                    return [str(part) for part in (session.get(field) or [])]
        return []

    def pick(self, rows: list[dict[str, str]]) -> str:
        """pick opens the native picker and returns the chosen slug, "" when cancelled."""
        res = self.run("pick", "--prompt", "backlog", "--window", self.window, stdin=json.dumps(rows))
        if res.returncode == 2:
            return ""
        if res.returncode != 0:
            fail(f"picker failed (exit {res.returncode})", self)
        try:
            choice = json.loads(res.stdout)
        except ValueError:
            return ""
        return str(choice.get("id", "")) if choice.get("result") == "picked" else ""

    def type_line(self, line: str, pane: str) -> subprocess.CompletedProcess[str]:
        """type_line sends the command into the pane the chord fired from, Return included.

        The caller reports a nonzero exit. The pane can be gone by the time an item is picked - the
        split closed while the picker was open - and a dropped result is the one failure on the
        recipe's own path that would otherwise reach no channel at all.
        """
        return self.run("session", "type", line + "\n", "--target", self.sid or "active",
                        "--pane", pane)

    def notify(self, message: str) -> None:
        """notify is the only channel a keybinding has: its stdout goes to /dev/null."""
        if self.bin:
            self.run("notify", message, "--title", "Backlog")


def probe(binary: str, subcommand: str) -> bool:
    """probe reports whether the binary's top-level help offers the named subcommand."""
    try:
        res = subprocess.run([binary, "--help"], capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return any(line.startswith(f"  {subcommand}") for line in (res.stdout + res.stderr).splitlines())


def running_app_ctl() -> str:
    """running_app_ctl returns the agtermctl of the agterm process actually running, "" when none.

    pgrep is blind to GUI apps from here, so the process list is read directly.
    """
    try:
        res = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True, timeout=5,
                             check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in res.stdout.splitlines():
        if line.endswith("agterm.app/Contents/MacOS/agterm"):
            return str(Path(line).parent / "agtermctl")
    return ""


def repo_root(cwd: str) -> Path:
    """repo_root returns the repo the session sits in, or its cwd when that is not a repo.

    The chord can fire from any subdirectory, and docs/backlog lives at the root.
    """
    try:
        res = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=cwd, capture_output=True,
                             text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return Path(cwd)
    return Path(res.stdout.strip()) if res.returncode == 0 and res.stdout.strip() else Path(cwd)


def fail(message: str, agt: Agt | None = None) -> Any:
    """fail reports through the only channels a keybinding has, then exits."""
    log(message)
    print(f"backlog-picker: {message}", file=sys.stderr)
    if agt:
        agt.notify(message)
    sys.exit(1)


def command_for(slug: str, running: bool) -> str:
    """command_for is what gets typed: a slash command into a live claude, else one that starts it.

    The shell case is quoted with shlex, not by hand: the slug is a file name from the repo the
    session sits in, so a cloned tree can carry `a"; id; :"b.md`, and double quotes leave `$(...)`,
    backticks and a closing quote live. The TUI case needs no quoting - it is typed as text - and is
    safe from the same file name only because load_items refuses a slug carrying a newline.
    """
    return f"/backlog {slug}" if running else f"{CLAUDE_CMD} {shlex.quote(f'/backlog {slug}')}"


def main(argv: list[str]) -> int:
    cwd = os.environ.get("AGT_SESSION_PWD") or os.getcwd()
    pane = os.environ.get("AGT_PANE", "left")
    root = repo_root(cwd)
    items = load_items(root)

    if "--list" in argv:
        today = local_today()
        for item in items:
            print(f"{item.slug:46} {item.worth:6} {age_label(item.added, today):6} {item.where}")
        print(f"{len(items)} items in {root / BACKLOG_DIR}")
        return 0

    agt = Agt()
    if not agt.bin:
        fail(f"AGTERMCTL is not executable: {os.environ['AGTERMCTL']}" if os.environ.get("AGTERMCTL")
             else "no agtermctl with pick support found (the one on PATH is too old)")
    if not items:
        fail(f"no backlog items in {root / BACKLOG_DIR}", agt)

    chosen = agt.pick(items_of(items, local_today()))
    if not chosen:
        return 0
    if chosen not in {i.slug for i in items}:
        fail(f"picker returned an unknown item: {chosen}", agt)

    running = any(FG_MATCH.search(part) for part in agt.foreground(pane))
    res = agt.type_line(command_for(chosen, running), pane)
    if res.returncode != 0:
        fail(f"could not type into the {pane} pane: {res.stderr.strip() or f'exit {res.returncode}'}", agt)
    return 0


class Tests(unittest.TestCase):
    ITEM = ("---\n"
            "worth: later\n"
            "where: internal/store/reopen.go:537\n"
            "added: 2026-08-05\n"
            "---\n"
            "# reopen fallback ignores which window was last frontmost\n"
            "\n"
            "Body prose that is not the title.\n")

    def test_parse_item(self) -> None:
        item = parse_item(Path("/x/reopen-fallback.md"), self.ITEM, 1.0)
        self.assertEqual(item.slug, "reopen-fallback")
        self.assertEqual(item.title, "reopen fallback ignores which window was last frontmost")
        self.assertEqual(item.worth, "later")
        self.assertEqual(item.where, "internal/store/reopen.go:537")
        self.assertEqual(item.added, "2026-08-05")

    def test_parse_item_tolerates_missing_pieces(self) -> None:
        cases = [
            ("no frontmatter", "# just a title\n", "just a title", "", ""),
            ("no h1", "---\nworth: no\n---\nbody\n", "slug", "no", ""),
            ("unanchored", "---\nworth: yes\nadded: 2026-01-02\n---\n# t\n", "t", "yes", ""),
        ]
        for name, text, title, worth, where in cases:
            with self.subTest(name):
                item = parse_item(Path("/x/slug.md"), text, 1.0)
                self.assertEqual((item.title, item.worth, item.where), (title, worth, where))

    def test_parse_item_drops_an_unusable_added(self) -> None:
        for added in ["2026-8-5", "nonsense", "", "2026-13-01"]:
            with self.subTest(added):
                item = parse_item(Path("/x/slug.md"), f"---\nadded: {added}\n---\n# t\n", 1.0)
                self.assertEqual(item.added, "")
        item = parse_item(Path("/x/slug.md"), "---\nadded: 2026-08-05\n---\n# t\n", 1.0)
        self.assertEqual(item.added, "2026-08-05")

    def test_age_label(self) -> None:
        today = date(2026, 8, 5)
        for added, want in [("2026-08-05", "today"), ("2026-08-04", "1d"), ("2026-07-06", "30d"),
                            ("2026-06-01", "2mo"), ("2025-01-01", "1y"), ("", ""), ("nonsense", "")]:
            with self.subTest(added):
                self.assertEqual(age_label(added, today), want)

    def test_command_for(self) -> None:
        self.assertEqual(command_for("some-slug", running=True), "/backlog some-slug")
        self.assertEqual(command_for("some-slug", running=False), "claude '/backlog some-slug'")

    def test_command_for_quotes_a_hostile_slug(self) -> None:
        # a file name is attacker-authored in a cloned repo; the shell must see one argument
        for slug in ['a"; id; :"b', "x$(id)", "y`id`", "z'q"]:
            with self.subTest(slug):
                line = command_for(slug, running=False)
                self.assertEqual(shlex.split(line), ["claude", f"/backlog {slug}"])

    def test_items_of(self) -> None:
        today = date(2026, 8, 5)
        rows = items_of([Item("a", "title a", "yes", "f.go:1", "2026-08-05", 1.0),
                         Item("b", "title b", "later", "", "2026-01-01", 2.0),
                         Item("c", "title c", "", "", "", 3.0),
                         Item("d", "title d", "no", "", "2026-08-05", 4.0),
                         Item("e", "title e", "maybe", "", "2026-08-05", 5.0)], today)
        self.assertEqual(rows, [
            {"id": "a", "label": "title a", "subtitle": "worth fixing · today · f.go:1"},
            {"id": "b", "label": "title b", "subtitle": "worth fixing later · 6mo"},
            {"id": "c", "label": "title c", "subtitle": ""},
            {"id": "d", "label": "title d", "subtitle": "not worth fixing · today"},
            {"id": "e", "label": "title e", "subtitle": "maybe · today"},
        ])

    def test_load_items_is_newest_first(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / BACKLOG_DIR
            directory.mkdir(parents=True)
            for slug, added in [("old", "2026-01-01"), ("new", "2026-08-05"), ("mid", "2026-05-05")]:
                (directory / f"{slug}.md").write_text(f"---\nworth: yes\nadded: {added}\n---\n# {slug}\n")
            # two items added the same day fall back to mtime, which a day's granularity cannot split
            (directory / "same-day.md").write_text("---\nworth: yes\nadded: 2026-08-05\n---\n# same\n")
            os.utime(directory / "same-day.md", (0, 0))
            self.assertEqual([i.slug for i in load_items(Path(tmp))], ["new", "same-day", "mid", "old"])

    def test_resolve_bin_takes_the_override_as_given(self) -> None:
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = Path(tmp) / "agtermctl-wrapper"
            wrapper.write_text("#!/bin/sh\nexec true\n")   # no `pick` in its --help, so the probe would drop it
            wrapper.chmod(0o755)
            with mock.patch.dict(os.environ, {"AGTERMCTL": str(wrapper)}):
                self.assertEqual(Agt.resolve_bin(), str(wrapper))
            with mock.patch.dict(os.environ, {"AGTERMCTL": str(Path(tmp) / "not-there")}):
                self.assertEqual(Agt.resolve_bin(), "")

    def test_load_items_missing_dir(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(load_items(Path(tmp)), [])

    def test_load_items_refuses_a_control_character_in_the_name(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / BACKLOG_DIR
            directory.mkdir(parents=True)
            (directory / "ok.md").write_text("# ok\n")
            (directory / "bad\nrm -rf x.md").write_text("# bad\n")
            self.assertEqual([i.slug for i in load_items(Path(tmp))], ["ok"])


if __name__ == "__main__":
    if "--test" in sys.argv:
        sys.argv.remove("--test")
        unittest.main()
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
