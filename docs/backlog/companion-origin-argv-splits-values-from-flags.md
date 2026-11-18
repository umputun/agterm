---
worth: maybe
where: agterm/Control/ControlServer+RemoteCompanions.swift:RemoteCompanionRequest.arguments
added: 2026-11-17
---
# companion origin argv splits values from their flags

`RemoteCompanionRequest.arguments` builds the origin command line as separate words: `--cwd X`,
`--command X`, `--name X`. ArgumentParser refuses a following word that starts with `-`, so a companion of
a remote row made with `--name=-label` passes the local parser, reaches the origin as `--name -label`,
and exits 64 there. `refusedArguments` is then true and the user is told "the agterm on HOST is too old
for companions": nothing is created and the message names the wrong cause.

Fix: join each value to its flag (`--cwd=X`, `--command=X`, `--name=X`), as `RemoteSessionCreate.arguments`
does, with a test using a dash-leading value.
