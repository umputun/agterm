---
name: backlog
description: Read, work, and maintain a repo's deferred-work items in docs/backlog/, one file per item. Use when the user says "backlog", "check backlog", "what's on my backlog", "work the backlog", "address the backlog", "add to backlog", "clean up backlog", or when a review or task produced items that are real but not being fixed now. Owns the item format, the create-then-delete lifecycle.
allowed-tools: Read, Edit, Write, Bash, Grep, Glob, AskUserQuestion
---

# Backlog

`docs/backlog/` at a repo root holds work that is real but not being done now: a defect a change did not
introduce, drift with no user-visible symptom, a fix whose blast radius exceeded its value, an idea worth
keeping. One file per item. It is the maintainer's own list — it never gates anything and never reaches a
contributor.

## Item format

`docs/backlog/<slug>.md`. The slug names the defect, not the file it lives in
(`reopen-fallback-ignores-frontmost.md`), so it can be cited from a commit and dedupe is a filename check.

```markdown
---
worth: later
where: internal/store/reopen.go:537
added: 2026-08-05
---
# reopen fallback ignores the last-frontmost window

`reopen`'s fallback ignores which window was last frontmost once `frontmost` is nil, so a multi-window
user's last-window capture replays only when the exited window happened to be `windows.first`. Surfaced
reviewing PR #370; the fix touches restore ordering, which is why it was deferred rather than done inline.
```

Three frontmatter fields, written once and rewritten only when a later sighting of the same item
sharpens it, which is the one case **Appending** below allows:

- **`worth: yes | no | later`** — the honest triage call. **`no` is a valid answer**: a real item not worth
  the edit still belongs here, because writing it down is what stops it being rediscovered every review.
- **`where: path:line`** — omit when the item is not anchored to one place. The dedupe key alongside the slug.
- **`added: YYYY-MM-DD`** — never updated, so it reads as age. A year-old item is itself information.
  Zero-pad it: a reader sorting on this field has nothing to fall back on when the value is not an ISO date.

The H1 is the title. The body below it is free — repro, what was tried, the review that surfaced it, links,
a snippet. No required sections: a two-line item stays two lines, a gnarly one gets a page.

## Lifecycle

Create the file. When the work lands, `git rm` it in the commit that lands the fix — not a separate cleanup
commit. There is no checkbox, no in-progress marker: the staged deletion is the state. Dropping an item
decided against is the same operation with a different reason.

## A slug as the argument

`/backlog <slug>` names one item: `docs/backlog/<slug>.md`, the file name without its extension. Read
that file alone, verify its `where` the same way step 2 below does, and go straight to the fix-or-drop
question for it — skip the listing, which is not what was asked for. A slug matching no file is a
mistake worth saying plainly: report it and list what is there instead of guessing at the nearest name.

The picker types this form, so the argument arrives already matching a real file name.

## Reading and working the list

1. Glob `docs/backlog/*.md` from the repo root and read each file's frontmatter and H1. If the directory
   does not exist, say so plainly and offer to start one — do not create it empty.
2. **Verify before reporting.** `where` goes stale when a file is renamed or a line moves. Check each
   item's location still exists and still says what the item claims; report a stale item as stale rather
   than as work.
3. Report every item, one line each — `yes` first, then `later`, then `no`, oldest `added` first within
   each group. Include `where`. Do not editorialize; the item already carries its reasoning.
4. Offer concrete actions with **AskUserQuestion**, never prose, with a recommendation first:
   - **fix a named item now** — name the specific item in the option label, not "fix something";
   - **file one as an issue** — for an item that wants tracking rather than doing;
   - **drop a named item** — a `no` that has stopped being worth carrying;
   - **leave it** — report only, nothing changes.

   With more than four items, group them across several questions rather than truncating the list.
5. On "fix it now": do the work under the usual gates — tests, formatters, linters — and `git rm` the file
   in the same commit. Never auto-commit.

## Appending

When a run produces deferred items, offer to append them; never write silently.

**Never write into a branch this session did not create.** An item is repo-wide notes; dropped into
someone else's in-progress branch it gets swept into that branch's diff or vanishes with it. Check
`git branch --show-current` first:

- the default branch, or a branch this session created — write in place;
- any other branch — write it against the default branch instead, from a throwaway checkout or worktree
  outside this one. Never switch the current checkout's branch to do it.

**Dedupe before writing**, on `where` first and the slug second. A pre-existing defect surfaces in every
review that touches its file, so the same item arrives repeatedly. If it is already there, say so and leave
it alone. If the new sighting sharpens the description or changes the `worth` call, edit that file in place
rather than adding a second one.

Create `docs/backlog/` if it does not exist.

When the files are written, offer the next step with **AskUserQuestion**, staging the `docs/backlog/` files
only — an item bundled with the run's other changes violates the rule below. Never commit without that
answer.

- **written in place** — commit now, or leave it uncommitted.
- **written from a separate checkout or worktree** — that tree is disposable, so a local commit leaves the
  item somewhere the user will not go looking. Offer **commit and push** first, and remove the worktree
  once it is pushed. Never end the run with an unpushed commit in a temp path as the only result.

## Rules

- **Never post a backlog item to a PR or issue thread** unless the user explicitly asks. These are the
  maintainer's cleanup notes; surfacing them on a contributor's change reads as scope pressure.
- **Never auto-commit** an item file, and never commit it alongside unrelated work.
- **Do not fix an item without being asked.** Reading the backlog is not permission to work it.
- **Prefer deleting to demoting.** An item nobody will ever do is noise; say so and offer to drop it.
