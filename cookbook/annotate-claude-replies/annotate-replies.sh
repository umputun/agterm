#!/bin/sh
# Open my last Claude response in revdiff, annotate it, hand the notes back to the same prompt.
#
# Bound to a chord in ~/.config/agterm/keymap.conf. agterm runs a custom command detached, in a
# non-interactive /bin/sh with a small PATH and stdio on /dev/null, so the PATH is widened here and
# progress goes to the log instead of a terminal.
#
#   $1  agterm session id, from {AGT_SESSION_ID}
#   $2  pane, from {AGT_PANE} (left, right or scratch)
#
# Which transcript to read comes from save-transcript-path.py, the Stop hook beside this script.
# Without it there is nothing to open.
set -eu

PATH=$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin
export PATH

# Everything below can be set in a config file instead of edited here, so one machine's quirks never
# become a change to the script. A setting takes effect on the next press; a keymap line would need a
# reload first, which is a trap when the chord keeps working with the old value and says nothing.
CONFIG=${AGTERM_ANNOTATE_CONFIG:-$HOME/.config/agterm-annotate/config}
if [ -r "$CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG"
fi

AGTERMCTL=${AGTERMCTL:-agtermctl}
PYTHON=${PYTHON:-python3}
# Binary names to try, in order. A local build under its own name belongs in the config file rather
# than here: AGTERM_ANNOTATE_REVDIFF_NAMES="my-revdiff revdiff".
REVDIFF_NAMES=${AGTERM_ANNOTATE_REVDIFF_NAMES:-revdiff}
# An absolute path, because the overlay runs its command under the app's GUI PATH, which has neither
# Homebrew nor ~/.local/bin. A bare name there exits 127 and the overlay flashes shut.
if [ -z "${REVDIFF:-}" ]; then
    for candidate in $REVDIFF_NAMES; do
        found=$(command -v "$candidate" 2>/dev/null || true)
        if [ -n "$found" ]; then
            REVDIFF=$found
            break
        fi
    done
fi
REVDIFF=${REVDIFF:-}
CACHE_DIR=${AGTERM_ANNOTATE_DIR:-$HOME/.cache/agterm-annotate}
LOG=${AGTERM_ANNOTATE_LOG:-/tmp/agterm-annotate.log}
# 1 sends the Return for you, so quitting revdiff is the whole interaction. Set here rather than in the
# keymap line: a keymap change needs a reload to take effect, and this script is read fresh every run.
SUBMIT=${AGTERM_ANNOTATE_SUBMIT:-1}
# 1 pastes the notes at the prompt; 0 types a one-line pointer to the file instead. Pasting needs the
# clipboard, which is saved and put back around the paste.
INLINE=${AGTERM_ANNOTATE_INLINE:-1}
# Flags handed to revdiff. Wrapping is on because a reply is prose, not code, and --wrap-indent keeps a
# wrapped bullet from reading as a new one. Add --tree-width=1 to shrink the side panel; there is no
# flag to collapse it outright.
REVDIFF_FLAGS=${AGTERM_ANNOTATE_REVDIFF_FLAGS:---wrap --wrap-indent=2}
# How far back to gather. 1 is everything Claude said since your last prompt; 2 adds the exchange
# before it, and so on. Each reply becomes a section of the file revdiff opens.
PROMPTS_BACK=${AGTERM_ANNOTATE_PROMPTS:-1}

exec >>"$LOG" 2>&1

session=${1:-}
pane=${2:-left}
# Resolve through symlinks, so the helpers are found beside the real script rather than beside
# whatever name it was installed under.
here=$("$PYTHON" -c 'import os, sys; print(os.path.dirname(os.path.realpath(sys.argv[1])))' "$0")
render=$here/annotate-render.py
extract=$here/annotate-extract.py

echo "--- $(date '+%F %T') session=$session pane=$pane"
echo "revdiff=$REVDIFF"

notify() {
    "$AGTERMCTL" notify "$1" --title "Annotate response" --target "$session" >/dev/null || true
}

if [ -z "$session" ]; then
    echo "no session id given; the keymap line must pass {AGT_SESSION_ID}"
    exit 1
fi

# Not every build has these, and an unknown flag makes the overlay flash shut with a usage error
# instead of opening, so ask the binary rather than assume. One --help, not one per flag. Skipped when
# the flags were overridden, because an explicit set is a deliberate one.
#   --no-tree  hides the side panel, which a single reply has no use for
#   --preview  opens in rendered markdown; the toggle switches to source to place annotations
if [ -z "${AGTERM_ANNOTATE_REVDIFF_FLAGS:-}" ] && [ -x "$REVDIFF" ]; then
    revdiff_help=$("$REVDIFF" --help 2>&1 || true)
    for probe in --no-tree --preview; do
        case $revdiff_help in
        *"$probe"*) REVDIFF_FLAGS="$REVDIFF_FLAGS $probe" ;;
        esac
    done
fi

if [ ! -x "$REVDIFF" ]; then
    echo "revdiff not found on PATH; set REVDIFF to its absolute path"
    notify "revdiff is not on the PATH this script sees. Set REVDIFF in it."
    exit 1
fi

pointer=$CACHE_DIR/$session.$pane.json
if [ ! -s "$pointer" ]; then
    echo "no pointer at $pointer"
    notify "This pane has no Claude transcript on record yet. It registers when Claude finishes a reply."
    exit 0
fi

work=${TMPDIR:-/tmp}/agterm-annotate/$session.$pane
mkdir -p "$work"

# One run per pane. mkdir is atomic, so a second press while revdiff is still open is dropped instead
# of stacking another overlay on the same session.
if ! mkdir "$work/lock" 2>/dev/null; then
    echo "already open for this pane, ignoring"
    exit 0
fi
trap 'rmdir "$work/lock" 2>/dev/null || true' EXIT INT TERM

# The session name goes in every reply's filename, because revdiff prints the path across the top and
# lists them in its tree. A stale or foreign answer is then obvious on sight.
# Two answers from one read: the session's name, and whether anything is running in the addressed
# pane. A pane whose agent has exited reports no foreground, and pasting there would hand the notes to
# a shell -- every quoted line starts with "> ", which a shell reads as a redirect and acts on.
probe=$("$AGTERMCTL" tree --json 2>/dev/null | "$PYTHON" -c '
import json, re, sys
want, pane = sys.argv[1], sys.argv[2]
try:
    tree = json.load(sys.stdin)["result"]["tree"]
except Exception:
    sys.exit(0)
for workspace in tree.get("workspaces", []):
    for node in workspace.get("sessions", []):
        if node.get("id") != want:
            continue
        slug = re.sub(r"[^A-Za-z0-9]+", "-", node.get("name") or "").strip("-")[:40]
        # No read-back exposes the foreground of a scratch pane, so it reports unknown and is
        # treated as live; it never takes the paste path anyway.
        key = {"left": "foreground", "right": "splitForeground"}.get(pane)
        busy = "unknown" if key is None else ("yes" if node.get(key) else "no")
        print(slug)
        print(busy)
' "$session" "$pane") || probe=""
name=$(printf '%s\n' "$probe" | sed -n 1p)
pane_busy=$(printf '%s\n' "$probe" | sed -n 2p)
[ -n "$pane_busy" ] || pane_busy=unknown

# Read the replies out of the transcript now, rather than trusting whatever the hook last copied. The
# hook only fires when a turn ends, so its copy goes stale as soon as it misses one.
replies=$("$PYTHON" "$extract" "$pointer" "$work" "${name:-replies}" "$PROMPTS_BACK") || replies=""
if [ -z "$replies" ]; then
    echo "no replies found through $pointer"
    notify "No answer to annotate in this pane yet."
    exit 0
fi
echo "resolved name=${name:-?} file=$(basename "$replies")"

# One file. revdiff builds its sidebar from a markdown file's headings, so each reply is a section and
# the contents can name them in words, running oldest first from the prompt that started it.
only_flags=" --only='$replies'"
: >"$work/notes.raw"

{
    printf '# Annotate the replies\n\n'
    printf 'Session **%s**, every reply since your last prompt.\n\n' "${name:-this pane}"
    cat <<'EOF'
The sidebar lists them oldest first, starting with what you asked. A note can land on an earlier reply as easily as on the one
that was on screen.

Put a note on any line you do not follow or disagree with. Quit when you are done and the notes go
back to the prompt in the session behind this overlay.

Quitting without a note sends nothing.
EOF
} >"$work/description.md"

# The overlay's command runs through `sh -c` with the app's GUI PATH, which has no /opt/homebrew/bin
# and no ~/.local/bin, so revdiff needs its absolute path here or the overlay flashes shut with 127.
overlay_cmd="'$REVDIFF' $REVDIFF_FLAGS$only_flags -o '$work/notes.raw' --description-file='$work/description.md'"

# --block makes agtermctl exit with revdiff's own status, so a non-zero rc is ambiguous: it can come
# from agtermctl refusing before revdiff ever ran. The reply text is what tells the two apart.
rc=0
# No --follow. The chord fires from the session you are looking at, so following is a no-op when the
# target is right and silently drags you elsewhere when it is not.
opened=$("$AGTERMCTL" session overlay open "$overlay_cmd" --target "$session" --block 2>&1) || rc=$?
echo "${opened:-(no reply)}"
echo "revdiff exit=$rc"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 10 ]; then
    case $opened in
    *"overlay already open"*)
        notify "This session already has an overlay open. Close it, then press the chord again."
        ;;
    *"not realized"* | *"no such session"*)
        notify "This session is not on screen yet. Visit it once, then press the chord again."
        ;;
    *)
        notify "Could not open revdiff (exit $rc). See $LOG."
        ;;
    esac
    exit 0
fi

# Quitting without marking anything is a normal outcome, so it stays silent. A banner here would raise
# the session's unseen badge and make you clear a red dot for a non-event.
if ! "$PYTHON" "$render" "$work" "$work/notes.raw" "$work/notes.md"; then
    echo "no annotations"
    exit 0
fi

# `session paste` is the only way to land multi-line text at the prompt without submitting it, because
# `session type` sends a real Return for every newline. It reads the system clipboard and has no
# --pane, always targeting the main pane, so a split or scratch pane falls back to the pointer.
# Nothing is typed into a pane whose agent has gone. The notes stay on disk instead.
if [ "$pane_busy" = "no" ]; then
    echo "nothing running in pane $pane; not sending"
    notify "No agent running in this pane, so the notes were not sent. They are in $work/notes.md."
    exit 0
fi

pasted=0
if [ "$INLINE" = "1" ] && [ "$pane" = "left" ] &&
    command -v pbcopy >/dev/null 2>&1 && command -v pbpaste >/dev/null 2>&1; then
    held=$(pbpaste 2>/dev/null || true)
    if pbcopy <"$work/notes.md" && "$AGTERMCTL" session paste --target "$session" >/dev/null; then
        pasted=1
        echo "pasted the notes inline"
    else
        echo "paste failed, using the pointer instead"
    fi
    # Put back whatever was on the clipboard. Plain text only; an image would already be gone.
    printf '%s' "$held" | pbcopy 2>/dev/null || true
fi

if [ "$pasted" -eq 0 ]; then
    ask="Read $work/notes.md and address every note in it. Each note quotes the lines of the replies I marked."
    "$AGTERMCTL" session type "$ask" --target "$session" --pane "$pane"
fi

if [ "$SUBMIT" = "1" ]; then
    # `session paste` returns once libghostty has run the paste, but the program on the other side of
    # the pty is still reading those bytes. A Return sent immediately can land before a long paste has
    # been ingested and submit half a message, so give it a moment to settle first.
    [ "$pasted" -eq 1 ] && sleep "${AGTERM_ANNOTATE_SETTLE:-0.4}"
    printf '\n' | "$AGTERMCTL" session type --stdin --target "$session" --pane "$pane"
    echo "submitted"
fi

# A blind Return is not safe: the agent's TUI decides what Enter does from its own focus, and an
# artifact or attachment chip can take it instead of the input, dropping the pasted text. Nothing here
# can see that focus, so keep a fixed recovery copy rather than pretend it cannot happen.
cp "$work/notes.md" "$CACHE_DIR/last-notes.md" 2>/dev/null || true
echo "sent, notes at $work/notes.md (copy: $CACHE_DIR/last-notes.md)"
