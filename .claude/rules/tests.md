---
paths:
  - "agtermCore/Tests/**"
  - "agtermTests/**"
  - "agtermUITests/**"
---

## Tests that do not flake

CI runs on a 3-vCPU `macos-26` runner with suites in parallel, so a pass on a 20-core Mac proves little.
These are preventive patterns drawn from `docs/ci-flakes.md`, which keeps each cause and how sure it is.
A newly understood flake gets its entry there, and a rule here only when it shows a reusable test pattern.

- Give each fixture its own instance of any mutable registry or cache that independent tests would otherwise
  share by accident. Parallel suites retaining into `AskRegistry.shared` evicted another test's ask result;
  the store now takes an injected registry and the app keeps `.shared`. Intentional app-wide coverage stays.
- Model expiry and deadline calculations take an injected clock, frozen or advanced explicitly by the test,
  which asserts the computed instant (`jobClock` in `ServerTestSupport`). Real waits on subprocesses, sockets
  and UI stay, each with a bound.
- Size a wall-clock bound for the operation on the slow runner, as a ceiling for a pathological slowdown,
  never a latency target: the near-cap page render went to 30 s and the shell-exit wait to 60 s. When a known
  failure could otherwise pass the wait or hide behind its timeout, assert it by name beside the wait, as
  `aShellThatExitsClosesItsSession` does with `!session.ended`.
- Wait for the state you assert, never for time or for layout luck: a page title read before it arrived and a
  width a runner's 17 px scroll bar never allows failed only on CI.
- A test holding a pty master reads it on every poll while it waits. `zmx attach` exits through
  `tcsetattr(TCSAFLUSH)`, which on macOS blocks until the master drains, so an unread pty keeps the child alive.
- A test stub writes sockets through `UnixSocket.write` and never replies to a request cut off before its
  newline. A raw `write` to a closed peer raises SIGPIPE, which can kill the whole Linux test process; the
  writer behind the one recorded SIGPIPE was never identified, and the stubs were the unguarded writes.
- Keep parameterized arguments short. This one is about diagnosis: `gh run view` stops at a 65 KB argument
  line and drops the failure that follows it.
