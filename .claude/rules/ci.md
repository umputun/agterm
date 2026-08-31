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
- `build` restores separate revision-keyed caches for libghostty and zmx, including each build stamp,
  installs xcodegen, runs Release `scripts/build.sh`, asserts both helpers have valid signatures and no
  entitlements, then Debug `scripts/test-app.sh`. A zmx pin change does not rebuild libghostty. Keep both
  app builds: Release exercises the whole-module optimizer and its SIL-deserializer failure. Debug provides
  `ENABLE_TESTABILITY` for `DockMenuTests`'s `@testable import agterm`. Do not enable testability in the
  notarized Release app.
- Three entitlement assertions run, all because a wrong entitlement set stays green. The first two read
  the built Release app. The first guards issue #396: `--deep` with `--entitlements` stamps the app's TCC
  entitlements onto bundled helpers. `scripts/release.sh` repeats it after its
  Developer ID re-sign, which runs after CI's copy and is not covered by it.
  The helper check covers both `agtermctl` and zmx and also verifies their signatures. Use
  `codesign -d --entitlements -`; the `:-` spelling is deprecated and warns.
- The second pins the app's own Release set to the seven TCC keys, so neither a Debug-only hardened-runtime
  exception nor a dropped TCC key can ship. It ignores `com.apple.security.get-task-allow`, which the
  ad-hoc "Sign to Run Locally" identity adds and the Developer ID re-sign drops. It compares `key=value`
  through `jq ... tojson`, not key names: a key set to `<false/>` is not granted and macOS treats it as
  absent, and codesign accepts `<string>true</string>`, which is not a Boolean and renders identically to
  one without `tojson`. Changing the set means editing that list in the same commit.
- The third reads the two entitlements files rather than a build, and derives Debug's expected content
  from the shipping file: Debug must be the shipping set plus exactly the three exceptions. Without it a
  TCC key added to the shipping file and missed in the Debug one leaves every job green, and Debug
  silently unable to prompt for that permission.
- Debug and Release sign from different entitlements files. `agterm/agterm-debug.entitlements` adds
  `disable-library-validation`, `allow-jit` and `allow-unsigned-executable-memory`: Debug is ad-hoc signed
  and split into a stub plus `agterm.debug.dylib`, and `agtermTests` loads an ad-hoc `.xctest` into that
  app, so library validation would reject both on a Team-ID mismatch. The Release bundle holds no dylib
  and JIT-links nothing, so `agterm/agterm.entitlements` carries none of the three. The re-sign in
  `project.yml` reads `$CODE_SIGN_ENTITLEMENTS` rather than a literal path, so it follows the
  configuration. Restoring a literal path there would re-sign Debug from the shipping file, stripping the
  three exceptions and breaking the ad-hoc `.xctest` load in `make test-app`.
- A separate `cookbook: ["cookbook/**"]` filter gates the Linux `cookbook` job. Recipe-only changes run
  no macOS jobs. Keep `.github/workflows/ci.yml` in both filters: the inline cookbook checks must run when
  changed; its Swift membership also runs macOS jobs.
- The cookbook job builds nothing. It compares the `cookbook/README.md` table and recipe directories in
  both directions; requires kebab-case directories, a `README.md` with all six exact
  (`grep -qxF`) headings, and shebangs for `.sh`/`.zsh`/`.py`; runs `shellcheck` on `.sh`; parses `.zsh`
  with `zsh -n`; runs `ruff check` on `.py`; and executes every `test_*.py` regression script directly.
  `shellcheck` is preinstalled. Install absent `zsh` and `fish` together before the shell gates (`fish`
  runs the Claude resume regression), and install `ruff` through `pipx` because the runner's python is
  externally managed.
- Recipes are not shell-only. A language gains a gate by adding its extension to the shebang glob plus a
  lint or parse step; until then it merges unchecked, which is why `cookbook/CONTRIBUTING.md` tells a
  contributor to flag any other language in the pull request. Keep that file, `cookbook/README.md` and
  this bullet in step when the set changes.
- Keep explicit `shell: bash` on every cookbook validation step with a pipeline or process substitution.
  It supplies bash process substitution and `bash -eo pipefail`; default `bash -e` can hide a failed
  `find` behind successful `xargs -r`. Use `-print0 | xargs -0 -r` for whitespace and empty matches,
  plus `-n1` for `zsh -n` because it parses only its first path.
  Keep `[ -d "$d" ] || continue` so an empty recipe tree does not
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
