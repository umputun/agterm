---
worth: later
where: agtermCore/Sources/agtermCore/ConfigPaths.swift:77
added: 2026-08-20
---
# the seeded Lazygit example omits --target and can open its overlay elsewhere

The starter `keymap.conf` ships:

```
command "Lazygit"  ctrl+a>g  agtermctl session overlay open 'zsh -lc lazygit' --socket "$AGT_SOCKET"
```

`TargetOptions.target` defaults to `active` (`agtermCore/Sources/agtermctlKit/Commands.swift:69`), and `active`
is resolved when the request reaches the server, not when the chord built its context. The custom command is
spawned detached and fire-and-forget (`agterm/Commands/CustomCommandRunner.swift:336`), so a session or window
switch between the keypress and delivery opens the overlay over whatever is selected by then. The command
reference already tells automated callers to pin it (`site/commands.html:379`), and a custom command has the
stable `$AGT_SESSION_ID` for exactly this.

The fix is one flag: `--target "$AGT_SESSION_ID"`. The line is otherwise valid — `overlay open` does not
require a size flag, so omitting `--size-percent` correctly gives a full-size overlay.

Worth doing because the `#extend` lesson now sends new users to **File ▸ Edit Keymap…**, where they read this
example next to the docs' pinned one and get two different answers. Kept out of the docs change (#PR) because
touching `ConfigPaths.swift` pulls in the full Swift gate run for a one-line seed-text improvement, and no
existing user is blocked by it.

Found by codex while reviewing the paste lines in the `#extend` lesson.
