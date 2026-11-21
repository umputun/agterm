---
worth: later
where: scripts/setup-zmx-linux.sh:stage_shell_integration
added: 2026-11-21
---
# linux shell-integration fetch has no integrity pin

`stage_shell_integration` downloads ghostty's source tarball for `GHOSTTY_REV` from codeload.github.com and
extracts the zsh, fish and bash integration that agterm-server panes load. Nothing checks the downloaded
content, so HTTPS to codeload is its only protection; the Swift SDK download in `server-build.sh` has a
pinned SHA-256 and the Mac build fetches ghostty through git at the commit (`setup.sh`, `git fetch --depth 1
origin "$GHOSTTY_REV"`), which pins it by hash. Fetching the same way here would close the gap.

Surfaced reviewing PR #1079, which made this fetch HTTPS-only including redirects. CI and `release.sh` run
the script; CI usually skips the download on a current stamp.
