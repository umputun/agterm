# zmx patches

`scripts/setup.sh` applies every `*.patch` here, in name order, to a fresh checkout of `ZMX_REV` before
building. Their digest is part of `.zmx-build-stamp`, so editing one rebuilds zmx.

Each patch is a plain `diff -ruN` of upstream's `src/`, made so `git apply` takes it with `-p1`. To change
one, check out `ZMX_REV`, apply the patches, edit, run `zig build test`, then regenerate the file against
a pristine copy of the same revision. Moving `ZMX_REV` means re-applying them by hand where they no longer
apply, and re-running `check.py`.

- `0001-explicit-leadership.patch` lets a terminal own which client leads a session. A client attached
  with `ZMX_MANAGED=<token>` leads only by claiming at attach (`ZMX_MANAGED_CLAIM`), never by typing, and
  reports its role as a title under a reserved prefix that carries the token. `zmx screen` reads the
  daemon's own terminal, which always has the leader's layout, and `zmx type` queues input with an
  acknowledgement and without taking the lead. A session switch is ignored while the leader is managed.
  A client that does not set the variable behaves as upstream does. `.claude/rules/control-api.md` owns
  how agterm uses it.

`check.py <zmx>` drives two managed clients on ptys of different sizes against one daemon in a throwaway
`ZMX_DIR`, prints one line per rule, and exits nonzero when any of them is broken.
