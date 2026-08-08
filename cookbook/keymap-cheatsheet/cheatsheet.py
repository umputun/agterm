#!/usr/bin/env python3
"""The keyboard cheat sheet: keep it level with keymap.conf, then print it.

Two modes. `--sync` is the maintenance pass, run by the custom command before the
overlay opens. With no arguments the sheet goes to stdout, which is what runs
inside the overlay.

The sheet is hand-written, because what a chord is *for* is not in its action
name: `previous_attention_session` says what the code does, not that the chord
walks the sessions waiting on you and skips the ones still working. So nothing
here rewrites the sheet. The maintenance pass only ever appends a row for a
chord the sheet has no line about at all, and a model drafts that row so the
chord is documented from the moment it is bound rather than whenever you next
remember.

The gate is two-stage on purpose. The modification time is cheap and wrong on
its own: a comment edit in keymap.conf moves it, and it says nothing about which
chords changed. So the timestamp decides whether to look, and the chord set
decides whether to act. A press that follows no keymap change costs one stat.
"""

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

CONFIG = pathlib.Path(
    os.environ.get("AGTERM_CONFIG_DIR") or pathlib.Path.home() / ".config/agterm"
)
KEYMAP = pathlib.Path(os.environ.get("AGTERM_KEYMAP") or CONFIG / "keymap.conf")
SHEET = pathlib.Path(os.environ.get("AGTERM_CHEATSHEET") or CONFIG / "SHORTCUTS.md")
STAMP = pathlib.Path(
    os.environ.get("AGTERM_CHEATSHEET_STAMP")
    or pathlib.Path.home() / ".cache/agterm/keymap-cheatsheet/stamp"
)

# Beside the stamp: chord -> the keymap line that bound it, as of the last time the sheet
# was current. What the chord-set check cannot see is a chord that stayed bound while its
# binding changed underneath, which leaves a row that names the right chord and describes
# the wrong thing.
BINDINGS = STAMP.with_name("bindings.json")

AGTERMCTL = os.environ.get("AGTERMCTL") or "agtermctl"
# Resolved rather than assumed, because this decides whether drafting happens at all:
# an unresolvable name has to mean "fall back to the banner", not "fail mid-press".
CLAUDE_BIN = os.environ.get("CLAUDE_BIN") or shutil.which("claude") or ""
# The full id, not the "haiku" alias: the alias is not recognized here and falls back
# to the default model, which is a slower and dearer way to write one table row.
MODEL = os.environ.get("AGTERM_CHEATSHEET_MODEL", "claude-haiku-4-5-20251001")
DRAFT = os.environ.get("AGTERM_CHEATSHEET_DRAFT", "1") != "0"
TIMEOUT = int(os.environ.get("AGTERM_CHEATSHEET_TIMEOUT", "45"))

DRAFT_HEADING = "## Recently bound, drafted"
DRAFT_INTRO = (
    "Rows a model wrote when the chord appeared in `keymap.conf`. Move each one into the"
    " section it belongs in and put it in your own words; this is a holding area, not a"
    " section of the sheet."
)

SYSTEM_PROMPT = (
    "You document keyboard shortcuts for a terminal. For each binding you are given, write"
    " what pressing it does, from the point of view of someone reaching for it. At most 12"
    " words, no trailing period, no chord repeated back, no marketing. Read the action name"
    " and any script path for what the binding actually does. Say plainly when you cannot"
    " tell: 'runs <script name>' beats an invention."
)

SCHEMA = json.dumps({
    "type": "object",
    "properties": {
        "rows": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"chord": {"type": "string"}, "does": {"type": "string"}},
                "required": ["chord", "does"],
            },
        }
    },
    "required": ["rows"],
})

# `map <chord> <action>`, and `command "<name>" [chord] <shell...>` where the chord is
# optional: a command with no chord is palette-only and has none to document. Requiring
# a modifier prefix is what tells the two apart, since the shell word that follows a
# chordless command never starts with a modifier and a `+`.
#
# Leading whitespace is allowed because agterm's parser trims the line before reading the
# verb, so an indented binding is a live binding. Every modifier spelling agterm accepts is
# listed, and the match is case-insensitive, for the same reason: `alt+k` and `Control+K`
# bind real chords, and a chord this misses is a chord that is never documented.
MODS = r"ctrl|control|cmd|command|opt|option|alt|shift"
MAP_LINE = re.compile(r"^[ \t]*map\s+(\S+)\s+(\S+)", re.MULTILINE)
COMMAND_LINE = re.compile(r'^[ \t]*command\s+"([^"]*)"\s+((?:' + MODS + r')\+\S*)',
                          re.MULTILINE | re.IGNORECASE)

STARTER_HEAD = """# Keyboard shortcuts

Generated from `keymap.conf` on the first run, as a starting point. Rewrite the
right-hand column in your own words: an action name says what the code does, not
why you reach for the chord.

| chord | does |
|---|---|
"""


def bindings(keymap):
    """Chord and label for every chord-carrying binding, `map` lines first."""
    pairs = [(chord, action.replace("_", " ")) for chord, action in MAP_LINE.findall(keymap)]
    pairs += [(chord, name) for name, chord in COMMAND_LINE.findall(keymap)]
    return pairs


def starter(pairs):
    rows = "".join(f"| `{chord}` | {label} |\n" for chord, label in pairs)
    return STARTER_HEAD + rows


def documented(chord, flat):
    """Is this chord named in the sheet, as a whole chord rather than as a prefix?

    A plain substring test is what you reach for first and it is wrong in a way that shows
    up immediately: `cmd+ctrl+shift+s` is a substring of `cmd+ctrl+shift+space`, so binding
    the first while the sheet documents the second reports it as already written up. The
    boundaries below are what a chord can be continued by — a word character, `+`, or the
    `>` of a leader sequence. `>` is in both of them: a row for `ctrl+x>ctrl+a` documents
    that sequence, not the bare `ctrl+a` it happens to end with.
    """
    pattern = r"(?<![\w+>])" + re.escape(chord) + r"(?![\w+>])"
    return re.search(pattern, flat) is not None


def searchable(sheet):
    """The part of the sheet a chord has to be found in: its table rows.

    Prose does not count, and that is the point. A sheet says two different things about a
    chord — "this is what it does", which is an entry, and "this one is still free", which
    is a note. Both name the chord, so a whole-file search accepts the second as
    documentation of the first, and a stale "still free" line then hides a chord someone
    bound months ago. Entries live in tables here, so the tables are what is searched.

    A sheet with no table at all falls back to the whole text, because reporting every
    chord as missing is not a useful thing to tell someone who writes in paragraphs.
    """
    rows = [line for line in sheet.splitlines() if line.lstrip().startswith("|")]
    return "\n".join(rows) if rows else sheet


def undocumented(pairs, sheet):
    # The sheet is searched with its markdown intact. Stripping the backticks first is the
    # obvious move and it breaks the one chord whose key IS a backtick: `cmd+ctrl+`` would
    # shrink to a bare `cmd+ctrl+` and match almost any row. Left in place, a chord written
    # the markdown way — `cmd+ctrl+j`, or ``cmd+ctrl+` `` for the awkward one — contains the
    # chord as a literal substring either way, and the boundary rule below does the rest.
    flat = searchable(sheet)
    return sorted({chord for chord, _ in pairs if not documented(chord, flat)})


def binding_lines(keymap):
    """Chord -> the whole keymap line that binds it."""
    lines = {}
    for line in keymap.splitlines():
        stripped = line.strip()
        for match in (MAP_LINE.match(stripped), COMMAND_LINE.match(stripped)):
            if match:
                chord = match.group(1) if match.re is MAP_LINE else match.group(2)
                lines[chord] = stripped
    return lines


def rebound(keymap, sheet):
    """Documented chords whose binding changed since the sheet was last touched.

    The comparison is against the sheet's own modification time, so it needs no
    acknowledgement: edit the sheet and every chord is taken as described correctly again,
    leave it alone and the same chords are named on every press until you do.
    """
    if not BINDINGS.exists():
        return []
    try:
        before = json.loads(BINDINGS.read_text())
        if SHEET.stat().st_mtime_ns > BINDINGS.stat().st_mtime_ns:
            return []
    except (OSError, json.JSONDecodeError):
        return []
    flat = searchable(sheet)
    return sorted(chord for chord, line in binding_lines(keymap).items()
                  if chord in before and before[chord] != line and documented(chord, flat))


def source_lines(keymap, chords):
    """The keymap lines binding these chords, which is what the model reads."""
    wanted = set(chords)
    out = []
    for line in keymap.splitlines():
        stripped = line.strip()
        if not stripped.startswith(("map ", "command ")):
            continue
        for chord in wanted:
            if re.search(r"(?<![^\s])" + re.escape(chord) + r"(?!\S)", stripped):
                out.append(stripped)
                break
    return out


class Hud:
    """The progress panel, posted over the session while the model is out.

    A session holds one overlay slot, and a HUD and a program overlay compete for it. So
    this only works before the cheat sheet overlay opens, which is why the maintenance
    pass runs from the custom command rather than from inside the overlay.

    Every failure here is swallowed. A panel that will not post must never be the reason
    a keypress shows no cheat sheet.
    """

    def __init__(self):
        self.sid = os.environ.get("AGT_SESSION_ID", "")
        self.socket = os.environ.get("AGT_SOCKET", "")
        self.up = False

    def _run(self, *args):
        cmd = [AGTERMCTL, *args]
        if self.socket:
            cmd += ["--socket", self.socket]
        try:
            return subprocess.run(cmd, capture_output=True, text=True, check=False)
        except OSError:
            return None

    def show(self, detail):
        if not self.sid:
            return
        res = self._run("session", "hud", "update" if self.up else "open", "cheat sheet",
                        "--detail", detail, "--spinner-style", "braille", "--target", self.sid)
        self.up = self.up or (res is not None and res.returncode == 0)

    def close(self):
        if self.up:
            self._run("session", "hud", "close", "--target", self.sid)
            self.up = False


def draft(lines, chords, hud):
    """Ask the model for one row per binding. None on any failure, so the sheet still opens."""
    if not CLAUDE_BIN:
        return None
    wanted = set(chords)
    body = "Document these agterm keybindings:\n\n" + "\n".join(lines)

    # Output goes to a temp file rather than a pipe. Nothing reads a pipe until the poll
    # loop below ends, so a child that writes more than the buffer holds would block on its
    # next write and leave the press sitting under the spinner for the whole timeout.
    with tempfile.TemporaryFile("w+") as out:
        try:
            proc = subprocess.Popen(
                [CLAUDE_BIN, "-p", "--model", MODEL, "--safe-mode", "--no-session-persistence",
                 # No tools, and no hooks: a SessionStart hook that prints anything lands in
                 # this output, and a headless one-shot has no use for either.
                 "--tools", "", "--settings", '{"hooks":{}}',
                 "--output-format", "json", "--system-prompt", SYSTEM_PROMPT,
                 "--json-schema", SCHEMA, body],
                stdout=out, stderr=subprocess.DEVNULL, text=True,
                env={**os.environ, "MAX_THINKING_TOKENS": "0"})
        except (OSError, subprocess.SubprocessError):
            return None

        started = time.monotonic()
        while proc.poll() is None:
            elapsed = int(time.monotonic() - started)
            if elapsed > TIMEOUT:
                proc.kill()
                return None
            plural = "" if len(lines) == 1 else "s"
            hud.show(f"drafting {len(lines)} new chord{plural} · {elapsed}s")
            time.sleep(0.7)

        try:
            out.seek(0)
            payload = json.loads(out.read())
            result = payload.get("result", payload)
            rows = (json.loads(result) if isinstance(result, str) else result).get("rows", [])
            # Only rows for chords that were actually asked about. A model answering
            # `Cmd+Ctrl+M` to a requested `cmd+ctrl+m` would otherwise add a row that never
            # satisfies the check, and add it again on every keymap edit, for ever.
            kept = [r for r in rows if r.get("chord") in wanted and r.get("does")]
        except (json.JSONDecodeError, AttributeError, TypeError):
            return None
    return kept or None


def cell(text):
    """Make a string safe to sit in a markdown table cell.

    The model is asked for one short line and normally sends one, but its answer is written
    into the reader's own file: a stray `|` would split the row into extra columns and a
    newline would end the table and leave the rest as loose prose. Neither is recoverable by
    hand without knowing what the file looked like before.
    """
    flat = " ".join(str(text).split())
    return flat.replace("|", "\\|")


def append_rows(sheet, rows):
    """Add the drafted rows to the holding section, creating it at the end when absent.

    Only ever an append. The sheet's own tables are hand-arranged — one of them pairs two
    chords per row across four columns — so a generic inserter aiming for the right
    section would corrupt the thing it is trying to keep current.
    """
    body = "".join(f"| `{cell(r['chord'])}` | {cell(r['does'])} |\n" for r in rows)
    if DRAFT_HEADING in sheet:
        return sheet.rstrip("\n") + "\n" + body
    return (sheet.rstrip("\n") + "\n\n" + DRAFT_HEADING + "\n\n" + DRAFT_INTRO
            + "\n\n| chord | does |\n|---|---|\n" + body)


def write(path, text):
    """Write through a temp file in the same directory, so a killed run leaves no half file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else None
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    # The replace swaps the inode, so a sheet the reader chmodded would come back at the
    # umask default. Carry its bits over rather than quietly widening them.
    if mode is not None:
        tmp.chmod(mode)
    tmp.replace(path)


def snapshot(keymap):
    """Record what each chord is bound to now, as the baseline `rebound` compares against."""
    write(BINDINGS, json.dumps(binding_lines(keymap), sort_keys=True, indent=1))


def sync(keymap):
    """The maintenance pass: draft rows for chords the sheet has never heard of."""
    # Seeding happens BEFORE the gate. On an existing install the stamp is already current,
    # so anything after the gate would wait for the next keymap edit — and that edit is
    # exactly the one that could rebind a chord with no baseline to notice it against.
    if SHEET.exists() and not BINDINGS.exists():
        snapshot(keymap)

    mtime = str(KEYMAP.stat().st_mtime_ns)
    if STAMP.exists() and STAMP.read_text() == mtime:
        return

    pairs = bindings(keymap)
    if not SHEET.exists():
        write(SHEET, starter(pairs))
        write(STAMP, mtime)
        snapshot(keymap)
        return

    # A sheet newer than the baseline has been edited since, so take it as describing what
    # is bound now.
    if SHEET.stat().st_mtime_ns > BINDINGS.stat().st_mtime_ns:
        snapshot(keymap)

    missing = undocumented(pairs, SHEET.read_text())
    if not missing:
        write(STAMP, mtime)
        return
    if not DRAFT:
        return

    hud = Hud()
    try:
        rows = draft(source_lines(keymap, missing), missing, hud)
    finally:
        hud.close()
    if not rows:
        return
    write(SHEET, append_rows(SHEET.read_text(), rows))
    write(STAMP, mtime)
    snapshot(keymap)


def render(keymap):
    """Print the sheet, with a banner naming anything still undocumented."""
    pairs = bindings(keymap)
    if not SHEET.exists():
        write(SHEET, starter(pairs))
        print(f"> **Generated `{SHEET}` from your keymap.**")
        print(">")
        print("> Rewrite it in your own words. This run shows what was written.")
        print()

    sheet = SHEET.read_text()
    missing = undocumented(pairs, sheet)
    if missing:
        print(f"> **This sheet has drifted from `{KEYMAP.name}`.**")
        print(">")
        print("> Bound but not documented: " + ", ".join(f"`{c}`" for c in missing))
        print()

    changed = rebound(keymap, sheet)
    if changed:
        print("> **Bound to something else now, so the row may be stale:** "
              + ", ".join(f"`{c}`" for c in changed))
        print(">")
        print("> Edit the sheet and this clears itself.")
        print()

    sys.stdout.write(sheet)


def main():
    try:
        keymap = KEYMAP.read_text()
    except OSError as err:
        sys.exit(f"cannot read {KEYMAP}: {err}")

    if "--sync" in sys.argv[1:]:
        sync(keymap)
        return
    render(keymap)


if __name__ == "__main__":
    main()
