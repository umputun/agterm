# HTML doc overlay

Ask Claude Code for a page about the issue, PR, plan, change or topic in hand, and read it in an overlay over the session.

## What it does

`/agdoc` turns whatever the session is working on into one static HTML page and opens it over the session as a floating panel. With no arguments it works out the subject itself: the issue or PR under discussion, the plan being executed, the change just made, or the current branch. When more than one fits, it asks, offering the likely subjects. With arguments it takes them as the brief, audience included:

```
/agdoc
/agdoc pr 45 for a reviewer
/agdoc the retry logic in internal/queue, from a business point of view
```

It then asks which of four designs to use, unless the brief already names one:

- **Editorial**: serif headings, a hero with the key numbers, a pinned numbered contents list, cards, pipelines and timelines. For explaining a topic, a code area or a plan.
- **Brief**: one screen, two at most. A masthead, a bottom line and a grid of labelled fact blocks. For the status of a PR, an issue, a branch or a release.
- **Classic**: a plain reference page with a contents bar, pills and callouts, read top to bottom.
- **Custom**: no fixed layout. The model designs the view for the content, such as side-by-side columns for an A vs B comparison.

The built-in *Other* answer takes a design you describe in your own words.

The page takes the terminal theme: its colors come from the CSS variables agterm gives every page, so it matches a dark or a light theme without a palette of its own. Every page ends with a collapsed "Markdown copy" box holding the same content as plain markdown, ready to paste elsewhere; asking for the markdown version puts it on the clipboard. A follow-up such as "drop the risks section" rewrites the same file and reloads the panel.

Optionally, "share it" publishes the page on a private link that expires on its own, after you approve the exact copy in a dialog over the session. This part needs a Cloudflare tunnel of your own and is set up separately; without it, everything else works.

## Requirements

- agterm 0.33.0 or later, which added HTML pages in overlays (`session overlay open --html`) and their `htmlOverlays` read-back in `tree --json`.
- Claude Code. The skill uses Claude Code's `allowed-tools` and `CLAUDE_SKILL_DIR`, so it does not load in other agents as written.
- jq.
- Python 3, standard library only, for `scripts/embed-md.py` and `scripts/share.py`.
- Optional: `gh`, `tea` or `glab` for issue and PR subjects on GitHub, Gitea or GitLab. Without a matching CLI the page is built from git and the conversation, and says that forge data is unavailable.
- Optional, for sharing: `cloudflared`, and a Cloudflare account with a domain whose DNS Cloudflare serves. The approval dialog uses `ask`, which shipped in 0.27.0, so 0.33.0 covers it.

## Setup

Copy the skill, its scripts and its templates into one directory under Claude Code's skills:

```sh
mkdir -p ~/.claude/skills/agdoc
cp -R SKILL.md scripts assets ~/.claude/skills/agdoc/
```

The skill finds `scripts/` and `assets/` relative to its own directory, so they must stay together. The three scripts are committed executable and `cp -R` keeps the bit.

Set `AGTERMCTL` in the environment Claude Code starts from if your `agtermctl` is not on its `PATH`.

### Sharing (optional)

Sharing serves pages through one named Cloudflare tunnel on a hostname you choose, `share.example.com` below. Set it up once per Mac:

```sh
brew install cloudflared
cloudflared tunnel login        # pick the domain; writes ~/.cloudflared/cert.pem
cloudflared tunnel create --credentials-file ~/.cloudflared/agdoc-share.json agdoc-share
chmod 600 ~/.cloudflared/agdoc-share.json
cloudflared tunnel route dns agdoc-share share.example.com
```

The last command adds a proxied CNAME from the hostname to the tunnel. The script needs only the credentials file, which can run this one tunnel and nothing else, so `cert.pem` can be deleted afterwards.

Then set these in the environment Claude Code starts from:

- `AGDOC_SHARE_HOST`, required: the hostname routed to the tunnel, `share.example.com` here. The script refuses to share while it is unset.
- `AGDOC_SHARE_CREDENTIALS`, optional: the credentials file, `~/.cloudflared/agdoc-share.json` by default.
- `CLOUDFLARED`, optional: the binary, `/opt/homebrew/opt/cloudflared/bin/cloudflared` by default, which is Homebrew's path on Apple silicon.

## Usage

Inside an agterm session, type `/agdoc` in Claude Code, with or without a brief, or ask in plain words: "show this as a doc", "make an html doc of this PR and show it". Answer the design question. The page opens over the session at 95% of its size without switching you to it, so a page built while you work elsewhere waits on its own session.

The bar above it carries back, forward, reload and open in browser. Close it with ⌘W or the close button in that bar. To change it, say what to change; the panel reloads in place.

Outside agterm the page opens in the default browser instead.

With sharing set up, say "share it", or "share it for 2h"; the default is 24 hours. The page's copy appears in the overlay with a Publish or Cancel dialog over it, and after Publish the link is printed and put on the clipboard. Sharing again after an edit asks again and keeps the same link and expiry. "List shares" shows what is live, and "stop sharing" stops the current page, or the one you name.

## How it works

The skill does the work in seven steps: settle the subject and the angle (technical, business, reviewer, newcomer), choose the design, gather the content, shape it, write the page from the design's template, embed its markdown translation, and show it. Facts on the page come from what it fetched or read; anything else is labelled `[Inference]`, and issue and PR text is treated as data and escaped.

Content comes from git and, for issues and PRs, from the forge CLI that matches the `origin` remote: `gh` for `github.com`, `tea` for a host `tea login list` knows, `glab` for a host `glab auth status --all` knows. Any other host gets a question rather than a guess, since sending a Bitbucket remote to `glab` would only produce errors.

The templates are self-contained static HTML and CSS: no JavaScript, which a file page in an overlay would not run without `--js`, and no fonts, images or stylesheets from anywhere else. Every color is derived from `--agterm-background`, `--agterm-foreground` and `--agterm-color-*` with a fallback, so the same file also reads in a browser.

`scripts/embed-md.py PAGE.html PAGE.md` writes the markdown into the page as a `<details>` box placed before the first `<footer>` or `</main>`, replacing a box an earlier run left, so the skill runs it after every edit and before every show. The markdown is a translation of the saved page rather than a summary: every fact, number and link stays, and only decoration and navigation go. `embed-md.py --test` runs its own tests.

`scripts/show.sh FILE` shows every page. It reads the session node from `tree --json --window "$AGTERM_WINDOW_ID"`, because `tree` without `--window` reports the frontmost window only, and a session in a background window would read as missing when you switch windows while the page is being written. Every call also passes `--socket "$AGTERM_SOCKET"` when that variable is set: `agtermctl` never reads it, so a bare call in a second agterm instance can reach the socket of the one already running. It reloads the page when the same file is already shown, and otherwise closes whatever page is up and opens the new one with `--size-percent 95 --navigation`; it leaves out `--follow`, so opening never moves you to another session. It then polls `htmlOverlays[].state` for about five seconds, up to 25 reads 0.2 seconds apart, and prints the state it last saw. A `failed` state exits non-zero with the page's error, so the agent fixes the page instead of reporting success; a page still `loading` when the time runs out is reported as such, with exit zero. The comparison against the shown file resolves the parent directories on both sides first: `/tmp` is a link to `/private/tmp` on macOS, so the same page can be named both ways, and a plain string compare can miss the match and close and reopen the page on every follow-up.

`scripts/share.py` publishes a snapshot, never the live file. It copies the page to a staging file, shows that copy through `show.sh`, and opens a non-blocking `ask` with Publish and Cancel, Cancel the default, then polls `ask result` once a second for up to ten minutes and cancels the question on any other exit. Only Publish moves the copy where it is served. Either way the overlay then goes back to the file page that was open before, or closes when there was none; a URL page or HUD shown before is not brought back. All live shares go through one local `python3 -m http.server` bound to 127.0.0.1 and one `cloudflared` named tunnel, started by the first share and stopped with the last. Each share sits at `https://$AGDOC_SHARE_HOST/<token>/`, where the token is random and is the only thing keeping it private; the root serves an empty page so it lists nothing. A watcher process per share checks the clock every 30 seconds and stops the share within that interval after its deadline, counted from approval. The `share.py` process that creates a share records its own PID and identity in the share. Until the expiry watcher is up, `list` shows that share as pending and leaves it alone, and a second share of the same page is refused. Once that process is gone, the leftover is cleaned up and no longer keeps the tunnel running. Each process stages its own copy, so overlapping updates of one page each publish only the bytes their own Publish approved. State lives under `/tmp/agdoc-share`, and every stop checks a process's start time and command line before signalling it, so a recycled PID is left alone. `share.py --test` runs its own tests.

## Limits

Showing a page closes any other HTML page or URL already open in the session-wide overlay slot of that session, and replaces a HUD panel posted there. It never replaces a running program: while a program overlay is open, `show.sh` refuses and says where the page was written.

Pages are written to the Claude Code session's scratchpad directory when it has one, otherwise to `/tmp/agdoc/`, and are never cleaned up. The name follows the subject and design, `pr-45-brief.html`, so a repeat run overwrites the previous page for the same subject.

The skill takes the subject's content from the forge as it is at the time of the run; a page left open does not update when the PR does.

A shared page is readable by anyone who has the link until it expires or you stop it, and a copy someone saved cannot be taken back. The link works only while your Mac is awake and online, and a sleeping Mac stops an expired share up to 30 seconds after it wakes. Only the HTML file is published: images, stylesheets or pages next to it are not, which is why the templates keep everything inside the page. While the approval dialog is up, the staged copy replaces whatever page the session's overlay showed. The dialog needs its session selected in its window, not zoomed and not under the dashboard: sharing from a session you are not looking at fails with "session not visible", and switching away while the dialog is up cancels it, so nothing is published.
