---
name: webrev
description: Review any text that is not a diff - a plan, a markdown or text document, or a draft such as a PR body, an issue comment or a commit message - as a rendered page in a chromeless agterm HTML overlay, with notes on blocks, code lines and the whole file handed back as annotation records. Use when the user says "webrev", "/webrev", "web review", "review this file", "review this plan", "review this doc", "let me annotate this", "webrev <file>", "review this draft before posting", "let me review the PR body first", or "let me review the commit message". Not for diffs.
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/webrev.py:*)
---

# webrev

Requires agterm (`AGTERM_SESSION_ID` set).

## Launch

Create a backup directory first, then run it as a foreground Bash call with `timeout: 600000`. A
background task lets Claude Code's status hooks overwrite the blinking blocked status the page sets. A
review that outlasts the cap is recovered from the backup file:

```bash
mktemp -d /tmp/webrev-XXXXXX
"${CLAUDE_SKILL_DIR}/scripts/webrev.py" review <file> --output <that dir>/result
```

The backup path must not exist beforehand: a missing file means no outcome was recorded, while an empty
one means a submit with no notes.

The page opens as a floating panel over this session and the script waits for it, at `--size N` percent
(default 95) for documents, plans and anything long. Pass `--fit` instead for a short draft such as a commit
message, a comment or a short PR body: the panel opens at a size estimated from the text.
A plain-text draft gets 80 columns; markdown gets its longest line within 60..100 columns, and the height
follows the wrapped rows. agterm limits each side to 80% of the session, and anything taller, a wide table or
an opened note scrolls. The estimate is for agterm's HTML page zoom of 1.0; agterm reports the zoom only once
a page is open, so at any other zoom the panel resizes once right after it opens, to the estimate times the
zoom. A zoom changed while the page is up does not resize it. `--pane left|right` puts the page over one
split pane, always at full size, so neither `--size` nor `--fit` applies.
If `--fit` fails because the session is presented from another Mac (`--width/--height are not supported`),
run the review again without it.

`WEBREV_STYLE=terminal` in the environment switches the page to a flat terminal-like look: body text at one
size, square chrome, a status bar at the bottom. Unset keeps the default look; any other value is an error.

When the file is a temp file holding generated content, pass `--title "<what it is>"`, for example
`--title "PR description: add retries"`: the header shows it in place of the temp file name. Annotation
records keep the real file path.

The call's exit status and stdout carry the result:

- exit 0: stdout is the annotations. Empty stdout means the user submitted with no notes: the review is done.
- exit 2: the user cancelled. Stop, change nothing.
- exit 1: report the stderr text verbatim.

Whenever the task ended without that result (killed, timed out, lost), read the backup file. It holds the
annotations once the waiter recorded the answer (empty for no notes), `dismissed` for a cancel, or
`pending <page-id>`, the last state the waiter recorded. A pending line does not prove the page is still
open: run `"${CLAUDE_SKILL_DIR}/scripts/webrev.py" result <page-id>`, which may already return the final
answer, since agterm keeps the outcome after the page closes (same exit codes, 1 while still pending).
Still pending means the user has not answered: do not relaunch, since agterm refuses a second overlay in
the slot, and do not treat the review as finished. A missing file means no recovery record was written.
Report the task stderr; if it contains a page id, use result to recover that page.

## Annotation format

```
## docs/plan.md (file-level)
split this into two plans

## docs/plan.md:12-15 ( )
this paragraph contradicts task 3

## docs/plan.md:40 ( )
wrong flag name
```

A paragraph, heading, list item or table row reports its source line range; a line in a code block
reports itself. Paths are relative to the cwd the script ran in, absolute outside it.

## Process

1. Split notes into questions and directives. A question contains `??` or opens with `explain`,
   `remind`, `describe`, `what is`, `what are`, `how does`, `how do` or `clarify` (case-insensitive):
   answer it in chat, change nothing for it.
2. Treat every other note as an instruction to change the file at that location, and make the changes.
3. Relaunch webrev on the same file so the user can check the result. Stop when a review comes back
   empty or cancelled.

## Review a draft before posting

Use this when the user asks to review a draft before it goes out: a PR or issue body, a comment, release
notes, or a commit message.

1. Create a directory with `mktemp -d /tmp/webrev-draft-XXXXXX` and write the draft into it as `draft.md`
   for forge text or `draft.txt` for a commit message. The extension decides whether the page renders
   markdown.
2. Create a separate backup directory as in Launch, then run `review` on the draft with `--title` naming
   what it is and where it goes, for example `--title "PR comment: owner/repo#42"`. Add `--fit` for a commit
   message, a comment or a short body; leave it out for a long description or release notes.
3. On exit 0 with notes, answer the questions in chat and apply the directives to the draft file, then
   review it again. A question never authorizes an edit.
4. On exit 2, stop: the draft is not approved, and nothing is posted or committed. Ask the user what to do
   with it. On exit 1 or a lost result, follow Launch; a review that cannot be read is not a clean one.
5. On exit 0 with empty stdout, the review is clean:
   - A commit message is approved by the clean review, since the user already asked for the commit. Commit
     with that file (`git commit -F <draft.txt>`). The review approves the message only, never changes
     staged beyond what the user asked to commit.
   - Anything posted to a forge needs an explicit go-ahead. Show the final text, name the action and the
     destination ("post this comment on owner/repo#42"), and wait for the user to confirm. Post from the
     same file (`--body-file`, `-F`), so the text that goes out is the text that was reviewed.
6. Any edit after the clean review, the user's or yours, sends the draft back to step 2.

## Page controls

The left rail shows each block's first source line; hovering a block shows a `+` there, and an
annotated block keeps an amber `✎`. Click a block, code line or its `+` to annotate it; click a note
to edit or delete it. `j`/`k` move, Page Up/Down and Home/End scroll and move with the view, `Enter` or `a`
annotates the current block, `f` or `A` opens the file note, `t` (or Contents) opens a heading list for
markdown with fuzzy search (arrows or Ctrl-n/p move, Enter jumps, Esc closes), `m` (or the Notes button)
opens the same list for the notes, `n`/`p` jump to the next and previous note, `⌘↵` saves a note, `Esc`
closes the editor. An open editor keeps its text and the keyboard until saved or closed: a click elsewhere
and keys typed after selecting page text go back to it, while `⌘C` copies the selection. Outside an editor
`⌘↵` submits at once when there are no saved notes; with notes it needs a second press within 3 seconds, so
a habitual extra press after saving cannot send the review; the Submit button sends at once. `Esc` outside
an editor or list cancels the review, the same as the Cancel button: with notes it asks for a second `Esc`
or click within 3 seconds before discarding them. `q` submits at once, like the Submit button, and `Q`
cancels the same way `Esc` does. Saved notes survive a theme change reload of the page, not its closing;
text still open in an editor does not.
