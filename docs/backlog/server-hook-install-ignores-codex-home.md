---
worth: later
where: agtermCore/Sources/AgtermServerKit/ServerHookInstall.swift:run
added: 2026-11-10
---
# agterm-server hook install ignores CODEX_HOME

`ServerHookInstall.run` installs the Codex skill (`SkillInstall.install(source:home:)`) and the Codex hooks
(`AgentHooksFiles(source:home:toolPath:)`) into `home/.codex` on the Linux host, so a user who exports
`CODEX_HOME` there gets them in a directory Codex does not read. It already reads `OPENCODE_CONFIG_DIR` and
`XDG_CONFIG_HOME` from `environment`; passing `environment["CODEX_HOME"]` (empty counts as unset) through
the Codex-root overloads #905 added to `SkillInstall` and `AgentHooksFiles` is a few lines, and
`outcome.codex.text(codexHome:)` names the root in the report. Surfaced reviewing #905, which covers the Mac
Help and welcome installers only.

The Mac side resolves the value in `OpenCodeEnvironmentProbe.run` (empty counts as unset, a relative path is
joined to the shell's working directory, then standardized). Move that rule into an `agtermCore` static next
to `AgentHooksInstall.OpenCode.configurationDirectory` first, so both installers resolve `CODEX_HOME` the
same way.
