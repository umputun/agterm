#!/usr/bin/env python3
"""Pick a SQLite database from THIS session's repo and open it in a TUI viewer, in an overlay.

Runs as an agterm keymap custom command, so the runner exports $AGT_*, widens PATH with the CLI and
Homebrew directories, and pins stdout to /dev/null.

Candidates are files under the repo root carrying a database extension AND starting with the SQLite
magic header, so a `.db` that is really a Berkeley DB or a text file never reaches the picker. The
extension is a speed filter only - reading 16 bytes of every file in a large tree is what it avoids -
so a database stored under an unusual name is not found. Newest first: the one just written is the
one being debugged.

Usage: sqlite-browser.py [--list] [--test]
    --list  print the databases found and exit, without opening the picker
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path
from typing import Any, NamedTuple

MAGIC = b"SQLite format 3\x00"
EXTS = {".db", ".db3", ".sqlite", ".sqlite3", ".sqlitedb"}
# a checkout carries whole dependency trees with their own fixtures; those are never the database the
# session is working on, and walking them is most of the scan. Hidden directories go too, as a rule
# rather than a list: .mypy_cache alone put 32 of its own sqlite files ahead of every real one in a
# repo tried during development, and .pytest_cache, .tox and .venv are the same shape.
PRUNE = {"node_modules", "vendor", "venv", "__pycache__", "site-packages", "target", "Pods"}
# agterm's picker refuses a longer list outright (ControlPickItem.maxItems) rather than truncating it,
# so a tree with more databases than this would open no picker at all. Rows are newest-first, so the
# cut falls on the least interesting end.
MAX_ROWS = 1000
# tabiew: it opens ON the data - every table of the database becomes a tab, H/L cycles them, `:schema`
# lists them with column stats. The SQL clients tried first (lazysql, harlequin, rainfrog, dblab) all
# open on an empty editor or a logo instead. The format is passed rather than inferred: tabiew maps
# only .db and .sqlite by extension, and this picker also finds .db3, .sqlite3 and .sqlitedb.
VIEWER = os.environ.get("SQLITE_VIEWER", "tw")
VIEWER_ARGS = shlex.split(os.environ.get("SQLITE_VIEWER_ARGS", "-f sqlite"))
OVERLAY_PERCENT = os.environ.get("SQLITE_OVERLAY_PERCENT", "90")
LOG = Path(os.environ.get("SQLITE_BROWSER_LOG", "/tmp/sqlite-browser.log"))
HUD_SECONDS = float(os.environ.get("SQLITE_HUD_SECONDS", "3"))
HUD_BG = os.environ.get("SQLITE_HUD_BG", "#4a3c12")
HUD_FG = os.environ.get("SQLITE_HUD_FG", "#f0d890")
HUD_WIDTH = os.environ.get("SQLITE_HUD_WIDTH", "40")


class Db(NamedTuple):
    """Db is one SQLite file found under the repo root."""

    rel: str      # path relative to the root, which is what the picker shows and returns
    path: Path
    size: int
    mtime: float


def log(message: str) -> None:
    """log appends a line to the run log; a keybinding has no stdout anyone reads."""
    try:
        with LOG.open("a") as fh:
            fh.write(f"{time.strftime('%F %T')}  {message}\n")
    except OSError:
        pass


def is_sqlite(path: Path) -> bool:
    """is_sqlite reads the file header; the extension alone proves nothing about the format.

    An unreadable file is logged rather than dropped quietly: it looks identical to a wrong-format one
    in the result, and a permission error is the whole explanation for a database that never appears.
    """
    try:
        with path.open("rb") as fh:
            return fh.read(len(MAGIC)) == MAGIC
    except OSError as err:
        log(f"skipped {path}: {err}")
        return False


def find_dbs(root: Path) -> list[Db]:
    """find_dbs walks the repo for SQLite files, newest first.

    Symlinked directories are not followed: a checkout carrying a link back to a parent (or to a home
    directory) would otherwise turn the scan into an unbounded walk of the filesystem. A database
    inside a hidden or dependency directory is not offered - see PRUNE.

    A name carrying a control character is refused. The path reaches a shell command line, and a
    newline in it would start a line of its own.
    """
    found: list[Db] = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in PRUNE and not d.startswith(".")]
        for name in filenames:
            path = Path(dirpath) / name
            # is_file before is_sqlite, and both follow the link: opening a FIFO read-only blocks until
            # something writes to it, and a chord whose stdout is /dev/null would hang with no sign of it.
            if path.suffix.lower() not in EXTS or not path.is_file() or not is_sqlite(path):
                continue
            rel = str(path.relative_to(root))
            if any(ch < " " or ch == "\x7f" for ch in rel):
                log(f"skipped {path!r}: control character in the path")
                continue
            try:
                stat = path.stat()
            except OSError as err:
                log(f"skipped {path}: {err}")
                continue
            found.append(Db(rel=rel, path=path, size=stat.st_size, mtime=stat.st_mtime))
    return sorted(found, key=lambda d: d.mtime, reverse=True)


def human_size(size: int) -> str:
    """human_size renders a byte count for a one-line subtitle."""
    for unit in ("B", "K", "M", "G"):
        if size < 1024 or unit == "G":
            return f"{size:.0f}{unit}" if unit == "B" or size >= 10 else f"{size:.1f}{unit}"
        size /= 1024.0  # type: ignore[assignment]
    return f"{size}B"


def age_label(mtime: float, now: float) -> str:
    """age_label says how long ago the file was written; a live database is the one being worked on."""
    seconds = max(0.0, now - mtime)
    if seconds < 90:
        return "just now"
    for limit, div, unit in ((3600, 60, "m"), (86400, 3600, "h"), (86400 * 31, 86400, "d")):
        if seconds < limit:
            return f"{int(seconds // div)}{unit} ago"
    return f"{int(seconds // (86400 * 31))}mo ago"


def rows_of(dbs: list[Db], now: float) -> list[dict[str, str]]:
    """rows_of renders the picker rows: the path, then its size and how fresh it is."""
    return [{"id": db.rel, "label": db.rel, "subtitle": f"{human_size(db.size)} · {age_label(db.mtime, now)}"}
            for db in dbs]


def viewer_command(path: Path, viewer: str) -> str:
    """viewer_command is the shell line the overlay runs.

    The viewer is spelled absolutely and the path is quoted: the overlay is spawned with the app's GUI
    PATH, which holds neither /opt/homebrew/bin nor the repo, and a checked-out file name can carry
    `$(...)`, a backtick or a quote.
    """
    return " ".join(shlex.quote(part) for part in (viewer, *VIEWER_ARGS, str(path)))


class Agt:
    """Agt is the agterm control channel: agtermctl plus this session's addressing."""

    def __init__(self) -> None:
        self.bin = self.resolve_bin()
        self.socket = os.environ.get("AGT_SOCKET", "")
        self.sid = os.environ.get("AGT_SESSION_ID", "")
        self.window = os.environ.get("AGT_WINDOW_ID", "active")

    @staticmethod
    def resolve_bin() -> str:
        """resolve_bin returns the agtermctl to drive, "" when there is none to run.

        A plain PATH lookup is enough from 0.22.0 on: the custom-command runner widens the child's PATH
        with the CLI install directory and Homebrew's prefix before spawning it.
        """
        override = os.environ.get("AGTERMCTL", "")
        if override:
            return override if os.access(override, os.X_OK) else ""
        return shutil.which("agtermctl") or ""

    def run(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
        """run invokes agtermctl with the socket appended, never raising on a nonzero exit."""
        cmd = [self.bin, *args]
        if self.socket:
            cmd += ["--socket", self.socket]
        return subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)

    def pick(self, rows: list[dict[str, str]], dropped: int = 0) -> str:
        """pick opens the native picker and returns the chosen path, "" when cancelled.

        The prompt says when the list was cut, since a truncation nothing names reads as the whole tree.
        """
        prompt = f"sqlite (newest {len(rows)} of {len(rows) + dropped})" if dropped else "sqlite"
        res = self.run("pick", "--prompt", prompt, "--window", self.window, stdin=json.dumps(rows))
        if res.returncode == 2:
            return ""
        if res.returncode != 0:
            fail(f"picker failed: {res.stderr.strip() or f'exit {res.returncode}'}", self)
        # not a quiet "" here: a cancel is exit 2 and was handled above, so exit 0 owes us the result
        # JSON, and treating a body we cannot read as a cancel would turn the failure into a dead key.
        try:
            choice = json.loads(res.stdout)
        except ValueError:
            fail(f"picker returned no readable result: {res.stdout.strip()[:120]!r}", self)
        return str(choice.get("id", "")) if choice.get("result") == "picked" else ""

    def overlay(self, command: str) -> subprocess.CompletedProcess[str]:
        """overlay runs the viewer on top of the session the chord fired from.

        No --follow: the overlay belongs to this session, and pulling the user to it would move the
        selection out from under whatever he is doing elsewhere.
        """
        return self.run("session", "overlay", "open", f"zsh -c {shlex.quote(command)}",
                        "--size-percent", OVERLAY_PERCENT, "--target", self.sid or "active")

    def notify(self, message: str) -> None:
        """notify is the fallback channel: a keybinding's stdout goes to /dev/null."""
        if self.bin:
            self.run("notify", message, "--title", "SQLite")

    def hud(self, message: str, seconds: float, detail: str = "") -> bool:
        """hud posts a passive panel at the top of the session, then takes it down.

        Preferred over a desktop notification for a state the chord itself produced: the panel appears
        over the session the key was pressed in, leaves it focused and typable, and needs no visit to
        Notification Center. False when the panel could not be posted at all.
        """
        target = self.sid or "active"
        args = ["session", "hud", "open", message, "--position", "top-center", "--target", target,
                "--background-color", HUD_BG, "--text-color", HUD_FG,
                "--size-percent", HUD_WIDTH]
        if detail:
            args += ["--detail", detail]
        if self.run(*args).returncode != 0:
            return False
        time.sleep(seconds)
        self.run("session", "hud", "close", "--target", target)
        return True


def resolve_viewer() -> str:
    """resolve_viewer returns the viewer's absolute path, "" when it is not installed.

    Absolute because of where the name is going, not where it is resolved: the OVERLAY is spawned with
    the app's own PATH, which no runner widens, so a bare viewer name exits 127 there. The directory
    ladder runs ahead of the lookup for a PATH that reaches this script without Homebrew's prefix.
    """
    if os.path.isabs(VIEWER):
        return VIEWER if os.access(VIEWER, os.X_OK) else ""
    for directory in ("/opt/homebrew/bin", "/usr/local/bin", str(Path.home() / "bin"), "/usr/bin"):
        candidate = os.path.join(directory, VIEWER)
        if os.access(candidate, os.X_OK):
            return candidate
    return shutil.which(VIEWER) or ""


def repo_root(cwd: str) -> Path:
    """repo_root returns the repo the session sits in, or its cwd when that is not a repo.

    The chord can fire from any subdirectory, and a database can sit anywhere under the root.
    """
    try:
        res = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=cwd, capture_output=True,
                             text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return Path(cwd)
    return Path(res.stdout.strip()) if res.returncode == 0 and res.stdout.strip() else Path(cwd)


def scan_root() -> Path | None:
    """scan_root resolves the tree to walk, None when there is no session behind the chord.

    The three states of AGT_SESSION_PWD are three different situations and only the variable tells them
    apart. UNSET is a plain shell run, so the shell's own cwd is the subject. SET AND EMPTY is the chord
    firing in a window holding no session: agterm exports every token whether or not it resolved, and
    leaves the child in the APP's working directory, which is / for a Dock-launched bundle. Reading that
    as "no value, use the cwd" is what turns one keypress into a walk of the whole filesystem, a TCC
    prompt per protected folder, and a picker listing personal databases.
    """
    pwd = os.environ.get("AGT_SESSION_PWD")
    if pwd is None:
        return repo_root(os.getcwd())
    return repo_root(pwd) if pwd else None


def too_broad(root: Path) -> str:
    """too_broad names what the root would drag in, "" when it is safe to walk.

    Only reachable when git found no repo, since a repo root is neither of these. The home directory is
    the one that actually happens: a shell opened there scans ~/Library's hundreds of application
    databases and raises a macOS permission prompt for every protected folder on the way. A non-repo
    subdirectory is left alone — that is a normal place to keep a database.
    """
    if root == Path(root.root):
        return "the whole filesystem"
    if root == Path.home():
        return "the whole home directory"
    return ""


def fail(message: str, agt: Agt | None = None) -> Any:
    """fail reports through the only channels a keybinding has, then exits."""
    log(message)
    print(f"sqlite-browser: {message}", file=sys.stderr)
    if agt:
        agt.notify(message)
    sys.exit(1)


def announce(agt: Agt, message: str, detail: str) -> None:
    """announce says a normal empty-handed outcome over the session, falling back to a notification."""
    log(f"{message}: {detail}")
    if not agt.hud(f"ⓘ  {message}", HUD_SECONDS, detail=detail):
        agt.notify(f"{message}: {detail}")


def main(argv: list[str]) -> int:
    root = scan_root()

    if "--list" in argv:
        root = root or repo_root(os.getcwd())
        dbs, now = find_dbs(root), time.time()
        for db in dbs:
            print(f"{db.rel:60} {human_size(db.size):>7}  {age_label(db.mtime, now)}")
        print(f"{len(dbs)} databases under {root}")
        return 0

    agt = Agt()
    if not agt.bin:
        fail(f"AGTERMCTL is not executable: {os.environ['AGTERMCTL']}" if os.environ.get("AGTERMCTL")
             else "no agtermctl found; install the command line tool or set AGTERMCTL")

    if root is None:
        # not announce: with no session there is no target, so the hud and the notification both
        # resolve `active` to nothing. A nonzero exit is the one channel left — agterm banners it.
        fail("no session here: the chord needs a session to take its directory from", agt)
    if reason := too_broad(root):
        announce(agt, f"refusing to scan {reason}", f"this session's directory is {root}")
        return 0

    viewer = resolve_viewer()
    if not viewer:
        announce(agt, f"{VIEWER} is not installed", f"brew install {VIEWER}")
        return 0

    dbs = find_dbs(root)
    if not dbs:
        announce(agt, "no sqlite databases", str(root))
        return 0

    shown, dropped = dbs[:MAX_ROWS], max(0, len(dbs) - MAX_ROWS)
    if dropped:
        log(f"{dropped} databases past the picker's {MAX_ROWS}-item cap were not offered")

    chosen = agt.pick(rows_of(shown, time.time()), dropped)
    if not chosen:
        return 0
    picked = next((db for db in shown if db.rel == chosen), None)
    if not picked:
        fail(f"picker returned an unknown database: {chosen}", agt)

    res = agt.overlay(viewer_command(picked.path, viewer))
    if res.returncode != 0:
        fail(f"could not open the overlay: {res.stderr.strip() or f'exit {res.returncode}'}", agt)
    return 0


class Tests(unittest.TestCase):
    def db_tree(self, tmp: str) -> Path:
        root = Path(tmp)
        (root / "sub").mkdir()
        (root / "node_modules" / "pkg").mkdir(parents=True)
        (root / "app.db").write_bytes(MAGIC + b"rest")
        (root / "sub" / "cache.sqlite3").write_bytes(MAGIC + b"rest")
        (root / "notes.db").write_bytes(b"this is a text file pretending")   # right name, wrong format
        (root / "app.db-wal").write_bytes(MAGIC + b"rest")                   # sidecar, not a database
        (root / "readme.md").write_bytes(MAGIC + b"rest")                    # magic, wrong extension
        (root / "node_modules" / "pkg" / "fixture.db").write_bytes(MAGIC + b"rest")
        (root / ".mypy_cache").mkdir()
        (root / ".mypy_cache" / "cache.db").write_bytes(MAGIC + b"rest")   # a tool cache, not the repo's data
        return root

    def test_find_dbs_takes_only_real_databases(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = self.db_tree(tmp)
            os.utime(root / "app.db", (0, 0))   # older, so the sort has something to order
            self.assertEqual([db.rel for db in find_dbs(root)], ["sub/cache.sqlite3", "app.db"])

    def test_find_dbs_does_not_follow_a_directory_symlink(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            (root / "inner").mkdir(parents=True)
            (root / "inner" / "real.db").write_bytes(MAGIC)
            (root / "loop").symlink_to(root)   # a walk that followed this would never finish
            self.assertEqual([db.rel for db in find_dbs(root)], ["inner/real.db"])

    def test_find_dbs_skips_a_fifo(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "real.db").write_bytes(MAGIC)
            os.mkfifo(root / "pipe.db")   # reading this one would block until something writes to it
            self.assertEqual([db.rel for db in find_dbs(root)], ["real.db"])

    def test_find_dbs_refuses_a_control_character(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ok.db").write_bytes(MAGIC)
            (root / "bad\nrm -rf x.db").write_bytes(MAGIC)
            self.assertEqual([db.rel for db in find_dbs(root)], ["ok.db"])

    def test_human_size(self) -> None:
        for size, want in [(0, "0B"), (512, "512B"), (1536, "1.5K"), (20480, "20K"),
                           (5 * 1024 * 1024, "5.0M"), (3 * 1024**3, "3.0G")]:
            with self.subTest(size):
                self.assertEqual(human_size(size), want)

    def test_age_label(self) -> None:
        now = 1_000_000.0
        for delta, want in [(0, "just now"), (60, "just now"), (600, "10m ago"), (7200, "2h ago"),
                            (86400 * 3, "3d ago"), (86400 * 90, "2mo ago")]:
            with self.subTest(delta):
                self.assertEqual(age_label(now - delta, now), want)

    def test_rows_of(self) -> None:
        now = 1_000_000.0
        rows = rows_of([Db("app.db", Path("/r/app.db"), 1536, now - 600)], now)
        self.assertEqual(rows, [{"id": "app.db", "label": "app.db", "subtitle": "1.5K · 10m ago"}])

    def test_viewer_command_quotes_a_hostile_path(self) -> None:
        # a checked-out file name is attacker-authored; zsh -c must see one argument
        for name in ['a"; id; :"b.db', "x$(id).db", "y`id`.db", "z'q.db"]:
            with self.subTest(name):
                line = viewer_command(Path("/r") / name, "/opt/homebrew/bin/tw")
                self.assertEqual(shlex.split(line),
                                 ["/opt/homebrew/bin/tw", *VIEWER_ARGS, f"/r/{name}"])

    def test_resolve_viewer_takes_an_absolute_override_as_given(self) -> None:
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "myviewer"
            binary.write_text("#!/bin/sh\n")
            binary.chmod(0o755)
            with mock.patch.object(sys.modules[__name__], "VIEWER", str(binary)):
                self.assertEqual(resolve_viewer(), str(binary))
            with mock.patch.object(sys.modules[__name__], "VIEWER", str(Path(tmp) / "gone")):
                self.assertEqual(resolve_viewer(), "")

    def test_resolve_bin_takes_an_executable_override_as_given(self) -> None:
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "agtermctl"
            binary.write_text("#!/bin/sh\n")
            binary.chmod(0o755)
            with mock.patch.dict(os.environ, {"AGTERMCTL": str(binary)}):
                self.assertEqual(Agt.resolve_bin(), str(binary))
            with mock.patch.dict(os.environ, {"AGTERMCTL": str(Path(tmp) / "gone")}):
                self.assertEqual(Agt.resolve_bin(), "")

    def test_scan_root_tells_the_three_pwd_states_apart(self) -> None:
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "session"
            session.mkdir()
            with mock.patch.object(sys.modules[__name__], "repo_root", Path):
                with mock.patch.dict(os.environ):
                    os.environ.pop("AGT_SESSION_PWD", None)
                    self.assertEqual(scan_root(), Path(os.getcwd()))
                with mock.patch.dict(os.environ, {"AGT_SESSION_PWD": ""}):
                    self.assertIsNone(scan_root())
                with mock.patch.dict(os.environ, {"AGT_SESSION_PWD": str(session)}):
                    self.assertEqual(scan_root(), session)

    def test_too_broad_refuses_the_root_and_the_home_directory(self) -> None:
        self.assertEqual(too_broad(Path("/")), "the whole filesystem")
        self.assertEqual(too_broad(Path.home()), "the whole home directory")
        self.assertEqual(too_broad(Path.home() / "dev" / "project"), "")
        self.assertEqual(too_broad(Path("/opt/data")), "")

    def test_pick_prompt_names_a_truncated_list(self) -> None:
        from unittest import mock
        for dropped, want in ((0, "sqlite"), (5, "sqlite (newest 2 of 7)")):
            with self.subTest(dropped=dropped):
                agt = Agt.__new__(Agt)
                agt.bin, agt.socket, agt.sid, agt.window = "/x/agtermctl", "", "sid-1", "active"
                calls: list[tuple[str, ...]] = []
                with mock.patch.object(Agt, "run", lambda self, *a, _c=calls, **kw: _c.append(a) or
                                       subprocess.CompletedProcess(a, 2, "", "")):
                    agt.pick([{"id": "a"}, {"id": "b"}], dropped)
                self.assertEqual(calls[0][2], want)

    def test_pick_failure_carries_the_server_reason(self) -> None:
        import tempfile
        from unittest import mock
        agt = Agt.__new__(Agt)
        agt.bin, agt.socket, agt.sid, agt.window = "/x/agtermctl", "", "sid-1", "active"
        said = []

        def fake_run(self: Agt, *args: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
            if args[0] == "notify":
                said.append(args[1])
                return subprocess.CompletedProcess(args, 0, "", "")
            return subprocess.CompletedProcess(args, 1, "", "too many items (max 1000)\n")

        with tempfile.TemporaryDirectory() as tmp, open(os.devnull, "w") as quiet, \
             mock.patch.object(sys.modules[__name__], "LOG", Path(tmp) / "log"), \
             mock.patch.object(Agt, "run", fake_run), \
             mock.patch.object(sys, "stderr", quiet), \
             self.assertRaises(SystemExit):
            agt.pick([{"id": "a"}])
        self.assertEqual(said, ["picker failed: too many items (max 1000)"])

    def test_overlay_targets_this_session(self) -> None:
        from unittest import mock
        agt = Agt.__new__(Agt)
        agt.bin, agt.socket, agt.sid, agt.window = "/x/agtermctl", "", "sid-1", "active"
        calls = []
        with mock.patch.object(Agt, "run", lambda self, *a, **kw: calls.append(a) or
                               subprocess.CompletedProcess(a, 0, "", "")):
            agt.overlay("/opt/homebrew/bin/tw -f sqlite /r/app.db")
        self.assertEqual(calls, [("session", "overlay", "open",
                                  "zsh -c '/opt/homebrew/bin/tw -f sqlite /r/app.db'",
                                  "--size-percent", OVERLAY_PERCENT, "--target", "sid-1")])


if __name__ == "__main__":
    if "--test" in sys.argv:
        sys.argv.remove("--test")
        unittest.main()
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
