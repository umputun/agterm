# agterm

## What it is

A native macOS terminal, SwiftUI over libghostty, with a workspace-to-session sidebar and a full
control API driven by the bundled `agtermctl` over a local unix socket. Shipped as a signed and
notarized `.app` on Homebrew, plus a static site at agterm.com. One maintainer, no on-call.

Two modules. `agtermCore` is a host-free SwiftPM package under Swift 6 complete concurrency checking
with no Xcode, GhosttyKit, AppKit, Metal or CoreGraphics dependency, holding the model, persistence,
parsing, validation, routing, response shaping and static catalogs. The app target is the side-effect
adapter: the SwiftUI shell, the AppKit sidebar, and the C boundary to libghostty.

## What a real failure looks like here

A user's terminal session becomes unusable or is lost: a pane that stops painting, a session that
restores without its shell environment, a spawned command that never runs, a control command that
lands on the wrong session, a crash at the libghostty C boundary. Persisted window and session state
being corrupted is the closest thing to data loss.

libghostty is called through a C boundary from an `@unchecked Sendable` callbacks type, not a
main-actor one, so use-after-free and cross-thread access there are real and have shipped before.

## Blast radius

One user per install, recoverable by relaunch. No server, no customer data, nothing irreversible.
A bad release reaches everyone on Homebrew until the next one, which raises the bar for anything in
the launch, restore or surface-lifecycle paths specifically.

## Reporting bar

Severity follows user-visible consequence: critical for data loss or a broken primary path, major for
wrong results or a broken secondary path, minor otherwise. Documentation inaccuracies are never
critical or major.

macOS is the only platform, so POSIX portability is not a finding on its own, and a shellcheck SC3xxx
on a shipped script is a lint gate rather than a runtime defect.

## Deliberate conventions, not defects

- Comments and docs are kept short on purpose. Only non-obvious constraints, rejected alternatives, or
  why the obvious implementation fails. Narrating code, restating a fact owned elsewhere, or a doc
  comment longer than the body it documents are all defects in the other direction.
- Test comments are rare and one line. No arrange/act/assert labels, no restating an assertion.
- Private by default. Exported only for an out-of-package caller.
- Interfaces are defined on the consumer side; the app target accepts them and returns concrete types.
- SwiftLint runs strict with zero findings required: 200-column lines, 1000-line files, 800-line types,
  raised to 2000 for tests. Disabled and tuned rules are deliberate.
- `agterm/Resources/ghostty`, `agterm/Resources/terminfo` and `GhosttyKit.xcframework` are gitignored
  build artifacts staged from upstream ghostty at a pinned revision, not project source.
- `cookbook/` recipes are third-party work the project publishes but does not own.

## What the project keeps in sync

A new user action is incomplete until the control protocol, the dispatcher, `agtermctl` and the
protocol tests all carry it, and a state-setting command must expose its result on the control tree.
`site/docs.html` is the canonical user guide, `site/commands.html` the canonical command reference,
and the bundled agent skill under `plugins/agterm/skills/agterm/` is the source for installed copies.
A change to the control API, the keymap or the model that updates only some of those is a real finding.
