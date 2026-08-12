# Trim README to a product synopsis

## Overview

`README.md` is 617 lines and works as a full user manual. Nearly all of that content already exists at
`site/docs.html` (2768 lines) and `site/commands.html` (the 75-command catalog), so the README duplicates
the docs site while being harder to navigate than it.

This change cuts the README to roughly 145 lines: a product synopsis that answers what agterm is, how it
is different, proof that the difference is real, and how to install it or keep reading. Most reference
material goes away entirely rather than moving, because the site already has it. Three pieces do not exist
anywhere else and must be relocated before their section is deleted.

Four other files change in the same commit, because each asserts something the trim makes false:
`CLAUDE.md:175` (the mirror rule), `CLAUDE.md:4` ("read README.md for product behavior"),
`.claude/rules/keymap.md:169`, `docs/troubleshooting.md:76`, and `site/llms.txt:22`.

## Context (from discovery)

Files involved:

- `README.md` — 617 lines, the subject of the trim
- `CLAUDE.md` — lines 4 and 175
- `.claude/rules/keymap.md` — line 169, points at README for the ghostty `key_` distinction
- `docs/troubleshooting.md` — line 76, points at "the keymap section of the README"
- `site/llms.txt` — line 22, the README description
- `CONTRIBUTING.md` — 114 lines, covers building except the Node.js prereq
- `site/docs.html` — section ids: overview, install, workspaces, terminals, navigation, windows,
  notifications, accessibility, settings, agtermctl, keymap, ghostty, status, restore, troubleshooting, related

Measured README section sizes, total lines including code fences:

```
 73  header, intro, "What it does" bullets, screenshots block
 26  ## Install
 33  ## Build from source
 32  ## Concepts
 14  ## Keyboard and navigation
  6  ## Accessibility
  6  ## Settings
220  ## Scripting agterm
  6  ## Cookbook
 80  ## Customizing keys
 38  ## Ghostty config
 41  ## Agent status
  4  ## Troubleshooting
  8  ## Restore limitations
 19  ## Related projects
  8  ## Attribution
  3  ## License
```

**Content with no home outside README**, verified by repo-wide grep:

- `README.md:110` — the Node.js 22.7+ / 20.19+ prereq for `OpenCodeStatusHookTests`. `CONTRIBUTING.md` never
  mentions Node; its only "node" match is the phrase "tree node".
- `README.md:217-222` — `cd agtermCore && swift build -c release`, the only documented way to build
  `agtermctl` without Xcode or libghostty.
- `README.md:215` — the marketplace caveat: do not install the skill by both routes; `marketplace add` clones
  the whole repository; `--sparse` must cover the manifest as well as `plugins/agterm`. `site/docs.html:475`
  has the one-liners without any of it, and `--sparse` appears nowhere else.

**Related projects**: README lists seven, `site/docs.html`'s `related` section names five. Only
**Rook / @jokius** is absent from all of `site/`.

## Development Approach

- **testing approach**: not applicable in the unit-test sense; this is a documentation change with no code
- verification per task is concrete and listed in the task itself
- complete each task fully before moving to the next
- **CRITICAL: relocate the three orphaned items (Task 1) before deleting their sections (Task 2).**
- **CRITICAL: stale references to README are prose, not anchors.** A `README.md#anchor` grep finds none of
  them. Task 7 greps for the word `README` across `*.md`, `*.html` and `*.txt` instead.
- **CRITICAL: update this plan file when scope changes during implementation**

## Testing Strategy

There is no code, so there are no unit or e2e tests. Verification is:

- every deleted section maps to a `site/docs.html` id that covers it, checked one by one in Task 9
- `wc -l README.md` against the ~145 target
- every internal `(#anchor)` in README resolves to a heading that still exists
- no tracked file refers to README content this change removed, by word-grep not anchor-grep
- `~/.claude/skills/writing-style/scripts/lint.sh README.md` reports no new violations on changed lines
- README renders correctly on GitHub, checked in Task 9 **before** merge, not after

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with the plus prefix
- document issues or blockers with the warning prefix
- keep plan in sync with actual work done

## Solution Overview

The trimmed README answers four questions in order: what is agterm, how is it different, can I see that
difference working, how do I install it or continue reading.

Structure, top to bottom:

1. Title, badges, four nav links
2. Three intro paragraphs, unchanged
3. Five "What it does" bullets, unchanged
4. libghostty sentence, unchanged
5. Hero screenshot plus a collapsed gallery trimmed to 3-4 shots
6. **The model** — new, 5-8 lines, descriptive
7. Install — brew, DMG, CLI-install note, plugin/skill one-liners
8. **`## Scripting agterm`** — rewritten to ~15 lines, one demo block. Heading text and its
   `#scripting-agterm` anchor are unchanged, so inbound external links keep working.
9. **Documentation** — new, routes to docs, commands, cookbook, CONTRIBUTING, ARCHITECTURE
10. Restore boundary, one sentence; troubleshooting, one line
11. Related projects, collapsed into `<details>` with every entry kept
12. Attribution and License, unchanged

Key design decisions:

- **The model section is descriptive, never comparative.** No "unlike a tabbed terminal" framing: agterm is
  itself a vertical hierarchical tab arrangement, so arguing against tabs is a straw man.
- **The API demonstration stays** because the product now leads with "full control API" and an unsupported
  headline reads as marketing. It shows the shape — stable ids, read-back, composability — not coverage.
- **The demo block is an annotated list of representative commands, not a runnable script.** Written as a
  script it would misrepresent: `session type` followed by `session text` races the shell, and `pick` blocks
  on interactive UI. Each line carries a comment saying what it demonstrates.
- **Related projects keeps every entry, collapsed into `<details>`.** Ecosystem and fork credit is
  repo-native, and Rook is not on the site at all.
- **Attribution stays intact**, uncollapsed. It is the libghostty and macterm MIT credit.
- **Build from source becomes a link to CONTRIBUTING.md**, once the Node prereq has moved there.

## Technical Details

The Scripting demo block, annotated rather than runnable:

```sh
ws=$(agtermctl workspace new demo)                        # objects have stable ids
sid=$(agtermctl session new --workspace "$ws" --cwd "$PWD" --no-select)
agtermctl session type --target "$sid" $'pwd\n'           # drive a session you are not looking at
agtermctl session text --target "$sid" --lines 10         # read its terminal back
agtermctl session status blocked --target "$sid"          # set the sidebar status glyph
printf '%s\n' staging production | agtermctl pick --prompt "Deploy where?"   # borrow the native picker
agtermctl tree --json                                     # the whole model, inspectable
```

The CLAUDE.md replacement defines roles rather than reversing the mirror direction, because "README mirrors
docs" would wrongly imply the README chases every documentation edit:

- `site/docs.html` — canonical user guide
- `site/commands.html` — canonical command reference
- `README.md` — product synopsis, install entry point, the model, and the API proof
- `site/llms.txt` — crawler-oriented summary and discovery index

Followed by the facts that must stay synchronized across surfaces: the command count, the install commands,
the minimum macOS version, and the positioning line.

## What Goes Where

- **Implementation Steps**: relocations, README rewrite, the four stale-reference files, and verification
- **Post-Completion**: the GitHub repo description, which is set outside the repo

## Implementation Steps

### Task 1: Relocate the three orphaned items

**Files:**
- Modify: `CONTRIBUTING.md`
- Modify: `site/docs.html`

- [x] add the Node.js 22.7+ / 20.19+ prereq for `OpenCodeStatusHookTests` to CONTRIBUTING's development setup
- [x] add `cd agtermCore && swift build -c release` to `site/docs.html`'s agtermctl section as the way to build the CLI without Xcode
- [x] add the marketplace caveat (one route not both, full-repo clone, `--sparse` must cover the manifest) beside the one-liners at `site/docs.html:475`
- [x] verify each of the three now appears in its new home with `grep`

### Task 2: Cut the reference sections from README

**Files:**
- Modify: `README.md`

- [x] delete `## Concepts`, `## Keyboard and navigation`, `## Accessibility`, `## Settings`
- [x] delete `## Customizing keys`, `## Ghostty config`, `## Agent status`
- [x] delete `## Troubleshooting`, `## Restore limitations`, `## Build from source`, `## Cookbook`
- [x] delete the `### Native picker` and `### Control events` subsections and the reference prose in `## Scripting agterm`, leaving the heading itself in place
- [x] record every internal anchor these deletions orphan, for Task 6
- [x] confirm the three Task 1 items are gone from README and present in their new homes

### Task 3: Add the model section

**Files:**
- Modify: `README.md`

- [x] write 5-8 descriptive lines after the screenshots: window owns a workspace/session tree; workspace groups sessions by project or context; session is the named, persistent sidebar unit; a session holds a main pane plus an optional split pane and scratch terminal; an overlay sits over a session without replacing its shell
- [x] confirm no comparative framing against tabbed terminals appears
- [x] verify each claim against `site/docs.html` sections `workspaces` and `terminals` so the two agree

### Task 4: Rewrite the Scripting section around one demo block

**Files:**
- Modify: `README.md`

- [x] keep the heading exactly `## Scripting agterm` so `#scripting-agterm` still resolves
- [x] write two opening sentences: `agtermctl` drives agterm over a local socket, terminal output is not streamed, `session text` reads a buffer
- [x] add the annotated demo block from Technical Details, one comment per line
- [x] verify every flag in the block against `agtermCore/Sources/agtermctlKit/`
- [x] add one sentence naming windows, layouts, notifications, events, dashboards, HUDs, themes, restoration
- [x] link to the command reference and confirm the command count matches `site/commands.html`

### Task 5: Rework Install and add the Documentation section

**Files:**
- Modify: `README.md`

- [x] keep brew and DMG; fold `### Optional Help-menu installers` down to the CLI-install note (brew includes `agtermctl`, DMG users install it from Help) plus one line for the status hooks and agent skill
- [x] keep the plugin/skill marketplace one-liners for Claude Code and Codex
- [x] add a `## Documentation` section routing to `agterm.com/docs`, `agterm.com/commands`, `cookbook/`, `CONTRIBUTING.md` for building, `ARCHITECTURE.md` for internals
- [x] name the model explicitly in the docs link text so the dropped vocabulary has a one-click definition
- [x] add the restore boundary in one sentence: restoration reconstructs structure, not running processes
- [x] add the troubleshooting pointer in one line, to the docs section plus Issues and Discussions
- [x] verify every link added in this task resolves

Decisions taken in this task:

+ [decision] the marketplace one-liners were removed with `## Scripting agterm`'s reference prose in Task 2; restored
  from `c08ce8dc^:README.md` into `## Install`, where the rest of the skill installation now lives.
+ [decision] dropped the old "the cask also installs `agtermctl`" sentence that followed the brew fence, since the
  folded install line carries the same fact once.
+ [deviation] the troubleshooting pointer links `docs/troubleshooting.md` directly instead of the docs-site section,
  because `site/docs.html`'s `troubleshooting` section is itself only a forward to that file. Issues and Discussions
  are linked alongside it as planned.
+ `~/.claude/skills/writing-style/scripts/lint.sh README.md` reports one violation at `README.md:165`, in the
  untouched Attribution paragraph: `agterm` opening a sentence as a code identifier, a false positive.

### Task 6: Fix anchors and the screenshot gallery

**Files:**
- Modify: `README.md`

- [x] resolve every remaining internal `(#anchor)` in README against surviving headings
- [x] trim the screenshots `<details>` block to 3-4 shots and confirm each referenced file exists in `docs/screenshots/`
- [x] leave the now-unreferenced files in `docs/screenshots/` in place; they are cheap to keep and may be linked from issues or posts
- [x] check every link newly added or reworded by this change resolves
- [x] run `wc -l README.md` and confirm it is near the ~145 target
+ [x] fix the `## Attribution` writing-style violation at former `README.md:165`: the sentence opening with the
  lowercase identifier `agterm` after a period now reads "The app builds it from upstream source at a pinned
  commit via `scripts/setup.sh`, with no fork and no prebuilt binary." Meaning, MIT attribution, project names
  and links are unchanged. `lint.sh README.md` now reports zero violations.

Decisions taken in this task:

+ [decision] kept four gallery shots: `dashboard.png` (several sessions' live output at once), `agent-prompt.png`
  (an agent prompt with attention glyphs), `floating-overlay.png` (a program over a session), and `split-theme.png`
  (two panes side by side). Each shows a model element the single-window hero cannot: the grid, the status glyphs,
  the overlay, and the split.
+ [decision] dropped `attention.png`, `action-palette.png`, `diff-tui.png`, `session-palette.png`, `context-menu.png`,
  `keymap-editor.png`, and `quick-terminal.png` from the README. All seven stay on disk in `docs/screenshots/`.
+ README has no `](#…)` links at all, so no internal anchor can dangle; the orphan recorded below was removed with
  its bullet list in Task 5.
+ `wc -l README.md` is 145, exactly the plan target.

Anchors orphaned by Task 2's deletions (recorded for this task):

+ `README.md:97` — `[Agent status](#agent-status)`, in the Help-menu installers bullet list. `## Agent status`
  is deleted, so the link is dangling; Task 5 rewrites that bullet list, which is where it gets fixed.
+ `#scripting-agterm` at `README.md:96` still resolves; the heading was kept deliberately.
+ no other `](#…)` link survives in README; every other internal anchor lived inside a deleted section.

### Task 7: Collapse Related projects

**Files:**
- Modify: `README.md`

- [ ] wrap `## Related projects` in a `<details>` block, keeping all seven entries and their attributions
- [ ] confirm the Rook entry survives, since it appears nowhere on the site
- [ ] confirm the collapsed block renders correctly in the GitHub markdown preview

### Task 8: Update the four files that assert something now false

**Files:**
- Modify: `CLAUDE.md`
- Modify: `.claude/rules/keymap.md`
- Modify: `docs/troubleshooting.md`
- Modify: `site/llms.txt`

- [ ] replace the `site/docs.html` mirrors README clause at `CLAUDE.md:175` with the four roles from Technical Details, plus the synchronized-facts list
- [ ] reword `CLAUDE.md:4` so product behavior points at the docs site, with README as the synopsis
- [ ] repoint `.claude/rules/keymap.md:169` at `site/docs.html` alone for the ghostty `key_` distinction
- [ ] repoint `docs/troubleshooting.md:76` at the keymap section of the docs site for the token list
- [ ] reword `site/llms.txt:22` so README is the project synopsis, not "the same documentation in the source repository"
- [ ] `grep -rn "README" --include='*.md' --include='*.html' --include='*.txt' .` and confirm no surviving reference describes content this change removed
- [ ] keep CLAUDE.md's semantic-line formatting

### Task 9: Verify acceptance criteria

- [ ] for each deleted section, name the `site/docs.html` id that covers it and confirm the content is actually there: Concepts to `workspaces`/`terminals`, Keyboard and navigation to `navigation`, Accessibility to `accessibility`, Settings to `settings`, Scripting reference to `agtermctl`, Customizing keys to `keymap`, Ghostty config to `ghostty`, Agent status to `status`, Troubleshooting to `troubleshooting`, Restore limitations to `restore`, Build from source to CONTRIBUTING
- [ ] README is near 145 lines and answers the four questions from Solution Overview
- [ ] no dangling internal anchors
- [ ] `~/.claude/skills/writing-style/scripts/lint.sh README.md` shows no new violations on changed lines
- [ ] render the README on GitHub and check the screenshots, the two `<details>` blocks and the code fences, before merge
- [ ] confirm CLAUDE.md no longer asserts a rule the repository violates

### Task 10: [Final] Update documentation

**Files:**
- Modify: `docs/plans/20260811-readme-trim.md`

- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**

- confirm the GitHub repo description, set outside the repo, still reads sensibly next to the trimmed README

**Deliberately out of scope:**

- adding Rook to `site/docs.html`'s related section, a pre-existing gap this change does not create
- the footer "terminal for agentic flow" strings in `site/index.html`, a standing maintainer decision
- any documentation build step; the site stays hand-authored static HTML with no build

Smells pre-check: skipped — non-Go project
