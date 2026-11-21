# zmx patches

`scripts/setup.sh` applies the patches in this directory in name order to a fresh checkout of `ZMX_REV`.
The revision, target, Zig toolchain, and patch digest make up `.zmx-build-stamp`. A daemon already running
keeps the zmx it was started by. `scripts/setup-zmx-linux.sh` builds the same tree for both Linux musl
architectures, with a separate stamp under each `build/linux/<arch>/`.

To update a patch, apply the series at the pinned revision, edit the source, and run `zig build test`.
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
  upstream does. A killed session writes nothing, and the shell never sees the variable.
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
- `0008-legacy-ipc.patch` lets the new client talk to daemons still running the bundled zmx 0.8.1.
  It detects the older wire format with an Info request and uses it for that connection, including the
  older managed attach tag. New daemons use upstream 1.0 framing.
- `0009-bounded-signal-cleanup.patch` restores terminal settings when a signal stops an attach client.
  It bounds the reset write so a session host that stopped reading the PTY can still reap the client.

`check.py <zmx>` drives managed clients on PTYs of different sizes against one daemon in a throwaway
`ZMX_DIR` and exits nonzero when a check fails. Pass a second argument pointing to agterm's patched
zmx 0.8.1 binary to also verify listing, reattaching, typing, reading the screen and history, detaching,
and killing across the upgrade.
