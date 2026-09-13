---
worth: maybe
where: agtermCore/Sources/agtermCore/ControlProtocol.swift:ControlArgs
added: 2026-09-13
---
# pick cannot open on a chosen initial row

`pick.open` takes items, a placeholder, `--query` prefill and `--allow-custom`; the selection always starts
on the first row and `--query` only re-ranks. A recipe listing windows or sessions cannot open with the
current one selected, so Enter on an untouched list jumps to the first row instead of being a no-op and
up/down do not read as "the one above / below where I am". Raised in discussion #592 (window switcher
recipe); the in-app palette already seeds the selection for the theme picker, so the app side has a
precedent. A `--select <n>` (or by item id) on `pick` would serve every recipe. The author was asked to file
it as its own ask; this entry is the maintainer's note in case he does not.
