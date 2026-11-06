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
- `SESSION` is an origin session id as `zmx tree HOST` lists it; the first listed is used when omitted. A fresh
  agterm-server lists none: make one with `agtermctl session new` there first.
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
| page | `session overlay open --html FILE` | an `htmlOverlays` entry with `replica` and the origin's `file`; a replica has a page id of its own |
| detach during page, ask, program | the Mac closes its row, then attaches again | the interaction showing first is asserted; what the detach does is recorded |
| relaunch | the Debug instance is stopped and launched again | recorded: attached rows are not restored by design |

A blocking origin call still running 15 s after its step is recorded as pending, cancelled on the origin, and its
ssh ended. Every other origin call gives up after 20 s. The companion and the page file are removed on any exit.

## Results

2026-11-06, `scripts/server-container.sh` (ubuntu 24.04, agterm-server from this branch) and a Debug build of the
same tree: every asserted step passed, exit 0. Every ssh the Mac ran went through the user's ssh, the `-tt`
attach panes included.

| step | result |
|---|---|
| attach, group, status, context, hud, ask, program overlay | pass |
| page | pass; the replica carries a page id of the presenting Mac's own |
| detach during page, program | the origin drops the page or overlay; the Mac reattaches connected with none |
| detach during ask | the origin call ends `cancelled` with `reason: presentation-lost`, exit 2 |
| relaunch | attached rows are not restored, as designed |

Kinds the gate does not assert, checked by hand over the same attach:

| origin command | on the Mac |
|---|---|
| `overlay open --image`, `--markdown`, `--text`, `--url https://…` | a loaded replica page |
| `overlay open --text FILE --follow-file` | refused: a log page is not shown on another Mac |
| `overlay open --url http://127.0.0.1:…` | refused: a loopback url names agterm-server's host |
| `pick open --no-block --session ID` | a replica picker with the origin's id |
