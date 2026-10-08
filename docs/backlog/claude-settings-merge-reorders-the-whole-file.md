---
worth: no
where: agtermCore/Sources/agtermCore/AgentHooksInstall.swift:serialize
added: 2026-08-19
---
# merging Claude hooks reorders and reformats the user's whole settings.json

`serialize` writes with `[.prettyPrinted, .sortedKeys]`, so every merge round-trips the entire
`~/.claude/settings.json` through `JSONSerialization` rather than editing the hook entries in place.
The user's own key order is replaced by alphabetical, indentation is normalized, and float literals drift
(`0.1` becomes `0.10000000000000001`, `1e3` becomes `1000`). No key is dropped, and a file carrying `//`
comments is refused by `parsedObject` rather than silently stripped.

This fires on first install, once more for an install still carrying a historical generated command,
which the adapter migration rewrites, and once for an install made before an event joined `claudeHooks`,
as `PermissionRequest` did: the next installer run appends the missing entry and rewrites the file.
Any other re-run finds the hooks already present and early-returns `existing` verbatim with
`changed == false`. Each event added to `claudeHooks` is a rewrite every installed user gets on their
next run.

Not worth fixing as it stands. `AgentHooksInstaller.mergeClaudeSettings` writes a `.bak` first, the write
is atomic and preserves mode and symlinks, and the file is one the user asked the installer to manage.
Preserving key order and numeric literals would mean a surgical text edit instead of a dict round-trip,
which is a structural change to the same path that owns the malformed-JSON refusal and the backup logic -
far more risk than the cosmetic effect justifies. Revisit if Claude Code ever adopts JSONC for
`settings.json`, since the refusal path would then start declining ordinary files.

Surfaced reviewing PR #461.
