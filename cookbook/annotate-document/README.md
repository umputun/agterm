# Annotate document

Review a plan, a document or a draft as a rendered page over the session, and hand your notes back to Claude Code.

## What it does

`/webrev docs/plan.md` opens the file as a rendered page in a floating panel over the session. Markdown is rendered with headings, tables and highlighted code; any other file is shown as plain text. Click a paragraph, a table row or a code line to attach a note to it, or use the File note button for the whole file, then press Submit. Claude Code gets the notes as annotation records, each block note with its source line range, answers the ones phrased as questions, applies the rest to the file, and opens the page again so you can check the result. The loop stops when you submit with no notes or cancel.

The same page reviews a draft before it leaves the machine. Ask "review this draft before posting" while Claude Code is writing a PR body, an issue comment, release notes or a commit message, and it writes the draft to a temp file, opens it at a size fitted to the text, and applies your notes until a review comes back clean. A commit message is committed after the clean review; anything posted to a forge still waits for your explicit go-ahead, and is posted from the reviewed file.

Notes come back in this shape, one record per note:

```
## docs/plan.md (file-level)
split this into two plans

## docs/plan.md:12-15 ( )
this paragraph contradicts task 3
```

It is the record format [revdiff](https://github.com/umputun/revdiff) prints, so anything that already reads revdiff output reads these. revdiff itself is not needed.

## Requirements

- agterm 0.38.1 or later. `--fit` sizes the panel with `session overlay open --width/--height` and `session overlay resize`, which shipped in 0.38.1. The rest needs 0.35.0, which added `--chromeless` file pages, and 0.34.0, which added the page bridge with `session.overlay.submit` and `session overlay result --page`.
- Python 3.10 or later, standard library only.
- Claude Code for the skill. It uses Claude Code's `allowed-tools` and `CLAUDE_SKILL_DIR`, so it does not load in other agents as written. The script itself works from any agent or shell inside agterm; see Usage.

## Setup

From `cookbook/annotate-document` in a checkout of this repository, copy the skill, its script and its page assets into one directory under Claude Code's skills:

```sh
mkdir -p ~/.claude/skills/webrev
cp -R SKILL.md scripts assets ~/.claude/skills/webrev/
```

The script finds `assets/` relative to its own directory, so the three must stay together. `scripts/webrev.py` is committed executable and `cp -R` keeps the bit.

Set `AGTERMCTL` in the environment Claude Code starts from if your `agtermctl` is not on its `PATH`.

To review every draft before it goes out, not only when you ask, add a line like this to your `~/.claude/CLAUDE.md`:

```markdown
- Before posting text with gh, glab or tea, and before every git commit, review the draft with /webrev.
```

Optional: `WEBREV_STYLE=terminal` in the same environment switches the page to a flat look with one text size and a status bar at the bottom.

## Usage

Inside an agterm session, ask Claude Code:

```
/webrev docs/plan.md
review this plan
review this draft before posting
```

On the page, `j`/`k` move between blocks, `a` or Enter annotates the current one, `A` opens the note for the whole file, `t` lists headings, `m` lists notes, and `n`/`p` jump between notes. `⌘↵` saves a note. `q` or the Submit button sends the review; `Esc`, `Q` or Cancel discards it, asking for a second press when notes would be lost. The skill file lists every key.

The script runs without the skill too, from any shell or agent in an agterm session:

```sh
~/.claude/skills/webrev/scripts/webrev.py review notes.md
~/.claude/skills/webrev/scripts/webrev.py review draft.txt --fit --title "commit message"
```

It blocks until you answer. A submitted review exits 0 with the records on stdout, empty when you sent no notes; a cancelled one exits 2; a failure exits 1 with the reason on stderr. A malformed command line exits 1 too, so 2 always means the user cancelled; Ctrl-C exits 130. `--output PATH` writes the outcome to a file as well, for a caller that can lose the process: the records, `dismissed`, or `pending <page-id>`. `webrev.py result <page-id>` reads the outcome of a page later, with the same exit codes and 1 while it is still open.

## How it works

`webrev.py` builds one self-contained HTML file per review from `assets/page.html`. markdown-it 14.1.0 and highlight.js 11.11.1 are inlined from `assets/`, with their license texts beside them, so the page loads no script from the network; a CDN would run remote code in a page that can drive agterm. The document goes into the page as JSON with every `<` escaped, so a `</script>` in it stays text. markdown-it runs with raw HTML off, because the page has the agterm bridge and markup from the document must never become live.

It opens the page with `session overlay open --html FILE --chromeless --js` on the session in `AGTERM_SESSION_ID`, marks the session's status as blocked and blinking, and polls `session overlay result --page` once a second. Submit calls `agterm.request('session.overlay.submit')` with the records as the value; Cancel calls `session.overlay.close`, which reads back as dismissed. When the outcome arrives, the script clears its status to idle, deletes the page file and prints the result. It does not restore the status it found: the session has one status, and replaying a block another pane set would claim it for this pane. An agent's own status hooks set its next state after the call returns. Both status writes pass `--pane` from `AGTERM_PANE` and `--pane-id` from `AGTERM_PANE_ID`, so they land on the pane that opened the review even after a split pane was swapped or promoted. Saved notes are kept in the page's local storage under a per-review key, so a theme change, which reloads the page, does not lose them. Text still open in an editor is not saved and is lost on that reload.

Every `agtermctl` call passes `--socket "$AGTERM_SOCKET"` when that variable is set. `agtermctl` never reads it, so without the flag a session running on a custom control socket would send its commands to the default one and fail to find its own session.

`--fit` estimates the panel from the text: 80 columns for plain text, the longest line within 60 to 100 columns for markdown, and one row per wrapped line. The numbers are measured at an HTML page zoom of 1.0. agterm reports the zoom only for an open page, in `tree --json`'s `htmlOverlays[].zoom`, so after opening the script reads it with `tree --window "$AGTERM_WINDOW_ID"` and resizes the panel once when it is not 1.0. Without `--window`, `tree` reports only the frontmost window, and a review opened in a background window would miss its page and keep the unscaled size.

The page takes its colors from the `--agterm-*` variables agterm gives every page, so it follows the terminal theme. It also reads `sidebarBackgroundShift` from agterm's `settings.json`, under `AGTERM_STATE_DIR` or `~/Library/Application Support/agterm`, to match the sidebar's tint.

The skill runs the script as a foreground call with Claude Code's 600-second tool timeout. In a background task Claude Code's own status hooks would overwrite the blocked status the script sets. A review that outlasts the timeout is recovered from the `--output` file and `webrev.py result`, which the skill describes step by step.

## Limits

Opening a review replaces a HUD panel shown in the session's overlay slot. It refuses to open while another HTML page or a program overlay is in that slot; close it first.

Closing the panel with ⌘W or `agtermctl session overlay close` reads as a cancel and drops any note still open in an editor, since it bypasses the page's own Cancel handling. Saved notes are dropped with it.

A waiter that is killed leaves its page file in `$TMPDIR/webrev`, because the open page still reads it on a theme change. These files are not cleaned up. `webrev.py result` works only while the same agterm instance runs, and agterm keeps only the last 32 finished page outcomes; a completed `--output` file survives either, while one still reading `pending` needs `webrev.py result`.

The draft review is instructions to Claude Code, nothing more. Nothing stops a post or a commit when the skill is not invoked, and the CLAUDE.md line above only asks the agent to invoke it.

`--fit` fails on a session presented from another Mac: agterm refuses point sizes for a remote page, and the script exits 1 with that error. Run the review again without `--fit`.

Markdown images in the reviewed document load from wherever they point, network included.
