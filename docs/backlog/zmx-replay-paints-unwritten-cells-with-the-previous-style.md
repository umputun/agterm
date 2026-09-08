---
worth: later
where: scripts/setup.sh
added: 2026-09-07
---
# zmx replay paints unwritten cells with the previous cell's style

After a live restore of an empty Claude Code session, a black block about three cells wide sits between
the logo and the "Claude Code" title on the eyes row. It looks random but is deterministic given two
conditions: the screen still holds the startup logo, and the pane's grid at restore equals the grid at quit.

Mechanism, verified 2026-09-07 with an isolated Debug instance, a follower zmx client recording the
replay bytes, and a headless pty recording Claude Code's raw output:

- Claude Code draws the eyes row as an orange run with an explicit black background, then jumps to
  column 12 with `CSI 12 G`. The three gap cells are never written, on the first frame and on every
  resize redraw after its `CSI 2 J`.
- zmx re-attach serializes the daemon's screen with ghostty's `TerminalFormatter` (`src/terminal/formatter.zig`,
  same code at zmx's pin `aa21cae` and at agterm's `GHOSTTY_REV`). Empty unstyled cells accumulate in
  `blank_cells` and are written as spaces when the next cell produces output, before that cell's style
  transition, so they go out under the previous SGR. `writeCellRun` does the same when the next cell has the
  same interned style id. Replaying only Claude's first frame into a throwaway daemon reproduces
  `\x1b[48;2;0;0;0m▛███▛█   \x1b[0m`. Upstream fixed only the row-end variant (reset before newlines).
- Nothing repaints because the attach sends the same grid the daemon already had, so `TIOCSWINSZ` raises no
  SIGWINCH and Node emits no resize. Six restarts at two window sizes all attached at the final grid;
  libghostty's 800x600 placeholder never reached the daemon, so there is no agterm-side race.

Not an agterm defect. The size-nudge workaround was rejected: a quick out-and-back coalesces to no change,
a delayed one adds a reflow and still depends on the program repainting.

Fix, written and passing on a ghostty checkout at `82938b6` (Page formatter tests 505 pass 1 skip, full
zig suite 3782 pass), dropped because ghostty gates external PRs behind a vouch request written by the
maintainer in person, then an Issue Triage discussion, then a PR against an accepted issue. Related merged
PR 10134 is the inverse defect. No duplicate in ghostty issues, PRs, discussions, or zmx's tracker.

```diff
@@ -1345,6 +1345,7 @@ pub const PageFormatter = struct {
                     // Cells with no text are blank
                     if (!cell.hasText()) {
+                        try self.closeStyleForBlank(emit, writer, &style, &style_id);
                         blank_cells += 1;
                         continue;
                     }
@@ -2048,6 +2049,22 @@ pub const PageFormatter = struct {
+    /// Reset the style before buffering a blank cell so both emission paths
+    /// materialize the buffered blanks unstyled.
+    fn closeStyleForBlank(
+        self: PageFormatter,
+        comptime emit: Format,
+        writer: *std.Io.Writer,
+        style: *Style,
+        style_id: *u32,
+    ) std.Io.Writer.Error!void {
+        if (!comptime formatStyled(emit)) return;
+        if (style.default()) return;
+        try self.formatStyleClose(emit, writer);
+        style.* = .{};
+        style_id.* = 0;
+    }
```

The trimmed-space branch needs no call: a space has text and leaves the blank block earlier in styled
mode. Tests written against `PageFormatter.init(page, .vt)` on an 80x24 terminal, each also asserting the
point map length equals the output length:

| input | expected |
|---|---|
| `\x1b[41mab\x1b[5Gc\x1b[0m` | `\x1b[0m\x1b[48;5;1mab\x1b[0m  \x1b[0m\x1b[48;5;1mc\x1b[0m` |
| `\x1b[41mab\x1b[49m\x1b[5G\x1b[1mc\x1b[0m` | `\x1b[0m\x1b[48;5;1mab\x1b[0m  \x1b[0m\x1b[1mc\x1b[0m` |
| `\x1b[41mab\x1b[0m\x1b[5Gc` | `\x1b[0m\x1b[48;5;1mab\x1b[0m  c` |
| `\x1b[41m日\x1b[0m\x1b[5Gc` | `\x1b[0m\x1b[48;5;1m日\x1b[0m  c` |
| `\x1b[41mab  c\x1b[0m` | `\x1b[0m\x1b[48;5;1mab  c\x1b[0m` |
| `\x1b[41mab\x1b[0m` | `\x1b[0m\x1b[48;5;1mab\x1b[0m` |

HTML for the first input: two separate `<div style="display: inline;font-weight: bold;">` around the plain
spaces when the run is bold.

Routes if picked up: upstream via the vouch flow, a local patch applied to zmx's ghostty package in
`setup.sh`, or a zmx-side post-process of the snapshot.
