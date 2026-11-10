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
the Codex-root overloads PR #905 adds to `SkillInstall` and `AgentHooksFiles` is a few lines. Surfaced
reviewing #905, which covers the Mac Help and welcome installers only; deferred until those overloads are
on master.
