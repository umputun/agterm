# Keymap cheat sheet

One chord shows your own keyboard cheat sheet in an overlay, and a chord you bound but never wrote down gets a drafted row before the sheet opens.

## What it does

Press the chord and the sheet you wrote about your own keymap renders over the session, in a floating overlay. `q` closes it.

The sheet is a markdown file you write and keep, not generated output. That is the point: an action name says what the code does, and the thing you forget is why you reach for a chord. `previous_attention_session` does not tell you that the chord walks the sessions waiting on you and skips the ones still working. A sentence you wrote does.

So nothing here rewrites your sheet. What it does instead, on the press after you bind something new, is draft a row for the chord the sheet has never heard of, ask a model what the binding does, and append it to a holding section at the end. You move it into the right table and put it in your own words. The chord is documented from the moment it is bound rather than whenever you next remember, and the sheet you wrote is never touched.

A progress panel sits over the session while the model is out, so a press that takes three seconds does not look like a press that did nothing.

With no model available, or with drafting turned off, the sheet still opens and a banner above it names what is undocumented:

```
> This sheet has drifted from keymap.conf.
>
> Bound but not documented: cmd+ctrl+m, cmd+ctrl+shift+m
```

With no sheet at all, the first run writes one from your bound chords, as a table of chord and action name to rewrite.

## Requirements

- The first agterm release after 0.21.0, for the `PATH` a custom command is spawned with. The fix is `babc760` on master and unreleased as this is written, so the version number goes in here when it ships. Up to and including 0.21.0 the runner handed a custom command launchd's own `PATH` — `/usr/bin:/bin:/usr/sbin:/sbin` — and a bare `agtermctl` exited 127 with nothing on screen (#393). This recipe relies on the fix rather than working around it, which is what keeps the opener free of hardcoded directories. `session hud`, the progress panel over a model call, needs 0.21.0; `session overlay open --follow` and `--size-percent` are 0.8.0.
- Python 3.7 or later, which every supported macOS ships. Standard library only.
- [glow](https://github.com/charmbracelet/glow), to render the markdown. Not found, and the overlay falls back to `less -R` and raw markdown rather than failing. `AGTERM_CHEATSHEET_PAGER='less -R'` drops the dependency deliberately.
- [Claude Code](https://github.com/anthropics/claude-code), for the drafting. Optional in the sense that everything else works without it: with no `claude` found, the recipe falls back to the drift banner, silently and with no delay. Nothing else here calls a model.

`AGTERMCTL`, `CLAUDE_BIN` and `PYTHON` take an absolute path for a binary in a prefix the runner's `PATH` does not reach.

## Setup

Copy the three files somewhere on your machine, say `~/.local/bin/agterm-cheatsheet/`, and make them executable:

```sh
chmod +x keymap-cheatsheet.sh render-cheatsheet.sh cheatsheet.py
```

The two helpers must sit **beside** `keymap-cheatsheet.sh`; it looks for both in its own directory.

Add the keybinding to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Cheat sheet"  cmd+ctrl+shift+/  ~/.local/bin/agterm-cheatsheet/keymap-cheatsheet.sh "{AGT_SESSION_ID}"
```

Pick a chord that is free in your own keymap. A custom command cannot shadow a built-in, so one that collides is quietly demoted to palette-only and the chord appears to do nothing. On 0.19.0 and later `agtermctl keymap list` shows what every chord resolved to. Either way the command is reachable by name from the action palette, which is the quickest way to tell a bad chord from a broken script.

Press it once. With no sheet at `~/.config/agterm/SHORTCUTS.md` the first run writes one and shows it, so the overlay comes up with your real chords in it. Then edit that file into something worth reading.

Settings, read from the environment. Put them in front of the script in the keymap line, or change the defaults at the top of the scripts — a keymap change needs a reload before it takes effect, an edit to a script does not:

- `AGTERM_CHEATSHEET` is the sheet, `~/.config/agterm/SHORTCUTS.md` by default.
- `AGTERM_KEYMAP` is the file the chords are read from, `~/.config/agterm/keymap.conf` by default. `AGTERM_CONFIG_DIR` moves both at once.
- `AGTERM_CHEATSHEET_DRAFT=0` turns the model off. The banner is then the whole mechanism.
- `AGTERM_CHEATSHEET_MODEL` is the model, `claude-haiku-4-5-20251001` by default. Write the full id: the short `haiku` alias is not recognized here and falls back to the default model, which is a slower and dearer way to write one table row.
- `AGTERM_CHEATSHEET_TIMEOUT` is how long the model gets, 45 seconds by default. On expiry the call is killed and the banner takes over.
- `AGTERM_CHEATSHEET_STAMP` is where the last-checked marker lives, under `~/.cache/agterm/` by default.
- `AGTERM_CHEATSHEET_PAGER` replaces `glow -p -`, and `AGTERM_CHEATSHEET_SIZE` is the overlay size in percent, 90 by default.

## Usage

Press the chord. Read. Press `q`.

After you bind something new, the next press takes a few seconds and comes back with a row for it at the end of the sheet. Move that row into the table it belongs in and rewrite it. The draft is a placeholder that keeps the chord from being forgotten, not the final wording — a model can read `next_attention_session` and the script it calls, and it cannot know why *you* bound it.

## How it works

The keymap line runs `keymap-cheatsheet.sh`, which does two things in order: a maintenance pass, then the overlay.

The maintenance pass runs **before** the overlay opens, and that is forced rather than chosen. A session has one overlay slot, and the progress panel and the cheat sheet overlay both want it, so a panel posted from inside the overlay would have nowhere to go. Running the pass from the custom command also means it has `{AGT_SESSION_ID}` and `AGT_SOCKET` in its environment, which the panel needs to address the session.

The gate is two stages, because a press that needs nothing has to cost nothing:

1. Compare `keymap.conf`'s modification time against a stamp file. Unchanged, and the pass returns immediately — one `stat`, about 40ms including python startup. This is every press but a handful.
2. Changed, so compare the chord sets. Every chord bound in `keymap.conf` has to appear somewhere in the sheet. Nothing missing — a comment edit, a chord you already documented — and the stamp moves forward with no model call.

Only a chord the sheet has never mentioned reaches the model. It gets the keymap lines themselves, not just the chords, so it can read the action name and the script path. It answers against a JSON schema, and the rows are appended under a `## Recently bound, drafted` heading at the end of the sheet.

Appending, rather than inserting into the right section, is deliberate. Cheat sheets are hand-arranged: the one this was written for pairs two related chords per row across four columns. A generic inserter aiming for the right table would eventually corrupt the thing it is trying to keep current. A holding section at the end is a worse-looking sheet and a safe one.

Everything about the model call fails soft. No `claude` found, a non-zero exit, a timeout, unparseable output, or an answer naming a chord nobody asked about — each returns nothing, the stamp is left alone so the next press tries again, and the sheet opens with the banner. The sheet is written through a temp file and renamed, so a killed run cannot leave you with half of one.

A partial answer is the one case that does not retry: three chords missing and one row back means that row is appended and the stamp moves on, so the other two wait for the next keymap edit. The banner keeps naming them in the meantime. Retrying instead would mean a model call on every press for as long as the model refuses to describe one particular chord, which is the worse failure.

Neither script hardcodes a `PATH`, and the two halves get there differently.

The opener is a custom command, so the runner hands it a `PATH` carrying the bundled `agtermctl`, `/usr/local/bin` and `/opt/homebrew/bin`. That is why *Requirements* starts at the release with that fix: an earlier build gives a custom command launchd's bare `PATH`, and a bare `agtermctl` exits 127 with nothing on screen.

The overlay half is not covered by that fix and never will be, because an overlay program is launched by the terminal rather than by the custom command. It gets the app's own `PATH` and nothing the opener exported, so it can resolve neither `glow` nor `python3` for itself.

The answer is not to guess a prefix inside the overlay script, and not to run the reader's shell profile to find one. The opener already has a working `PATH`, so it resolves both and passes them across as absolute paths on the command line, which is the only channel into an overlay. The overlay's command string is `eval`ed by `sh` on the other side, so each word is single-quoted going in; a path containing a single quote is the one case that does not survive. If `glow` is not there, the opener sends `/usr/bin/less -R` instead: raw markdown, but visible, where a failed pipeline would close the overlay at once and look exactly like a chord that never fired.

There are two scripts rather than one because agterm spawns the overlay program itself. Nothing the opener exports reaches it, so the second script takes everything it needs as arguments — which is also why it has no environment override for the sheet script: one set in the opener would never arrive.

The drift check reads `keymap.conf` for two line shapes: `map <chord> <action>`, and `command "<name>" <chord> <shell...>` where the chord is optional. A command with no chord is palette-only and has nothing to document, and requiring a modifier prefix on that second capture is what separates the two cases, since the shell word after a chordless command never begins with `ctrl+`, `cmd+`, `opt+` or `shift+`. Each chord is then looked for in the sheet with its markdown intact. Stripping the backticks first is the obvious move and it breaks the one chord whose key is a backtick, which would shrink to a bare `cmd+ctrl+` and match almost any row. Written either way — `` `cmd+ctrl+j` `` or ```` ``cmd+ctrl+` `` ```` — the row contains the chord as a literal substring, and the boundary rule does the rest.

A chord can also stay bound while its binding changes underneath it, which leaves a row naming the right chord and describing the wrong thing. The chord-set check cannot see that, so a second file beside the stamp records what each chord was bound to as of the last time the sheet was current. A documented chord whose keymap line has changed since is named in a banner of its own — it says the row is suspect and leaves the sentence to you, like everything else here.

That check needs no acknowledgement. It compares against the sheet's own modification time: edit the sheet and every chord is taken as described correctly again, leave it and the same chords are named on every press until you do.

Only one direction is checked. The reverse — the sheet naming a chord that is no longer bound — is almost entirely deliberate: the macOS chords you did not touch, the reserved ones, the ones a sheet lists as freed. Flagging those buries the real finding in noise.

## Limits

A new chord costs one model call on the next press, a few seconds with the default model. Nothing else here calls a model, and a press that follows no keymap change never does. Set `AGTERM_CHEATSHEET_DRAFT=0` if you would rather it never did.

Drafted rows land in a holding section at the end, not in the table where they belong. Filing them is yours to do, and until you do, the sheet has a slightly untidy tail.

The drafted wording is a first pass written from the action name and the script path. It is usually right about what the binding does and it cannot be right about why you wanted it.

Writes go to `~/.config/agterm/SHORTCUTS.md` and to two small files under `~/.cache/agterm/` — the stamp and the record of what each chord was bound to — creating both directories if needed. Each write goes through a `.tmp` sibling that exists for the length of the write and is renamed over the target, carrying the original's permission bits. The sheet is only ever appended to, never rewritten, and an existing sheet is never replaced by a generated one. Shelling out to `claude` also lets that tool keep its own state under `~/.claude/`, which is not this recipe's doing but is not nothing either. No session, workspace or window is closed or changed: the only control commands here are `session hud open|update|close` and `session overlay open`.

A drafted row is one line the model wrote, put into a table in your file, so its text is flattened to a single line and any `|` in it is escaped. Without that, one stray pipe splits the row into extra columns and one stray newline ends the table and leaves the rest of your sheet as loose prose — neither repairable by hand without knowing what the file looked like before.

A chord counts as documented when it appears in a **table row**, and only there. Two rules make that work, and both come from a sheet in daily use.

A chord is matched as a whole chord rather than as a substring, so `cmd+ctrl+shift+s` is not satisfied by a row documenting `cmd+ctrl+shift+space`.

And prose does not count. A sheet says two different things about a chord: "this is what it does", which is an entry, and "this one is still free", which is a note. Both name the chord, so searching the whole file lets the second stand in for the first — and a "still free" line written a year ago then hides a chord someone bound last month. Searching the tables only is what separates them. A sheet with no table at all falls back to the whole text, since reporting every chord as missing helps nobody who writes in paragraphs.

Leader chords like `ctrl+a>a` are matched the same way and work, as long as the sheet writes them exactly as `keymap.conf` does.

The sheet is markdown, and glow renders it. A table wider than the overlay wraps badly rather than scrolling, so keep the right-hand column to a line. `AGTERM_CHEATSHEET_SIZE=100` buys some width back.
