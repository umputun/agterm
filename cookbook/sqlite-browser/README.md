# SQLite browser

Pick one of the repo's SQLite databases in the native picker and browse it in a TUI viewer, in an overlay over the session you pressed the chord in.

## What it does

Plenty of projects carry a SQLite database or two — the application's store, a test fixture, a cache — and opening one up is the quickest way to see what the code actually wrote.

One chord does that, in a proper TUI rather than a `sqlite3` prompt. The picker lists this repo's databases newest first, each row showing how big it is and how long ago it was written:

```
internal/store/data.db
2.4M · just now

testdata/fixture.sqlite3
48K · 3d ago
```

Choosing one opens the viewer in a 90% overlay over the session. The overlay closes when the viewer exits — `q` in tabiew — and the session is where it was.

The repo is whichever one the session sits in, so the same chord in another tab lists that project's databases.

## Requirements

- agterm 0.22.0 or later. `pick` itself shipped in 0.19.0; 0.20.0 is where a caller-supplied picker stopped re-sorting an empty query alphabetically and stopped matching typed text against subtitles, both of which this recipe depends on — newest-first is the order it hands over, and typing `2.4M` must not filter the list by another row's size. 0.22.0 is where `session hud --position` took the nine anchors of a 3x3 grid, which is what puts the "nothing found" panel at the top of the session instead of over the middle of the text.
- Python 3.9 or later, which macOS ships as `/usr/bin/python3`
- [tabiew](https://github.com/shshemi/tabiew) (`brew install tabiew`), or another viewer you point `SQLITE_VIEWER` at.

Set `AGTERMCTL` if your binary is somewhere unusual; the script otherwise takes the `agtermctl` on `PATH`, which the chord's own widened `PATH` provides. The viewer is looked up differently, in the usual install directories before `PATH`, because it has to reach the overlay as an absolute path.

## Setup

Copy the script somewhere on your machine, say `~/bin/`, and make it executable:

```sh
mkdir -p ~/bin && cp sqlite-browser.py ~/bin/ && chmod +x ~/bin/sqlite-browser.py
```

Add an entry to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "SQLite ›" ctrl+a>d ~/bin/sqlite-browser.py
```

`ctrl+a>d` is a leader sequence: press ⌃A, release, then press D. Any chord carrying a modifier works as the leader, and leaving the chord out entirely makes the entry palette-only. The name ends in `›` so the palette shows it opens something rather than doing something.

To use a viewer other than tabiew, set the two variables on the same line. `SQLITE_VIEWER` is the command and `SQLITE_VIEWER_ARGS` is what goes before the path, so a viewer that needs no flags takes an empty string:

```
command "SQLite ›" ctrl+a>d SQLITE_VIEWER=litecli SQLITE_VIEWER_ARGS= ~/bin/sqlite-browser.py
```

`SQLITE_OVERLAY_PERCENT` sizes the overlay, default `90`. `SQLITE_HUD_BG`, `SQLITE_HUD_FG`, `SQLITE_HUD_WIDTH` and `SQLITE_HUD_SECONDS` style the panel that reports an empty-handed run, and `SQLITE_BROWSER_LOG` moves the run log off `/tmp/sqlite-browser.log`.

## Usage

Press the chord in any session sitting in a repo. Type to filter, Return to pick, Escape to cancel — cancelling opens nothing. In the viewer, Escape (or whatever your viewer quits with) closes the overlay.

Check what the picker will show without opening it:

```sh
./sqlite-browser.py --list
```

It prints one line per database, path first, then the size and age, then the count and the root it read. This is the first thing to run when the picker says there are none and you know there are: the path it prints is the repo root it resolved.

The script carries its own tests, which is what to run after editing the scan:

```sh
./sqlite-browser.py --test
```

A run that finds nothing to do — no databases under the root, or a viewer that is not installed — posts a panel over the session saying which, and takes it down after three seconds. Real failures exit nonzero, which agterm banners by itself as `SQLite › (exit 1)`, and post a notification naming what went wrong. Files skipped during the scan are in the log and nowhere else.

## How it works

The scan is two filters, and the order is the whole point. The extension is checked first, against `.db`, `.db3`, `.sqlite`, `.sqlite3` and `.sqlitedb`, because it is free; then the first sixteen bytes are read and compared against `SQLite format 3\0`, because the extension proves nothing. A `.db` that is really a Berkeley DB, a text file, or a `-wal` sidecar never reaches the picker. The cost of that ordering is a database stored under a name nobody would guess, which is not found at all.

What the scan skips matters more than what it keeps. `node_modules`, `vendor`, `venv`, `__pycache__`, `site-packages`, `target` and `Pods` are pruned, and so is every hidden directory — as a rule rather than a list, because `.mypy_cache` alone put 32 of its own SQLite files ahead of every real one in the first repo this ran in, and `.pytest_cache`, `.tox` and `.venv` are the same shape. Symlinked directories are not followed: a checkout carrying a link back to a parent would otherwise turn the scan into an unbounded walk of the filesystem.

Rows are sorted by mtime, newest first, on the assumption that the database just written is the one being debugged. That order is handed to `agtermctl pick` on stdin as JSON and shown as-is.

The file name is treated as hostile, because in a repo you cloned it is someone else's. The viewer's command line is quoted with `shlex`, so `a"; id; :"b.db` reaches `zsh -c` as one argument rather than as a second statement, and a name carrying a control character is refused outright and logged.

PATH is the gotcha, and the two halves of it are not the same. A custom command's own PATH is widened by the runner from 0.22.0 on, with the CLI install directory and Homebrew's prefix, so a bare `agtermctl` resolves from the chord. The overlay it opens is a different matter: nothing widens that one, it is the app's own, and a bare viewer name exits 127 there with the overlay flashing open and vanishing. So the viewer is resolved to an absolute path here and passed as one — which is also why the recipe reports "not installed" up front rather than letting the overlay fail silently.

The overlay is opened without `--follow`. It belongs to this session, and pulling focus to it would move the selection out from under whatever you are doing in another one.

Everything the script needs about where it is comes from the environment agterm exports to a custom command: `AGT_SESSION_PWD` for the repo, `AGT_SESSION_ID` for which session gets the overlay, `AGT_WINDOW_ID` for which window shows the picker, and `AGT_SOCKET` for the instance to talk to. The repo root itself is `git rev-parse --show-toplevel` from that directory, so the chord works from a subdirectory.

`AGT_SESSION_PWD` has three states and they are three different situations, which is worth knowing if you port this pattern. Unset means nobody is passing one — a plain shell run, so the shell's own directory is the subject. A real path is a session. **Set but empty is the trap**: agterm exports every `AGT_` token whether or not it resolved, and a chord fired in a window holding no session gets an empty one while the process is left in the app's own working directory, `/` for a Dock-launched bundle. Read that as "no value, use the cwd" and one keypress walks the entire filesystem, raising a macOS permission prompt for every protected folder on the way. The recipe tests the variable rather than its truthiness, and refuses.

Refusing is easy; saying so is not. With no session there is no target, so the panel and the desktop notification both resolve `active` to nothing and neither arrives — which is the same absence that sent the chord down this path. What is left is the exit code: agterm banners a custom command's nonzero exit by itself, as `SQLite › (exit 1)`, and that is what the reader actually sees.

The other end of the same problem is a session in a directory git does not recognise as a repo, where the scan root is that directory verbatim. A subdirectory is fine and is a normal place to keep a database. The home directory is not: `~/Library` alone holds hundreds of application databases, and reaching `~/Documents` and `~/Desktop` costs a macOS permission prompt each. That one and the filesystem root are refused by name.

## Limits

The viewer opens the database read-write, whatever that viewer's defaults are. Nothing here makes it read-only, and tabiew's `:` commands run SQL against the file you picked.

The overlay takes the session's overlay slot, so a chord pressed while a program overlay is already up is refused rather than replacing it.

The scan walks the whole repo on every press. On a large checkout with a cold page cache that is a visible pause before the picker appears, with no progress shown.

Databases are found by extension, so one stored under a name that is not on the list is invisible to the recipe, however valid its header.

The picker takes at most 1000 rows, which is agterm's own cap. Past that the list is cut to the 1000 newest and the prompt says so.

The chord does nothing in the home directory, at the filesystem root, or in a window with no session. Those are refusals rather than failures — see *How it works* for why.

A file symlink is followed. A cloned repo can carry `cache.db` as a link to a database outside the checkout, and it appears under its repo-relative name.
