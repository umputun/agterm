---
paths:
  - ".github/workflows/**"
---

## CI (`ci.yml`)

- `ci.yml` runs for pushes and PRs to `master`; concurrency cancels the older run for the same ref. All
  macOS jobs use `macos-26`. Releases are local; see `.claude/rules/release.md`.
- The `dorny/paths-filter` Swift set includes `**/*.swift`, `agtermCore/**`, `agterm/**`, `plugins/**`,
  `.claude-plugin/**`, `.agents/**`, `project.yml`, `scripts/**`, both SwiftLint configs, and `ci.yml`.
  Keep all three plugin paths: `SkillInstallTests` checks the bundled `SKILL.md` command count, every
  manifest path, and agreement among the three versions. A skill/manifest-only release preflight commit
  must run the four Swift jobs.
- `test` runs `swift test --enable-code-coverage` in `agtermCore`, exports lcov, and uploads it.
  `coverage`, the only Swift-gated Linux job, downloads it for best-effort Coveralls.
  `lint` installs SwiftLint and runs `swiftlint lint --strict`; every warning fails.
- `build` restores the libghostty/resource `actions/cache` keyed by `hashFiles('scripts/setup.sh')`,
  installs xcodegen, runs Release `scripts/build.sh`, then Debug `scripts/test-app.sh`. Editing
  `setup.sh` rebuilds libghostty. Keep both app builds: Release exercises the whole-module optimizer and
  its SIL-deserializer failure; Debug provides `ENABLE_TESTABILITY` for
  `DockMenuTests`'s `@testable import agterm`. Do not enable testability in the notarized Release app.
- A separate `cookbook: ["cookbook/**"]` filter gates the Linux `cookbook` job. Recipe-only changes run
  no macOS jobs. Keep `.github/workflows/ci.yml` in both filters: the inline cookbook checks must run when
  changed; its Swift membership also runs macOS jobs.
- The cookbook job builds nothing. It compares the `cookbook/README.md` table and recipe directories in
  both directions; requires kebab-case directories, a `README.md` with all six exact
  (`grep -qxF`) headings, and shebangs for `.sh`/`.zsh`/`.py`; runs `shellcheck` on `.sh`; parses `.zsh`
  with `zsh -n`; and runs `ruff check` on `.py`. `shellcheck` is preinstalled. Install absent `zsh` and
  `ruff` in separate steps immediately before their own; shellcheck cannot lint zsh, and `ruff` needs
  `pipx` because the runner's python is externally managed.
- Recipes are not shell-only. A language gains a gate by adding its extension to the shebang glob plus a
  lint or parse step; until then it merges unchecked, which is why `cookbook/CONTRIBUTING.md` tells a
  contributor to flag any other language in the pull request. Keep that file, `cookbook/README.md` and
  this bullet in step when the set changes.
- Keep explicit `shell: bash` on the layout, shellcheck, and zsh steps. It supplies bash process
  substitution and `bash -eo pipefail`; default `bash -e` can hide a failed `find` behind successful
  `xargs -r`. Use `-print0 | xargs -0 -r` for whitespace and empty matches, plus `-n1` for `zsh -n`
  because it parses only its first path. Keep `[ -d "$d" ] || continue` so an empty recipe tree does not
  turn the unexpanded glob into directory `*`.
- The two-way index scan accepts only lines starting with `|`, so prose links/comments cannot satisfy it
  and deleted directories leave stale rows. It is line-based, so keep fenced sample rows in
  `cookbook/CONTRIBUTING.md`, never `cookbook/README.md`. Executable-bit policy is per recipe and belongs
  in `cookbook/CONTRIBUTING.md` plus local verification, not CI.
- Coveralls runs on Linux because `coverallsapp/github-action@v2` uses a blocked Homebrew tap on macOS but
  a prebuilt Linux binary. The macOS test job strips `$GITHUB_WORKSPACE/` from absolute lcov `SF:` paths
  before transfer. A bad rewrite prints `🚨 Nothing to report` but exits green. Lcov upload, artifact
  download, and Coveralls submission all use `continue-on-error`; inspect the Coveralls build/API after
  changing this path. Core and hosted tests still gate their own jobs.
- CI runs `agtermTests` against the real `TEST_HOST`, with launch-time state/config/socket isolation and
  `AGTERM_HOSTED_TESTS=1` to suppress shells and the control server. It does not run `agtermUITests`.
  The badge reports only `agtermCore` coverage.
