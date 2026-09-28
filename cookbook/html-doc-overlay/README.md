# HTML doc overlay

Ask Claude Code for a page about the issue, PR, plan, change or topic in hand, and read it in an overlay over the session.

## What it does

`/agdoc` turns whatever the session is working on into one static HTML page and opens it over the session as a floating panel. With no arguments it works out the subject itself: the issue or PR under discussion, the plan being executed, the change just made, or the current branch. When more than one fits, it asks, offering the likely subjects. With arguments it takes them as the brief, audience included:

```
/agdoc
/agdoc pr 45 for a reviewer
/agdoc the retry logic in internal/queue, from a business point of view
```

It then asks which of three designs to use, unless the brief already names one:

- **Editorial**: serif headings, a hero with the key numbers, a pinned numbered contents list, cards, pipelines and timelines. For explaining a topic, a code area or a plan.
- **Brief**: one screen, two at most. A masthead, a bottom line and a grid of labelled fact blocks. For the status of a PR, an issue, a branch or a release.
- **Classic**: a plain reference page with a contents bar, pills and callouts, read top to bottom.

The built-in *Other* answer takes a design you describe in your own words.

The page takes the terminal theme: its colors come from the CSS variables agterm gives every page, so it matches a dark or a light theme without a palette of its own. A follow-up such as "drop the risks section" rewrites the same file and reloads the panel.

## Requirements

- agterm 0.33.0 or later, which added HTML pages in overlays (`session overlay open --html`) and their `htmlOverlays` read-back in `tree --json`.
- Claude Code. The skill uses Claude Code's `allowed-tools` and `CLAUDE_SKILL_DIR`, so it does not load in other agents as written.
- jq.
- Optional: `gh`, `tea` or `glab` for issue and PR subjects on GitHub, Gitea or GitLab. Without a matching CLI the page is built from git and the conversation, and says that forge data is unavailable.

## Setup

Copy the skill, its script and its templates into one directory under Claude Code's skills:

```sh
mkdir -p ~/.claude/skills/agdoc
cp -R SKILL.md scripts assets ~/.claude/skills/agdoc/
```

The skill finds `scripts/show.sh` and `assets/*.html` relative to its own directory, so the three must stay together. `show.sh` is committed executable and `cp -R` keeps the bit.

Set `AGTERMCTL` in the environment Claude Code starts from if your `agtermctl` is not on its `PATH`.

## Usage

Inside an agterm session, type `/agdoc` in Claude Code, with or without a brief, or ask in plain words: "show this as a doc", "make an html doc of this PR and show it". Answer the design question. The page opens over the session at 95% of its size and switches you to that session.

Close it with ⌘W or the close button in the bar above it. To change it, say what to change; the panel reloads in place.

Outside agterm the page opens in the default browser instead.

## How it works

The skill does the work in six steps: settle the subject and the angle (technical, business, reviewer, newcomer), choose the design, gather the content, shape it, write the page from the design's template, and show it. Facts on the page come from what it fetched or read; anything else is labelled `[Inference]`, and issue and PR text is treated as data and escaped.

Content comes from git and, for issues and PRs, from the forge CLI that matches the `origin` remote: `gh` for `github.com`, `tea` for a host `tea login list` knows, `glab` for a host `glab auth status --all` knows. Any other host gets a question rather than a guess, since sending a Bitbucket remote to `glab` would only produce errors.

The templates are self-contained static HTML and CSS: no JavaScript, which a file page in an overlay would not run without `--js`, and no fonts, images or stylesheets from anywhere else. Every color is derived from `--agterm-background`, `--agterm-foreground` and `--agterm-color-*` with a fallback, so the same file also reads in a browser.

`scripts/show.sh FILE` is the only thing that touches agterm. It reads the session node from `tree --json --window "$AGTERM_WINDOW_ID"`, because `tree` without `--window` reports the frontmost window only, and a session in a background window would read as missing when you switch windows while the page is being written. Every call also passes `--socket "$AGTERM_SOCKET"`: `agtermctl` never reads that variable, so a bare call in a second agterm instance would reach the socket of the one already running. It reloads the page when the same file is already shown, and otherwise closes whatever page is up and opens the new one with `--size-percent 95 --follow`. It then polls `htmlOverlays[].state` for about five seconds, up to 25 reads 0.2 seconds apart, and prints the state it last saw. A `failed` state exits non-zero with the page's error, so the agent fixes the page instead of reporting success; a page still `loading` when the time runs out is reported as such, with exit zero. The comparison against the shown file resolves the parent directories on both sides first: `/tmp` is a link to `/private/tmp` on macOS, so the same page can be named both ways, and a plain string compare can miss the match and close and reopen the page on every follow-up.

## Limits

Showing a page closes any other HTML page or URL already open in the session-wide overlay slot of that session, and replaces a HUD panel posted there. It never replaces a running program: while a program overlay is open, `show.sh` refuses and says where the page was written.

Pages are written to the Claude Code session's scratchpad directory when it has one, otherwise to `/tmp/agdoc/`, and are never cleaned up. The name follows the subject and design, `pr-45-brief.html`, so a repeat run overwrites the previous page for the same subject.

The skill takes the subject's content from the forge as it is at the time of the run; a page left open does not update when the PR does.
