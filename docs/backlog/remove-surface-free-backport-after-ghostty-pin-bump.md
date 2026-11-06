---
worth: yes
where: scripts/setup.sh
added: 2026-09-14
---
# remove surface free backport after a ghostty pin bump

The patch in `scripts/ghostty-patches/` keeps the app mailbox draining during surface teardown, including
until in-flight frame callbacks finish. Remove it when `GHOSTTY_REV` includes an equivalent upstream fix;
[ghostty PR 14444](https://github.com/ghostty-org/ghostty/pull/14444) must also keep its drain active
through `renderer.deinit()` to qualify. The patch README describes the required setup and cache cleanup.

Retest the new pin with `scripts/test-surface-teardown.py`: one title producer, eight title producers
with one surface closed, and eight idle surfaces with one closed. CI runs all three against Release.
The upstream issue and earlier samples are at https://github.com/ghostty-org/ghostty/issues/14245 and
https://gist.github.com/umputun/9ffd6da3e3b93d649ae9c109c59823d4.
