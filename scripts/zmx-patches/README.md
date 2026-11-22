# zmx patches

`scripts/setup.sh` applies the patches in this directory in name order to a fresh checkout of `ZMX_REV`.
The revision, target, Zig toolchain, and patch digest make up `.zmx-build-stamp`. A daemon already running
keeps the zmx it was started by. `scripts/setup-zmx-linux.sh` builds the same tree for both Linux musl
architectures, with a separate stamp under each `build/linux/<arch>/`.

To update a patch, apply the series at the pinned revision, edit the source, and run
`env -u ZMX_NO_DETACH_KEY zig build test`: agterm panes export that variable, and an upstream test that
unsets it aborts Zig 0.17's test runner.
Generate a diff against the tree with the preceding patches applied. Run `check.py` against the built
binary after moving `ZMX_REV`. zmx resolves its Ghostty dependency from its own build manifest. That
Ghostty version preserves skipped cells during VT replay by moving the cursor across them.

- `0001-explicit-leadership.patch` lets a terminal own which client leads a session. A client attached
  with `ZMX_MANAGED=<token>` leads only by claiming at attach (`ZMX_MANAGED_CLAIM`), never by typing, and
  reports its role as a title under a reserved prefix that carries the token. `zmx screen` reads the
  daemon's own terminal, which always has the leader's layout, and `zmx type` queues input with an
  acknowledgement and without taking the lead. A session switch is ignored while the leader is managed.
  A client that does not set the variable behaves as upstream does. `.claude/rules/control-api.md` owns
  how agterm uses it.

- `0003-atomic-socket-publish.patch` gives a session socket its name only after it listens. Upstream binds
  the session path and then listens, and `zmx list`, attach and the commands that connect to a session
  delete a path that refuses a connection as stale. A probe between bind and listen can unlink the new socket
  as stale and leave the daemon unreachable. The patch binds and listens in `.s/<pid>` beside the sessions,
  a directory, which listing in every zmx version skips, then hard-links the socket to the session name. The link fails when the
  name exists, so a losing creator gets the same `AddressInUse` a bind gave it and never removes the
  winner's socket. When `.s` cannot be made or the staged path is too long for `sockaddr_un`, it binds the
  session name directly and keeps the old window.
- `0004-managed-exit-keeps-screen.patch` keeps the screen when a managed client exits. Upstream writes RIS
  on every attach exit, which erases a Live `--command --wait` pane's output under its hold prompt. A client
  with a valid `ZMX_MANAGED` instead turns off the input reports a program may have left on and resets SGR
  and the OSC colors. An unmanaged client and a session switch still write RIS.
- `0005-detached-create.patch` lets agterm-server start a pane with no terminal. `attach --detached NAME
  [command...]` creates the session as an attach would and returns, refusing a session that already answers;
  upstream `run` cannot do it, since it always starts bash and types the command into it. With
  `ZMX_EXIT_FILE` set, a session whose shell exits writes `exited` to that path, atomically, before its socket
  goes, so a session found gone without a record was killed; teardown then ends the shell's process group as
  upstream does. A killed session writes nothing, and the shell never sees the variable. Create and attach
  hand labels the bare name, since upstream's prefixed one is prefixed again under `ZMX_SESSION_PREFIX`.
  The creator exits only once the forked daemon acknowledges its `setsid`, or after a 1 s bound: agterm's
  host runs it as its PTY's session leader, whose exit hangs up a daemon still in its process group.
- `0006-single-da-answer.patch` keeps a DA1/DA2 query from being answered twice. Until a client sends
  Init, the daemon answers such queries itself, but upstream also forwards them to an attach it accepted
  and has not yet heard Init from, whose terminal answers again; the program reads the spare reply as the
  answer to its next query. The daemon now drops each query it answered from that output.
- `0007-drain-output-on-exit.patch` keeps a session's last output when its shell exits. Upstream's attach
  client returned at the daemon's hangup, dropping output it had read but not written and output still
  queued behind the hangup, and the daemon made at most one more write per client at the PTY's EOF before
  shutdown freed the rest. A hangup with the session's socket still in place, a detach or a daemon that
  died, returns as before. After any other the client reads the socket to EOF and writes stdout until both
  are done, reading the socket only while stdout keeps up, under one 2 s deadline; on a terminal it stops
  200 ms short of it, so the reset still fits under it. On macOS TCSAFLUSH, and the exit's close of the
  tty, wait for a terminal that may never read, so output it has not taken by then is flushed and termios
  is restored without TCSAFLUSH; a reset it has not taken by the deadline is flushed too, leaving the
  terminal in the session's modes. The attach a session switch returns through shares the deadline. On a
  shell exit the daemon goes on sending what its clients have not read, until none is left or one 2 s
  deadline shared by all of them passes, and takes no new attach, input or command meanwhile. A kill ends
  the daemon at once; its clients write only what they already hold, under their deadline.
- `0008-reclaim-dropped-lead.patch` lets an attach take back a lead it lost with its link. Every managed
  client sends its `ZMX_MANAGED` token in a new `Identity` message after `Manage`, followed by the token in
  `ZMX_MANAGED_RECLAIM` when that is set. At Init such a client leads while the leader is the attach that
  token names, or one that took a vacant session without claiming and has sent no key, paste or mouse
  press since, control keys, Esc and kitty paste events included and a terminal's own replies not; otherwise it
  attaches as before. A daemon without the patch ignores the unknown tag.
- `0009-legacy-ipc.patch` lets the new client reach daemons still running agterm's zmx 0.8.1, so Live
  sessions survive the upgrade and a reset can end them. It sends an Info request both framings read and
  keeps the framing the reply uses for that connection, mapping `Manage` and `Identity` to their 0.8.1
  tags, 22 and 26. A first frame that reads both ways, an 0.8.1 one-byte Output whose header padding is
  not zero or a current Output of a multiple of 256 bytes, is current when the bytes after it cannot open
  an 0.8.1 frame, and is otherwise retried on a fresh connection.
  `tail` and `run` keep upstream framing, because the probe would swallow the one `TaskComplete` a task
  sends, and refuse an 0.8.1 daemon, which misreads it: `run` sends its task on the fresh connection the
  probe returns, and `tail` probes on a second connection after subscribing.
  `write` refuses an 0.8.1 daemon, which drops a file past its input cap and
  still acknowledges it, and so do `history --screen` and `--scrollback`, which 0.8.1 has no capture for.
- `0010-caller-owned-socket-path.patch` backports upstream `f5d604e`: the daemon no longer frees the
  socket path its caller owns, which aborted it at shutdown under Zig 0.17.
- `0011-init-keeps-frame-boundary.patch` keeps the unsent tail of a frame a short write left half sent
  when a client's first Init clears what it was sent before attaching, so the client never reads the next
  frame from inside it.
- `0012-bounded-signal-cleanup.patch` lets an attach client stopped by a signal exit while nothing reads its
  terminal. Upstream catches SIGTERM, SIGHUP and SIGINT and leaves through a detach's `TCSAFLUSH` and
  blocking reset, which on macOS wait for the terminal to read them. The client instead flushes what is
  queued, restores termios at once and gives the reset 100 ms.

- `0013-hold-until-attach.patch` lets a detached create hold its command until a terminal attaches.
  With `ZMX_HOLD_UNTIL_ATTACH=<seconds>` set, `attach --detached` forks the child as usual but parks it
  before `exec` on a close-on-exec pipe. The first terminal client's Init releases it once leadership and
  the PTY size are set, or the bound does with no terminal attached; a kill delivered before the bound, or
  a teardown, closes the pipe and the child exits without running. A program that queries the terminal at startup (codex reads OSC 10/11
  once) then reaches the attached terminal instead of a creator that answers only DA. A follower's Init
  does not release; a zero or non-numeric value fails the create, and the variable is unset before exec.

`check.py <zmx>` drives managed clients on PTYs of different sizes against one daemon in a throwaway
`ZMX_DIR` and exits nonzero when a check fails. Pass a second argument pointing to agterm's patched
zmx 0.8.1 binary to also verify listing, claiming and reclaiming the lead, typing, reading the screen,
printing, refusing `write`, `run` and `tail`, and killing across the upgrade.
