# agterm control recipes

Worked `agtermctl` examples. See `reference.md` for exact flags and return shapes. All assume
`agtermctl` is on PATH and you are inside an agterm session (`AGTERM_ENABLED=1`).

## Inspect the current state

```bash
agtermctl tree --json        # workspaces -> sessions, with active/split/overlay/scratch flags
agtermctl window list --json # windows, with open/active flags
```

## Create a session and type into it

`session new` returns the new id and focuses the session. Capture the id, then type. The session is
realized eagerly, so no `--select` is needed.

```bash
sid=$(agtermctl session new --cwd "$HOME/project" --json | jq -r '.result.id')
agtermctl session type "git status" --target "$sid"
agtermctl session type $'\n' --target "$sid"     # send Return (or include it in the text)
```

Run a command AS the session's process (closes when it exits, no echoed command line):

```bash
agtermctl session new --command "htop"
agtermctl session new --command "ssh host -p 22"   # shell-parsed, runs with no echo
```

## Build a small layout

```bash
ws=$(agtermctl workspace new "build" --json | jq -r '.result.id')
a=$(agtermctl session new --workspace "$ws" --cwd "$HOME/proj" --json | jq -r '.result.id')
agtermctl session rename "server" --target "$a"
agtermctl session split on --target "$a"          # second shell side by side
b=$(agtermctl session new --workspace "$ws" --json | jq -r '.result.id')
agtermctl session rename "logs" --target "$b"
```

## Run a program in a blocking overlay and read its status

`--block` waits for the program to exit and makes agtermctl exit with the program's status. The
program renders normally in the overlay; read its OUTPUT from the program's own output file.

```bash
agtermctl session overlay open "revdiff HEAD~3 --output /tmp/notes.md" --block
echo "exit status: $?"
cat /tmp/notes.md
```

Floating panel variant (session stays visible behind it):

```bash
agtermctl session overlay open "htop" --size-percent 70
# ... later
agtermctl session overlay close
```

Manual open + poll for status instead of `--block`:

```bash
agtermctl session overlay open "make test"
agtermctl session overlay result --json   # errors "still running" until it exits, then result.exitCode
```

## Toggle the scratch terminal

A third per-session full-coverage shell. Hide keeps it alive; `exit` in it recreates on next show.

```bash
agtermctl session scratch on        # show (selects the target)
agtermctl session scratch off       # hide, shell stays alive
agtermctl session scratch toggle
```

## Copy a selection and reuse it

`session copy` returns the selection as text (it does not use the system clipboard). Pipe it onward.

```bash
sel=$(agtermctl session copy --json | jq -r '.result.text')
agtermctl session type "$sel" --target "$other"
```

## Search the terminal scrollback

`session search` opens a search bar over the focused terminal and highlights matches in the live
output. It returns the "N of M" counter; step matches with `--next`/`--prev`, close with `--close`.

```bash
agtermctl session search "error"          # highlight matches, print the counter (e.g. "1 of 7")
agtermctl session search --next           # step to the next match
agtermctl session search --prev           # step back
n=$(agtermctl session search "warn" --json | jq -r '.result.count')   # how many matches
agtermctl session search --close          # close the search bar
```

## Notify the user in a specific session

```bash
agtermctl notify "build finished" --title "CI"                 # active session
agtermctl notify "tests failed" --target "$sid"               # a specific session
```

## Agent status glyph

```bash
agtermctl session status active --blink --target "$AGTERM_SESSION_ID"   # working
agtermctl session status completed --auto-reset --target "$AGTERM_SESSION_ID"  # one-shot done flash
agtermctl session status idle --target "$AGTERM_SESSION_ID"             # clear
```

## Navigate and manage windows

```bash
agtermctl session go --to next            # step selection to the next session
agtermctl session go --to next-attention  # jump to the next blocked/completed session
w=$(agtermctl window new "scratch" --json | jq -r '.result.id')
agtermctl window resize "$w" --width 1200 --height 800
agtermctl window move "$w" --x 100 --y 100 --display 0
agtermctl window select "$w"
```

## Reload the keymap after editing it

```bash
$EDITOR ~/.config/agterm/keymap.conf
agtermctl keymap reload          # prints the parse-diagnostic count (0 = clean)
```

## Targeting another window's tree

```bash
agtermctl tree --json --window work          # the "work" window's tree (prefix match)
agtermctl session new --window work --cwd "$HOME"
```
