---
worth: maybe
where: agterm/Resources/markdown/text.js:agtermTextUpdate
added: 2026-11-20
---
# a followed log page lays out its whole tail on every update

Each `agtermTextUpdate` replaces the code element's children, and the first `scrollHeight` read then lays out the
whole `<pre>` again. Measured in a Debug hosted probe (22k ANSI lines, 2 MiB tail, 10 lines appended every
100 ms), medians per update: about 107 ms of layout in a 227 ms update, and 24 ms at a 534 KB default tail. A
default click can approach the 2 MiB cap with 5000 lines averaging roughly 420 bytes.

An append-only update, which drops the lines that left the front with one Range and appends the new runs, was
prototyped and left out. Same-run medians at 2 MiB went 227 to 153 ms without a search and 307 to 228 ms with one,
yet layout stayed at 78 ms, since the tail is still one inline formatting context. The prototype also keeps a
color whose SGR started on a dropped line, where a full parse of the new snapshot shows those lines unstyled.

The candidate is splitting a log page's lines into block children, to see whether layout can stay within the
changed blocks. It has to keep wrapped row measurement (`measureRows`), search geometry, selection and text parity
working; the diff renderer can stay outside it, and the bounded snapshot `LogFollower` pushes stays as it is.
