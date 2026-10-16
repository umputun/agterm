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
def _seconds(value, fallback):
    """A timeout that will not parse falls back rather than raising at import.

    This module is also what the overlay runs, and an exception there means an empty stream,
    a pager with nothing to show and an overlay that closes on the spot — the very symptom
    the recipe exists to avoid.
    """
    try:
        return max(1, int(value))
    except (TypeError, ValueError):
        return fallback


TIMEOUT = _seconds(os.environ.get("AGTERM_CHEATSHEET_TIMEOUT"), 45)

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

SHEET_PROMPT = (
    "You write the first draft of someone's keyboard cheat sheet for a terminal. For each"
    " binding you are given, say what pressing it does, from the point of view of someone"
    " reaching for it: at most 12 words, no trailing period, no chord repeated back, no"
    " marketing. Read the action name and any script path for what the binding actually"
    " does, and say plainly when you cannot tell — 'runs <script name>' beats an invention."
    " Also put each binding in a section, so related chords sit together: a handful of short"
    " section names in plain English, reused exactly across the rows that belong together,"
    " ordered from what someone reaches for most often to what they reach for least."
)

SHEET_SCHEMA = json.dumps({
    "type": "object",
    "properties": {
        "rows": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"chord": {"type": "string"}, "section": {"type": "string"},
                               "does": {"type": "string"}},
                "required": ["chord", "section", "does"],
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

GENERATED_HEAD = """# Keyboard shortcuts

Written from `keymap.conf` on the first run, by a model reading each binding. Treat it as a
draft in someone else's words: it knows what a chord does and it cannot know why you bound
it. Rewrite as you go, and it will never be regenerated over you.

"""


def bindings(keymap):
    """Chord and label for every chord-carrying binding, `map` lines first."""
    pairs = [(chord, action.replace("_", " ")) for chord, action in MAP_LINE.findall(keymap)]
    pairs += [(chord, name) for name, chord in COMMAND_LINE.findall(keymap)]
    # A chord bound by both a map line and a command line is one chord, and one row.
    seen, unique = set(), []
    for chord, label in pairs:
        if chord not in seen:
            seen.add(chord)
            unique.append((chord, label))
    return unique


def chord_md(chord):
    """A chord as markdown code. The one whose key is a backtick needs the other fence."""
    return f"``{chord} ``" if "`" in chord else f"`{chord}`"


def starter(pairs):
    rows = "".join(f"| {chord_md(chord)} | {label} |\n" for chord, label in pairs)
    return STARTER_HEAD + rows


def generated(rows):
    """A first sheet from the model's rows, grouped under the sections it chose."""
    order, grouped = [], {}
    for row in rows:
        section = row.get("section") or "Shortcuts"
        if section not in grouped:
            order.append(section)
            grouped[section] = []
        grouped[section].append(row)
    out = [GENERATED_HEAD]
    for section in order:
        out.append(f"## {section}\n\n| chord | does |\n|---|---|\n")
        for row in grouped[section]:
            out.append(f"| {chord_md(row['chord'])} | {cell(row['does'])} |\n")
        out.append("\n")
    return "".join(out)


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


def normalise(line):
    """A binding line reduced to what it actually does.

    agterm strips an inline comment and tokenizes before binding anything, so neither a
    trailing note nor the column padding people use to line a file up changes the chord's
    behaviour. Comparing raw lines makes re-aligning the keymap read as a rebind of every
    chord in it, which is a normal edit and a very loud false alarm.
    """
    return " ".join(line.split("#")[0].split())


def binding_lines(keymap):
    """Chord -> what its keymap line does, normalised."""
    lines = {}
    for line in keymap.splitlines():
        stripped = line.strip()
        for match in (MAP_LINE.match(stripped), COMMAND_LINE.match(stripped)):
            if match:
                chord = match.group(1) if match.re is MAP_LINE else match.group(2)
                lines[chord] = normalise(stripped)
    return lines


def sheet_is_current():
    """Was the sheet touched after both the baseline and the last keymap change?

    That is the reader saying it describes what is bound now. Both comparisons are needed:
    newer than the baseline alone also swallows a rebind that happened after they last
    touched the sheet, which is the case worth reporting.
    """
    try:
        sheet_at = SHEET.stat().st_mtime_ns
        return sheet_at > BINDINGS.stat().st_mtime_ns and sheet_at > KEYMAP.stat().st_mtime_ns
    except OSError:
        return False


def rebound(keymap, sheet):
    """Documented chords whose binding changed since the sheet was last touched.

    The comparison is against the sheet's own modification time, so it needs no
    acknowledgement: edit the sheet and every chord is taken as described correctly again,
    leave it alone and the same chords are named on every press until you do.
    """
    if not BINDINGS.exists():
        return []
    before = stored()["bound"]
    if sheet_is_current():
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


def draft(lines, chords, hud, whole_sheet=False, restating=False):
    """Ask the model for one row per binding. None on any failure, so the sheet still opens.

    `whole_sheet` is the first run, where there is nothing to preserve: every binding is sent
    at once and the model groups them into sections as well as describing them.
    """
    if not CLAUDE_BIN:
        return None
    wanted = set(chords)
    prompt, schema = (SHEET_PROMPT, SHEET_SCHEMA) if whole_sheet else (SYSTEM_PROMPT, SCHEMA)
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
                 "--output-format", "json", "--system-prompt", prompt,
                 "--json-schema", schema, body],
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
            what = "writing the sheet" if whole_sheet else (
                "rewriting what changed" if restating else "drafting")
            plural = "" if len(lines) == 1 else "s"
            hud.show(f"{what}, {len(lines)} chord{plural} · {elapsed}s")
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
    body = "".join(f"| {chord_md(r['chord'])} | {cell(r['does'])} |\n" for r in rows)
    if DRAFT_HEADING in sheet:
        return sheet.rstrip("\n") + "\n" + body
    return (sheet.rstrip("\n") + "\n\n" + DRAFT_HEADING + "\n\n" + DRAFT_INTRO
            + "\n\n| chord | does |\n|---|---|\n" + body)


def write(path, text):
    """Write through a temp file in the same directory, so a killed run leaves no half file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else None
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    # The replace swaps the inode, so a sheet the reader chmodded would come back at the
    # umask default. Carry its bits over rather than quietly widening them.
    if mode is not None:
        tmp.chmod(mode)
    tmp.replace(path)


def snapshot(keymap, wrote=None, unresolved=()):
    """Record what each chord is bound to now, as the baseline `rebound` compares against.

    `wrote` carries the descriptions the model just produced, kept alongside so a later pass
    can tell its own draft from a sentence the reader has since written. Anything recorded
    before is kept, so a row drafted three edits ago is still recognisable as a draft.
    """
    before = stored() if BINDINGS.exists() else {"bound": {}, "drafted": {}}
    was, previously_bound = before["drafted"], before["bound"]
    was.update(wrote or {})

    bound = binding_lines(keymap)
    # A chord whose row could not be brought up to date keeps its OLD line here, so it is
    # still reported next time. Recording the new one would mean the pass had quietly
    # accepted a row it knows is wrong.
    for chord in unresolved:
        if chord in previously_bound:
            bound[chord] = previously_bound[chord]

    write(BINDINGS, json.dumps({"bound": bound, "drafted": was}, sort_keys=True, indent=1))


def stored():
    """The baseline file, as {bound, drafted}.

    An earlier version of this recipe wrote the bare chord-to-line map at the top level. It
    is read as `bound` rather than discarded, because discarding it would silently answer
    "nothing has changed" for every chord until the next keymap edit reseeded the file.
    """
    try:
        raw = json.loads(BINDINGS.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"bound": {}, "drafted": {}}
    if "bound" not in raw:
        return {"bound": {k: v for k, v in raw.items() if isinstance(v, str)}, "drafted": {}}
    return {"bound": raw.get("bound", {}), "drafted": raw.get("drafted", {})}


def drafted_text(chord):
    """What the model last wrote for this chord, or None if it never did."""
    return stored()["drafted"].get(chord)


def first_sheet(keymap, pairs):
    """The sheet a machine with none gets, and the descriptions the model wrote for it.

    Nothing is being preserved here, so this is the one place the model writes the whole
    file. Every later run only ever appends.
    """
    chords = [chord for chord, _ in pairs]
    if not DRAFT or not chords:
        return starter(pairs), {}
    hud = Hud()
    try:
        rows = draft(source_lines(keymap, chords), chords, hud, whole_sheet=True)
    finally:
        hud.close()
    if not rows:
        return starter(pairs), {}

    # A 41-row answer can quietly come back with 40. The drift banner would catch it on the
    # next press, but an incomplete first sheet is a poor first impression when the missing
    # rows can simply be added with the label the mechanical starter would have used.
    described = {row["chord"] for row in rows}
    rows += [{"chord": chord, "section": "Also bound", "does": label}
             for chord, label in pairs if chord not in described]
    # Every row here is the model's, and saying so is what lets a later pass rewrite one when
    # its chord is rebound. Returning only the text threw that away, which left the rewrite
    # dead on exactly the machines where the whole sheet is the model's work.
    return generated(rows), {row["chord"]: row["does"] for row in rows}


def is_chord_cell(text, chord):
    """Is this cell the chord itself, rather than prose that happens to mention it?

    The distinction is what keeps the replacement on the right cell. "mark, the opposite of
    `cmd+ctrl+n`" names a chord and is somebody's description; a cell that is nothing but the
    chord is a column entry, and the one after it is what describes it.
    """
    return text.replace("`", "").strip() == chord


def owns(sheet, chord):
    """Is the description beside this chord the model's words rather than the reader's?

    Two proofs. The row still sits under the holding heading, which is what that heading
    means. Or the cell still holds exactly what was recorded when the model wrote it. Without
    one of them the words are the reader's, and rewriting those is not this recipe's to do.
    """
    mine = drafted_text(chord)
    in_holding = False
    for line in sheet.splitlines():
        stripped = line.strip()
        if stripped.startswith("## "):
            in_holding = stripped == DRAFT_HEADING
        if not stripped.startswith("|"):
            continue
        cells = stripped.split("|")
        for i, one in enumerate(cells[:-1]):
            if is_chord_cell(one, chord):
                return in_holding or (mine is not None and cells[i + 1].strip() == cell(mine))
    return False


def restate(sheet, chord, text):
    """Replace the description beside `chord`, leaving the rest of the row alone.

    The cell is the one after the cell that IS the chord, which is what makes this safe in a
    hand-arranged table: a row holding two chords across four columns has the right one
    rewritten and the other pair untouched, and a description mentioning some other chord is
    not mistaken for a column entry.
    """
    out, replaced = [], False
    for line in sheet.splitlines(keepends=True):
        stripped = line.rstrip("\n")
        indent = stripped[:len(stripped) - len(stripped.lstrip())]
        body = stripped.strip()
        if not replaced and body.startswith("|"):
            cells = body.split("|")
            for i, one in enumerate(cells[:-1]):
                if is_chord_cell(one, chord):
                    cells[i + 1] = f" {cell(text)} "
                    line = indent + "|".join(cells) + "\n"
                    replaced = True
                    break
        out.append(line)
    return "".join(out), replaced


def sync(keymap):
    """The maintenance pass: draft rows for chords the sheet has never heard of."""
    # Seeding happens BEFORE the gate. On an existing install the stamp is already current,
    # so anything after the gate would wait for the next keymap edit — and that edit is
    # exactly the one that could rebind a chord with no baseline to notice it against.
    if SHEET.exists() and not BINDINGS.exists():
        snapshot(keymap)

    mtime = str(KEYMAP.stat().st_mtime_ns)
    # The timestamp says nothing new since the last pass, and that is true of the chord SET.
    # It is not true of a row an earlier pass left out of date: the keymap change that caused
    # it is already stamped, so the timestamp alone would never look at it again.
    unchanged = STAMP.exists() and STAMP.read_text(encoding="utf-8") == mtime
    if unchanged and not (SHEET.exists() and rebound(keymap, SHEET.read_text(encoding="utf-8"))):
        # Nothing to do, but a sheet edited since the baseline was written is the reader
        # saying it describes what is bound now. Recording that here is what stops the next
        # unrelated keymap edit from reporting a row they already fixed.
        if SHEET.exists() and BINDINGS.exists() and sheet_is_current():
            snapshot(keymap)
        return

    pairs = bindings(keymap)
    if not SHEET.exists():
        text, wrote = first_sheet(keymap, pairs)
        write(SHEET, text)
        write(STAMP, mtime)
        snapshot(keymap, wrote)
        return

    # A sheet edited after the last keymap change describes what is bound now, so it becomes
    # the baseline.
    if sheet_is_current():
        snapshot(keymap)

    sheet = SHEET.read_text(encoding="utf-8")
    missing = undocumented(pairs, sheet)
    # A chord that kept its key and changed its command: the row names it and describes
    # something else. Whose words those are decides what happens, and it is asked HERE,
    # before the model is called — asking afterwards meant a call per press whose answer was
    # thrown away, for as long as the reader left their own row in place.
    stale = rebound(keymap, sheet)
    ours = [chord for chord in stale if owns(sheet, chord)]
    theirs = [chord for chord in stale if chord not in ours]
    if not missing and not stale:
        write(STAMP, mtime)
        return
    if not DRAFT:
        write(STAMP, mtime)
        return

    hud = Hud()
    try:
        rows = draft(source_lines(keymap, missing), missing, hud) if missing else []
        redone = draft(source_lines(keymap, ours), ours, hud, restating=True) if ours else []
    finally:
        hud.close()
    if not rows and not redone:
        if stale:
            snapshot(keymap, unresolved=stale)
        return

    if rows:
        sheet = append_rows(sheet, rows)
    wrote = {row["chord"]: row["does"] for row in rows or []}
    fixed = set()
    for row in redone or []:
        sheet, replaced = restate(sheet, row["chord"], row["does"])
        if replaced:
            wrote[row["chord"]] = row["does"]
            fixed.add(row["chord"])
    write(SHEET, sheet)
    write(STAMP, mtime)
    snapshot(keymap, wrote, unresolved=[c for c in stale if c not in fixed] + theirs)


def render(keymap):
    """Print the sheet, with a banner naming anything still undocumented."""
    pairs = bindings(keymap)
    if not SHEET.exists():
        write(SHEET, starter(pairs))
        print(f"> **Generated `{SHEET}` from your keymap.**")
        print(">")
        print("> Rewrite it in your own words. This run shows what was written.")
        print()

    sheet = SHEET.read_text(encoding="utf-8")
    missing = undocumented(pairs, sheet)
    if missing:
        print(f"> **This sheet has drifted from `{KEYMAP.name}`.**")
        print(">")
        print("> Bound but not documented: " + ", ".join(f"`{c}`" for c in missing))
        print()

    # Normally the maintenance pass has already rewritten these. What reaches here is what
    # it could not: no model available, or a call that failed.
    changed = rebound(keymap, sheet)
    if changed:
        print("> **Bound to something else now, so the row is out of date:** "
              + ", ".join(f"`{c}`" for c in changed))
        print(">")
        print("> These are yours to reword — the ones written by a model were already"
              " brought up to date.")
        print()

    sys.stdout.write(sheet)


def main():
    try:
        keymap = KEYMAP.read_text(encoding="utf-8")
    except OSError as err:
        sys.exit(f"cannot read {KEYMAP}: {err}")

    if "--sync" in sys.argv[1:]:
        sync(keymap)
        return
    render(keymap)


if __name__ == "__main__":
    main()
