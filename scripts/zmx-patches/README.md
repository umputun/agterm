# zmx patches

`scripts/setup.sh` applies every `*.patch` here, in name order, to a fresh checkout of `ZMX_REV` before
building, and every `ghostty/*.patch` to a private checkout of the ghostty revision that `ZMX_REV` pins
in its `build.zig.zon`. The digest of both sets is part of `.zmx-build-stamp`, so editing one rebuilds
zmx. A daemon already running keeps the zmx it was started by. `scripts/setup-zmx-linux.sh` builds the same
patched tree for `aarch64-linux-musl` and `x86_64-linux-musl`, the zmx agterm-server runs, each under its own
stamp in `build/linux/<arch>/`, so a patch has to build for Linux as well as macOS.

Each patch is a plain `diff -ruN` against a pristine copy of the tree it patches, made so `git apply`
takes it with `-p1`: the zmx patches against `ZMX_REV`, the `ghostty/` ones against the ghostty revision
in that `ZMX_REV`'s `build.zig.zon`. To change one, check out both trees side by side as `zmx` and
`zmx-ghostty`, apply the ghostty patches to `zmx-ghostty` and then the zmx patches to `zmx`, since `0002`
makes zmx build against `../zmx-ghostty`. Edit, run `zig build test` in `zmx`, then regenerate the file
against the pristine copy of its own tree. Moving `ZMX_REV` means re-applying them by hand where they no
longer apply, and re-running `check.py`.

- `0001-explicit-leadership.patch` lets a terminal own which client leads a session. A client attached
  with `ZMX_MANAGED=<token>` leads only by claiming at attach (`ZMX_MANAGED_CLAIM`), never by typing, and
  reports its role as a title under a reserved prefix that carries the token. `zmx screen` reads the
  daemon's own terminal, which always has the leader's layout, and `zmx type` queues input with an
  acknowledgement and without taking the lead. A session switch is ignored while the leader is managed.
  A client that does not set the variable behaves as upstream does. `.claude/rules/control-api.md` owns
  how agterm uses it.

- `0002-private-ghostty-dependency.patch` points zmx's ghostty dependency at `../zmx-ghostty`, the
  private checkout `setup.sh` patches, in place of the zig package cache. Its context names the pinned
  revision, so a `ZMX_REV` that moves ghostty stops it applying. zmx's build reads the dependency hash
  as its reported ghostty version, so the patch writes that string in, marked `+agterm`.
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
- `ghostty/0001-formatter-unstyled-blanks.patch` fixes the snapshot a re-attach replays. The formatter
  wrote cells a program skipped with a cursor move as spaces under the previous cell's style, so a gap
  after a colored run came back painted; a skipped cell now closes the style first. Spaces the program
  wrote keep their style. Not agterm's `GHOSTTY_REV`: this is the ghostty zmx links, nothing else.

`check.py <zmx>` drives managed clients on ptys of different sizes against one daemon in a throwaway
`ZMX_DIR`, prints one line per rule, and exits nonzero when any of them is broken.
