---
paths:
  - ".github/workflows/**"
---

## CI (`ci.yml`)

- **`ci.yml` runs on push/PR to `master`, gated by a `dorny/paths-filter`.**
  Swift-impacting paths include `**/*.swift`, `agtermCore/**`, `agterm/**`, `project.yml`, `scripts/**`, the root/test SwiftLint configs, and `ci.yml`.
  The `test` job runs `swift test --enable-code-coverage` in `agtermCore`, exports lcov, and uploads it as an artifact.
  The `coverage` job is the only Swift-gated `ubuntu-latest` job (the `cookbook` job below is the other Linux one)
  and downloads that artifact for a best-effort Coveralls upload.
  The `lint` job installs SwiftLint and runs `swiftlint lint --strict` without building.
  The `build` job restores the libghostty/resource cache, installs xcodegen,
  runs the Release `scripts/build.sh`,
  and then runs the application-hosted `agtermTests` suite through `scripts/test-app.sh`.
  The cache is an `actions/cache` keyed on `hashFiles('scripts/setup.sh')`,
  so editing `setup.sh` invalidates it and pays the libghostty rebuild.
  That job compiles the app TWICE by design, and the duplication is not removable.
  `build.sh` is `-configuration Release`, which is what exercises the whole-module optimizer
  (the SIL deserializer crash the module-boundary rule in `CLAUDE.md` describes only reproduces there).
  `test-app.sh` builds Debug because `DockMenuTests` is `@testable import agterm`
  and `ENABLE_TESTABILITY` is Debug-only,
  so hosting the tests on the Release product would mean enabling testability in the shipped, notarized build.
  Expect that job to run roughly twice as long as a plain build,
  and do not "fix" it by unifying the configurations.
  All macOS jobs run on `macos-26`, and workflow concurrency cancels an older run for the same ref.
  There is NO `release.yml` — releases are cut locally; see `.claude/rules/release.md`.
- **A second paths filter, `cookbook`, gates the one job that has nothing to do with Swift.**
  `cookbook/**` matches no entry in the `swift` filter,
  so a recipe-only change runs zero macOS jobs and only the `cookbook` job on `ubuntu-latest`.
  Editing `ci.yml` itself still trips the `swift` filter, so a change to this workflow runs the macOS jobs too.
  The job is static verification of the recipe tree and builds nothing.
  It compares the `cookbook/README.md` index table against the directory set in BOTH directions,
  requires every recipe directory to be kebab-case and to carry a `README.md` with all six template headings,
  requires every `.sh`/`.zsh` to start with a shebang,
  and then runs `shellcheck` over every `.sh`.
  `shellcheck` is preinstalled on the `ubuntu-latest` image — it is in the runner-images apt package set —
  so the job installs nothing.
  `zsh` is NOT on that image, so `zsh -n` over the `.zsh` recipes stays a local check;
  the shebang check is the only thing in CI that looks at a `.zsh` file at all.
- **Several details of the `cookbook` job are load-bearing and must not be "simplified".**
  The `[ -d "$d" ] || continue` guard keeps the job green when `cookbook/` holds no recipe subdirectories:
  without it `cookbook/*/` does not expand, `basename` yields `*`,
  and the check errors on a directory named `*`.
  The index comparison is two-directional and reads only lines starting with `|`,
  so a link in prose or an HTML comment cannot satisfy it
  and a row left behind by a deleted directory is reported as stale.
  It reads lines, not rendered tables, so a **fenced example table row** in `cookbook/README.md` would satisfy it
  just like a real row — which is why the sample index row lives in `cookbook/CONTRIBUTING.md`
  and `cookbook/README.md` carries only real rows.
  The `shellcheck` step uses `-print0 | xargs -0 -r`,
  which tolerates whitespace in filenames and exits 0 on an empty match
  instead of failing the step the way the earlier `files=$(find …)` form did.
  The headings are matched with `grep -qxF`, so a heading must be the whole line.
  Deliberately absent is any executable-bit check:
  whether a script is executed or sourced is per-recipe intent,
  so that rule lives in `cookbook/CONTRIBUTING.md` and the local verification set, not in CI.
- **The Coveralls upload runs on Linux ON PURPOSE.**
  `coverallsapp/github-action@v2` installs its reporter from a brew tap on macOS, which is blocked by Homebrew's tap-trust gate, but downloads a prebuilt binary on Linux.
  The macOS `test` job therefore hands the lcov artifact to the Linux `coverage` job.
  The `test` job rewrites `llvm-cov`'s absolute `SF:` paths to repo-relative paths,
  stripping the `$GITHUB_WORKSPACE/` prefix,
  so the reporter resolves them against its own checkout.
  Get that rewrite wrong and the reporter matches nothing and prints `🚨 Nothing to report` while still exiting green.
  That string is the symptom to look for; it is the only thing distinguishing this failure from a successful upload.
  The lcov upload, artifact download, and Coveralls submission are all `continue-on-error`.
  Core tests still gate the `test` job, and hosted AppKit tests independently gate the `build` job.
  A masked coverage failure can therefore show green, so verify the actual Coveralls build/API after changing this path.
- **CI runs application-hosted AppKit tests but not XCUITests.**
  `scripts/test-app.sh` runs the `agtermTests` scheme against the real app `TEST_HOST` after the Release build.
  The scheme's launch environment isolates state/config/socket access before `agtermApp.init()` and uses `AGTERM_HOSTED_TESTS=1` to avoid shells and the control server.
  CI does not run the `agtermUITests` XCUITest scheme.
  The Coveralls badge remains `agtermCore` coverage only because hosted app and XCUITest coverage are excluded.
- **The `lint` job is `--strict`.**
  Any SwiftLint warning fails the build; see the `make lint` note in the root `CLAUDE.md`.
