# Long-commands status

Wrap a long-running shell command so the session's row reports `active` while it runs and `completed` or `blocked` when it finishes — without an agent's hooks.

## What it does

`agst` is the wrapper for the rest of your shell. `make test`, `cargo build`, a database restore: prefix it with `agst` and the row goes active while the command runs, then `completed --auto-reset` on success or `blocked --auto-reset` on failure. Both end states clear once you visit the session.

Pass `--blink` and `--sound` to get attention on the end states only — they apply to `completed` and `blocked`, not to `active`, so the row does not pulse or beep the whole time the command is running. `--shape` and `--socket` apply to every status call:

```sh
agst --blink --sound default make test
```

Outside agterm (`$AGTERM_SESSION_ID` unset), `agst` `exec`s the command directly — no status calls, no overhead, same exit code.

## Requirements

- agterm 0.17.0 or later, which shipped `session status --shape`.
- `agtermctl` on your `PATH`, or set `AGTERMCTL` to its full path.

## Setup

```sh
mkdir -p ~/bin
cp agst.sh ~/bin/agst
chmod +x ~/bin/agst
```

## Usage

```sh
agst make test
agst cargo build --release
agst --blink --sound default pg_restore -d warehouse /backups/db.dump
```

The exit code is the wrapped command's, so `agst` is safe in a pipeline:

```sh
agst make test && agst make deploy
```

## How it works

`active` is set before the command runs. The command's exit code is captured without `set -e`, so the final status call runs either way. Status calls are best-effort (`2>&1 || :`): a missing `agtermctl` or closed socket fails silently and the command runs as if `agst` were not there.

`--blink` and `--sound` are forwarded to the end states only (`completed`/`blocked`), not to `active`, so a long-running command does not pulse or beep the whole time. `--shape` and `--socket` apply to every status call including `active`.

`$AGTERM_SESSION_ID` is the gate: agterm exports it into every shell it spawns, so its presence is the signal that a status call has somewhere to land. Outside agterm the wrapper `exec`s the command directly — same exit code, same stdout, same stderr, no fork.

## Limits

Nothing destructive: the wrapper only posts status for its own session.

- The status reflects the command's exit code, not real-time progress. A hung command reads as `active` for as long as it hangs.
- A command that backgrounds itself and returns exit 0 reports `completed` while the real work is still going.
- `active` is set once, before the command starts, and not re-asserted.
- Status calls are best-effort: if `agtermctl` is missing or the socket is closed, the command runs unaffected.
- Ctrl-C kills the wrapper along with the command, so the end status is never posted and the row stays `active` until a later call clears it.
- While the command runs, `agtermctl tree` reports the pane's foreground as the `sh` wrapper's argv, not the wrapped command's.
