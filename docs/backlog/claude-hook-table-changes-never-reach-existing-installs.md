---
worth: later
where: agtermCore/Sources/agtermCore/AgentHooksInstall.swift:mergeClaudeSettings
added: 2026-08-18
---
# a changed Claude hook mapping never reaches an existing install

`mergeClaudeSettings` skips an event outright when any entry there already invokes the wrapper, so
editing `claudeHooks` (the event-to-state table at `AgentHooksInstall.swift:48`) only affects users who
have never installed. Everyone else keeps the old mapping in `~/.claude/settings.json` until they hand-edit
it, and a reinstall does not correct them. Codex has the upgrade path Claude lacks:
`refreshManagedCodexBlock` rewrites its managed block in place.

The consequence is that any future fix to what a Claude hook event sets ships to new users only, which is
worse than not shipping it. A refresh would have to recognize an agterm-written entry, distinguish it from
one the user edited on purpose, and leave the second alone. Note `.claude/rules/control-api.md:51`: changing
a hook command re-triggers Claude Code's `/hooks` review for every user, so the refresh should rewrite the
state argument without disturbing the command when it can.

Surfaced answering discussion #456, where a proposed change to the `Stop` mapping would have hit exactly
this. Deferred because nothing user-visible is broken today.
