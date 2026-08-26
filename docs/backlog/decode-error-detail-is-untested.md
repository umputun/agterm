---
worth: later
where: agterm/Control/ControlServer.swift:98
added: 2026-08-26
---
# nothing pins the decode error naming the rejected cmd

`decodeDetail` and its use at `ControlServer.swift:356` have no test at any level. The only existing case,
`ControlProtocolTests.unknownCommandFailsToDecode`, wraps a bare `JSONDecoder().decode` in
`#expect(throws:)` and never reaches `handleConnection`, so it stays green under `localizedDescription`,
`String(describing:)`, or any rewrite. A revert to `localizedDescription` returns "The data couldn't be
read because it isn't in the correct format." with no `cmd` name and nothing goes red, while
`.claude/rules/control-api.md:112-117` records that naming the rejected `cmd` is what a caller gets.

`decodeDetail` is `private static`, so `@testable import agterm` cannot reach it. The socket-level route
is the only one without widening visibility: one case in `agtermUITests/ControlAPIUITests.swift`, which
already has `sendCommand`, sending `{"cmd":"restore.bogus"}` and asserting the returned `error` contains
`restore.bogus`. The "Cannot initialize Command from invalid String value ..." text comes from the
compiler-synthesized `RawRepresentable` init in the app binary rather than an OS library, so a `contains`
assertion holds across OS versions.

Surfaced reviewing PR #452, merged as 22f3c7c. It pins a diagnostic sentence rather than behavior a user's
workflow depends on, which is why it was not asked of the contributor on a fifth round.
