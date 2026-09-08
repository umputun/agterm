---
worth: no
where: agtermCore/Sources/agtermCore/AgentHooksInstall.swift:serialize
added: 2026-08-19
---
# merging Claude hooks reorders and reformats the user's whole settings.json

`serialize` writes with `[.prettyPrinted, .sortedKeys]`, so every merge round-trips the entire
`~/.claude/settings.json` through `JSONSerialization` rather than editing the four hook entries in place.
The user's own key order is replaced by alphabetical, indentation is normalized, and float literals drift
(`0.1` becomes `0.10000000000000001`, `1e3` becomes `1000`). No key is dropped, and a file carrying `//`
comments is refused by `parsedObject` rather than silently stripped.

Today this fires once, on first install: a re-run finds the hooks already present and early-returns
`existing` verbatim with `changed == false`, so nobody sees a second rewrite. Any future change that makes
the merge report `changed` on an already-installed file turns it into a rewrite every affected user gets.

Not worth fixing as it stands. `AgentHooksInstaller.swift:222` writes a `.bak` first, the write is atomic
and preserves mode and symlinks, and the file is one the user asked the installer to manage. Preserving key
order and numeric literals would mean a surgical text edit instead of a dict round-trip, which is a
structural change to the same path that owns the malformed-JSON refusal and the backup logic - far more
risk than the cosmetic effect justifies. Revisit if Claude Code ever adopts JSONC for `settings.json`,
since the refusal path would then start declining ordinary files.

Surfaced reviewing PR #461.
