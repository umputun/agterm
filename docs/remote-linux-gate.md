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
| `overlay open --text FILE --follow-file` | refused: a log page is not shown on another Mac (2026-11-06); a Mac with `page.text` is expected to show a following replica, not rechecked by hand |
| `overlay open --url http://127.0.0.1:…` | refused: a loopback url names agterm-server's host |
| `pick open --no-block --session ID` | a replica picker with the origin's id |

# Remote window gate

`scripts/remote-window-gate.sh` checks a remote window (`window remote open HOST`) against
`scripts/server-container.sh` under stock sshd, whose `MaxSessions` stays at 10. It drives an isolated Debug
instance, never the live terminal.

```bash
make build
scripts/server-container.sh build && scripts/server-container.sh start
export AGTERM_STATE_DIR=/tmp/agw
scripts/remote-window-gate.sh [COUNT]        # COUNT server sessions, default 20
```

The Debug instance's ssh goes through a wrapper in `$AGTERM_STATE_DIR/bin` that adds the container's key and host
key and logs every call, so the master starts can be counted.

| step | done | asserted |
|---|---|---|
| open | COUNT sessions on the server, one split; `window remote open` | the window `connected`, COUNT rows, every row's presentation `connected`; every server daemon has one client |
| reconnect | every master killed with SIGKILL, as a network loss would | the same, and no connection started twice |
| forward-pages | `busybox httpd` on the server's 127.0.0.1:8099; two sessions open `--url http://localhost:8099/` | each row's page is `http://localhost:<own port>/` |
| forward-reaches | `curl` through both local ports, polled up to 30 s | both return the server's file |
| forward-cancel | one page closed on the server | its port refuses connections (curl exit 7) within 15 s; the other still answers; master pids unchanged |
| ended | a session's daemon killed on the server | the row stays, `ended`, still realized |
| promoted | the split session's primary daemon killed | the row stays with no split, not ended |
| shell-exit | `exit` typed into a session | the row is gone |
| unreachable, back | `docker pause`, then `docker unpause` | `disconnected` with every row kept, then `connected` |
| no-stray-ssh | after the run | every running master start is its own path's master, none a plain session |

Only the ControlPath values this run's ssh log names are counted or killed: the pool directory is shared by every remote
window of the user.

## Results

2026-11-06, `scripts/server-container.sh` with agterm-server from this branch and a Debug build of the same tree, 20
sessions: every asserted step passed, exit 0. Masters left by the stopped instance exited on their own within
`ControlPersist`'s 60 s.

| step | result |
|---|---|
| open | 20 rows connected over 6 masters for 42 counted channels; 21 daemons with one client each |
| reconnect | every row and pane back after every master was killed; 8 starts, each path once (the reconnect probes' own leases opened 2 slots) |
| forward-pages, forward-reaches, forward-cancel | 2026-11-07: both loopback pages served through pooled forwards on their own local ports; closing one refused its port while the other answered and every master pid stayed the same |
| ended, promoted, shell-exit | pass |
| unreachable, back | Disconnected with all 19 rows kept, then connected |

Two defects the gate found, both fixed: the server closed a `catalog.subscribe` connection after its ok reply
(`streamingCommands` lacked it), and a killed master's leftover socket made each replacement `ssh -M` run without
multiplexing, so the pool now removes it before starting one.
