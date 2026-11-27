---
worth: maybe
where: agtermCore/Sources/agtermCore/AgentHooksInstall.swift:backupPath
added: 2026-11-27
---
# installer backups overwrite the previous .bak

Every Agent Status Hooks install that changes a config file (Claude `settings.json`, Codex
`config.toml`, agy and Copilot hooks, the moved Copilot cookbook file) writes the old contents to
`<file>.bak`, replacing any `.bak` already there. The first install keeps the user's pre-agterm file;
a later install that changes the file again (a marker refresh after an upgrade) replaces that backup
with a copy agterm already modified, so the original is gone after two changing installs.

Not decided: keeping the first `.bak` preserves the original but leaves a stale backup after the user
edits the file, and numbered or dated backups accumulate files in the user's config directories.
Surfaced reviewing PR #1120, whose Copilot backups follow the same convention.
