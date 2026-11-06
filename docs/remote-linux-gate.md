# Mac-to-Linux attach gate

`scripts/linux-origin-gate.sh` checks that today's per-session attach (`zmx attach HOST ID`) works from a Mac to
a Linux origin over real ssh, presentation stream included. It drives an isolated Debug instance, never the live
terminal.

## Running it

```bash
make build                                    # the Debug bundle the script launches
export AGTERM_STATE_DIR=/tmp/agg              # short, under /tmp; the script refuses anything else
scripts/linux-origin-gate.sh HOST [SESSION]
```

- `HOST` is any destination the user's own ssh reaches with key auth, `ssh://user@127.0.0.1:2222` included.
  The origin's `agtermctl` and zmx must be on its PATH or in `~/.local/bin`.
- `SESSION` is an origin session id as `zmx tree HOST` lists it; the first listed is used when omitted.
- `AGTERM_GATE_APP` points at another Debug bundle.

The script refuses an unset state dir, the live or `agterm-debug` one, a directory outside `/tmp`, and one too
long for a control socket. It stops its Debug instance by pid on exit and reports any `agterm.debug` entry
`lsappinfo` still lists. Results go to `$AGTERM_STATE_DIR/gate-results.txt`; the exit status is 1 when an
asserted step fails.

## Steps

Origin commands run as `ssh HOST agtermctl ... --target SESSION`; Mac checks poll `tree --json` for up to 15 s.

| step | origin | asserted on the Mac's attached row |
|---|---|---|
| attach, group | a companion made with `session new --parent`, then `zmx attach HOST SESSION --companions` from the Mac | parent and companion rows both `presentation.state == "connected"` |
| status | `session status active` | `status == "active"` |
| context | `session context <nonce>` | `context` equals the nonce |
| hud | `session hud`, then `hud close` | `hud` set, then cleared |
| ask | `ask "gate ask"` (blocks), then `ask cancel <id>` | `ask.replica == true`, then `ask` cleared; the origin call exits 2 (cancelled) |
| program overlay | `session overlay open --block 'sleep 3; exit 7'` | `overlay` true, then false; the origin call exits 7 |
| page | `session overlay open --html FILE` | an `htmlOverlays` entry with `replica` and the origin page's `id` |
| detach during page, ask, program | the Mac closes its row, then attaches again | the interaction showing first is asserted; what the detach does is recorded |
| relaunch | the Debug instance is stopped and launched again | recorded: attached rows are not restored by design |

A blocking origin call still running 15 s after its step is recorded as pending, cancelled on the origin, and its
ssh ended. Every other origin call gives up after 20 s. The companion and the page file are removed on any exit.

## Results

Filled by the first run against `scripts/server-container.sh` (plan Task 5).
