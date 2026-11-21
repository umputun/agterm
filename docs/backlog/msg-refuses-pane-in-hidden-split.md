---
worth: maybe
where: agtermCore/Sources/agtermCore/AppStore+Messages.swift:livePanes
added: 2026-11-15
---
# messages to a pane in a hidden split are refused as unknown pane

Seen on the deployed build on 2026-11-15: a session's split had been shown, codex running in its right pane, then
hidden (`tree` reported `split: false`, `hasSplit: true`). `agtermctl msg send --to SESSION:RIGHT-PANE-ID` was
refused twice with `unknown pane`, while `tree --json` still listed the right surface with that same `paneID`. After
`session split on`, the identical send was delivered at once.

`livePanes` keeps a slot only when `surface.isRealized`; the tree's `paneID` reads the token without that check.
[Inference] the hidden split's surface reports not realized while it is off screen. `control-api.md` says only "a
split hidden since launch has none", which suggests a split hidden after being shown should stay addressable.

Open question before any fix: whether a hidden split should receive mail (its shell keeps running, and the chat
recipe's peer often sits there) or whether the tree should stop reporting a `paneID` the bus will refuse. Repro:
show a split, run a program there, hide the split, `msg send --to` its pane id.
