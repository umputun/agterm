---
paths:
  - ".github/workflows/**"
---

## CI (`ci.yml`)

- **`ci.yml` runs on push/PR to `master`, gated by a `dorny/paths-filter`** (`**/*.swift`,
  `agtermCore/**`, `agterm/**`, `project.yml`, `scripts/**`, `.swiftlint.yml`, `ci.yml`).
  Jobs: a `test` job (`swift test --enable-code-coverage` in `agtermCore`, then
  `xcrun llvm-cov export … -format=lcov`, then uploads the lcov as an artifact),
  a `coverage` job (the ONLY `ubuntu-latest` job) that downloads that artifact and does a
  `continue-on-error` upload to Coveralls via `coverallsapp/github-action@v2` with `secrets.GITHUB_TOKEN`,
  a `lint` job (`brew install swiftlint` then `swiftlint lint --strict` — no build, it only parses sources),
  and a `build` job (`brew install xcodegen` then `scripts/build.sh`, Release, with
  `GhosttyKit.xcframework` + ghostty/terminfo resources restored from an `actions/cache` keyed on
  `scripts/setup.sh`), the mac jobs on `macos-26`, concurrency cancel-in-progress.
  There is NO `release.yml` — releases are cut locally; see `.claude/rules/release.md`.
- **The Coveralls upload runs on Linux ON PURPOSE.**
  `coverallsapp/github-action@v2` installs its reporter from a brew tap on macOS (blocked by Homebrew's
  new tap-trust gate), but downloads a prebuilt binary on Linux, so the mac `test` job hands the lcov to
  the `ubuntu-latest` `coverage` job to upload.
  Because the two jobs are different machines, the `test` job rewrites `llvm-cov`'s absolute `SF:` paths
  to repo-relative (strips `$GITHUB_WORKSPACE/`) so the Linux reporter resolves each source file against
  its own checkout; skip that and the reporter matches nothing and prints `🚨 Nothing to report`.
  The upload step is `continue-on-error`, so a masked failure shows green — verify the actual Coveralls
  build/API after changing anything here, never trust the check color alone.
- **CI does NOT run the XCUITests** — it builds the app but never test-runs the app target;
  only the host-free `swift test` runs in CI.
  So the Coveralls badge reflects `agtermCore` coverage ONLY — the app target
  (SwiftUI/AppKit/libghostty) is manually tested and excluded, not "the whole app is N% covered".
- **The `lint` job is `--strict`**, so any swiftlint warning fails the build (see the `make lint` note in
  the root `CLAUDE.md`).
