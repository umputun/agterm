---
worth: yes
where: .claude/rules/control-api.md:113
added: 2026-08-26
---
# control-api.md calls the decode error the only version-skew signal, and its example is the one case it cannot cover

The bullet says the decode error "is the only signal a caller gets that its agterm predates its
agtermctl, and the reason a new command needs no version handshake". The same file contradicts that at
`:598` ("a recipe preflight uses `agtermctl version`"), `version` is in the public catalog at `:147`, and
`reference.md:1227` calls it the number a cookbook recipe's minimum is compared against. A maintainer or
agent reading this file concludes no ahead-of-time check exists and skips the preflight recipes are
required to carry.

The code comment at `ControlServer.swift:351-355` has the matching problem: it names `restore.capture` as
its worked example, and that is precisely the command the mechanism can never diagnose. An app built at
94ab03f has no `decodeDetail`, so a newer CLI hitting the running 0.25 server gets the generic
`localizedDescription` sentence. The mechanism only helps for commands introduced after that server
shipped.

Surfaced reviewing PR #452 (merged as 22f3c7c) and confirmed independently by codex. Fix is wording in
both places: soften "the only signal" to name `agtermctl version` alongside it, and change the comment's
example to a hypothetical future command. Codex proposed translating the legacy error client-side in
`Restore.Capture.run()`; that is a per-command special case matched against another binary's error prose
and both reviewers rejected it as out of proportion.
