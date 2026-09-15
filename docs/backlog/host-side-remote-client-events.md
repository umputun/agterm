---
worth: maybe
where: agtermCore/Sources/agtermCore/RemoteSession.swift:attachPaneCommand
added: 2026-09-15
---
# host-side client.attached / client.detached events for zmx attach

`remote.opened` / `remote.closed` report the LOCAL row. The Mac hosting the daemon learns nothing: attach is
ssh plus `zmx attach`, and the host reads its daemons' client counts only on demand. The names
`client.attached` / `client.detached` are reserved for the host-side pair; do not add the enum cases until
this is built.

The cheapest design found (chat with codex, 2026-09-15): the attach chain we already own becomes a
`/bin/sh -c` script that reports start and end to the host's own control socket through a new narrow
control command, which the host emits through the ordinary ring and hook seam. Constraints established
before it can be called cheap:

- `SocketClient`'s response read has no deadline, so a report to a stalled host would block the attach
  before zmx launches. The report needs a bounded lifetime, stdin from `/dev/null`, and stdout/stderr to
  `/dev/null` so nothing prints onto the pty before the zmx snapshot; zmx keeps the pty. Save zmx's exit
  status before reporting and exit with it.
- A pty probe on macOS `/bin/sh` showed a HUP or TERM trap waiting for the foreground child, reporting a
  false status 0, then the normal path reporting again. One guarded finish path, distinguishing a signal
  reason from an observed child exit. Test under real sshd, including local pane teardown and network loss;
  a blackholed connection may go unnoticed for a while.
- `SSH_CONNECTION` is same-account-spoofable and names the jump host under `ProxyJump`; use the existing
  0600 socket trust boundary and validate only the daemon/pane association, claiming no authentication.
- Contract is best-effort and per attach invocation and pane: `attached` is a reported attach attempt,
  since the start report precedes the zmx launch; `detached` carries an observed exit code or a signal
  reason, whichever ended the client; nothing fires on the host when ssh itself fails to connect; and a
  silent report failure leaves either half absent. Carry an attachment id, the stable daemon/pane identity,
  and the peer session; resolve the host's model location from the stable identity, since roles change
  by promotion or swap during a long attachment.
- An older host without the command must leave the attach untouched.
