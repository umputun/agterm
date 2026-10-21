# zmx patches

`scripts/setup.sh` applies every `*.patch` here, in name order, to a fresh checkout of `ZMX_REV` before
building, and every `ghostty/*.patch` to a private checkout of the ghostty revision that `ZMX_REV` pins
in its `build.zig.zon`. The digest of both sets is part of `.zmx-build-stamp`, so editing one rebuilds
zmx. A daemon already running keeps the zmx it was started by.

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
- `ghostty/0001-formatter-unstyled-blanks.patch` fixes the snapshot a re-attach replays. The formatter
  wrote cells a program skipped with a cursor move as spaces under the previous cell's style, so a gap
  after a colored run came back painted; a skipped cell now closes the style first. Spaces the program
  wrote keep their style. Not agterm's `GHOSTTY_REV`: this is the ghostty zmx links, nothing else.

`check.py <zmx>` drives managed clients on ptys of different sizes against one daemon in a throwaway
`ZMX_DIR`, prints one line per rule, and exits nonzero when any of them is broken.
