# Universal (Apple Silicon + Intel) build, CI, and release support

## Overview
- Ship agterm as a **universal binary** (single app/DMG/cask covering both
  arm64 and x86_64), instead of the current arm64-only build.
- The unlock is `GhosttyKit.xcframework`: ghostty's own zig build already has
  a `universal` xcframework preset (`src/build/xcframework.zig`'s
  `Target` enum: `native | universal`), which lipo's an arm64+x86_64 macOS
  slice via zig cross-compilation — no Intel machine is needed to *build* it.
  `scripts/setup.sh` currently forces `native`; flipping that one flag is the
  core change.
- The `universal` preset also bundles iOS + iOS-simulator slices into the
  same xcframework (agterm doesn't use them, but they can't easily be carved
  out without patching ghostty's build.zig). User explicitly accepted the
  extra build time rather than a more surgical macOS-only universal build.
- Single universal cask/DMG (drop `depends_on arch: :arm64`), per user's
  choice — no separate arch-specific distribution artifacts.
- CI (`macos-26` runners, Apple Silicon only) can cross-build both
  architectures in the same job; it cannot natively *run/test* x86_64. A
  Rosetta-based smoke check of the built `agtermctl` CLI helper is the best
  available automated Intel signal. Final manual acceptance testing happens
  on the user's own physical Intel Mac (out of scope for this repo's
  automation — tracked as a Post-Completion step).
- No functional Swift code changes are expected: a repo-wide grep found no
  `#if arch(...)`/runtime architecture branching. This is purely a
  build/packaging/release-tooling change.

## Context (from discovery)
- `project.yml`: `ARCHS: arm64` hardcoded (base settings); `Debug` config sets
  `ONLY_ACTIVE_ARCH: YES`, `Release` sets `ONLY_ACTIVE_ARCH: NO`.
  `deploymentTarget.macOS: "14.0"`. Ad-hoc signing
  (`CODE_SIGN_IDENTITY "-"`, `DEVELOPMENT_TEAM ""`), `ENABLE_HARDENED_RUNTIME
  YES`. No arch-conditional settings anywhere else in the file.
- `scripts/setup.sh`: builds `GhosttyKit.xcframework` from upstream ghostty
  at a pinned `GHOSTTY_REV`, via
  `zig build -Doptimize=ReleaseFast -Demit-xcframework=true
  -Dxcframework-target=native -Demit-macos-app=false`. Present-check skips
  the rebuild if `GhosttyKit.xcframework` + `agterm/Resources/terminfo`
  already exist (cached in CI keyed on `hashFiles('scripts/setup.sh')`).
- Verified via ghostty's own source
  (`src/build/xcframework.zig`, `src/build/GhosttyXCFramework.zig`,
  `src/build/Config.zig`): `Target = enum { native, universal }`, default is
  `universal`. The `.universal` branch builds
  `GhosttyLib.initMacOSUniversal` (a lipo'd macOS arm64+x86_64 static lib)
  plus iOS + iOS-sim slices, and wraps all three into one
  `GhosttyKit.xcframework`. The `.native` branch (what agterm currently
  passes) builds only a host-arch macOS slice.
- `scripts/build.sh` / `scripts/run.sh`: call `setup.sh` → `xcodegen
  generate` → `xcodebuild … build`, no arch-specific logic.
- `scripts/release.sh`: local-only (no `release.yml`), builds Release, then
  authoritatively re-signs with Developer ID (`codesign --timestamp`) after
  `xcodebuild` returns, notarizes + staples the app and the DMG, and
  (behind `--publish`) creates the GitHub release and bumps the Homebrew
  cask. `release_notes()` currently hardcodes: *"Apple Silicon (arm64) only,
  macOS 14 or later."*
- `packaging/agterm.rb`: `depends_on arch: :arm64` restricts the cask to
  Apple Silicon; otherwise a normal single-artifact cask
  (`version`/`sha256`/`url`/`app`/`binary`/`zap`).
- `.github/workflows/ci.yml`: `test` (host-free `swift test` in
  `agtermCore`), `coverage` (Coveralls upload, `ubuntu-latest`), `lint`
  (`swiftlint --strict`), `build` (`brew install xcodegen` +
  `scripts/build.sh`, with `GhosttyKit.xcframework` +
  ghostty/terminfo resources cached). All mac jobs run on `macos-26`
  (Apple Silicon). CI does **not** run XCUITests, so there is no existing
  app-launch test to extend for an Intel check — a new lightweight step is
  needed.
- Outward-facing "Apple Silicon (arm64) only" copy also appears in
  `README.md`, `site/index.html`, `site/docs.html`, `site/llms.txt` — all
  keep-in-sync surfaces per repo convention. `CHANGELOG.md` is release-only
  and must NOT be touched here. Comment-only "Apple Silicon" mentions in
  `agterm/CLIInstaller.swift` and
  `agtermCore/Sources/agtermCore/CLIInstall.swift` are unrelated (describe a
  "clean Apple Silicon Mac may lack `/usr/local/bin`" install-path quirk,
  not an arch check) and don't need changes.

## Development Approach
- **Testing approach**: Regular / validation-based. This is build/packaging
  tooling, not host-free logic — no new `agtermCore` unit tests apply. Gates
  are: `swift test` stays green (unaffected, but verify), a normal Debug
  build still works unchanged, and a Release build produces a verifiably
  universal (arm64+x86_64) binary.
- Make small, focused changes; each task should be independently verifiable
  with `lipo -info` / `file` before moving to the next.
- Do not touch CI runner selection — GitHub-hosted `macos-26` runners are
  Apple Silicon only; universal support comes from cross-compilation, not a
  different runner.
- Do not restructure `scripts/release.sh`'s sign/notarize/staple flow — it
  already operates arch-agnostically on whatever `xcodebuild` produces; only
  the release-notes copy (and optionally an added verification step) change.

## Testing Strategy
- **swift test**: `cd agtermCore && swift test` must stay green (no core
  changes expected).
- **libghostty universal verification**: after flipping `setup.sh`, rebuild
  and run `lipo -info` (or `xcrun xcframework`/`file`) against the macOS
  slice inside `GhosttyKit.xcframework` to confirm both `arm64` and
  `x86_64` are present.
- **Local universal app build**: after the `project.yml` `ARCHS` change,
  regenerate (`xcodegen generate`) and do a Release build
  (`scripts/build.sh`); confirm with `lipo -info` on both the built
  `agterm` executable and the bundled `agtermctl` that both slices are
  present. Also do a plain Debug build (`scripts/run.sh`) to confirm normal
  day-to-day iteration is unaffected (Debug stays active-arch-only via
  `ONLY_ACTIVE_ARCH: YES`).
- **CI cross-build**: push/PR the change and confirm the `build` job (on
  `macos-26`) still succeeds building both architectures in one job, and
  that the new Rosetta smoke-check step passes (`agtermctl` launches
  correctly when forced to `x86_64` via `arch -x86_64`).
- **Release dry-run**: run `scripts/release.sh <version>` (no `--publish`)
  locally; confirm the signed app + DMG both still notarize `Accepted` and
  pass `spctl`, and (if added) that the `lipo -info` guardrail step reports
  both architectures before notarizing.
- **Manual Intel acceptance (Post-Completion, user-owned)**: install the
  built DMG on a physical Intel Mac; confirm launch, basic terminal
  functionality, and `brew install --cask` work end-to-end.

## What Goes Where
- **Implementation Steps** (`[ ]`): `scripts/setup.sh`, `project.yml`,
  `.github/workflows/ci.yml`, `scripts/release.sh`, `packaging/agterm.rb`,
  `README.md`, `site/index.html`, `site/docs.html`, `site/llms.txt` — all in
  this repo.
- **Post-Completion** (no checkboxes): manual acceptance testing on the
  user's physical Intel Mac; publishing the real release
  (`scripts/release.sh <ver> --publish`); any follow-up update to
  `.claude/rules/ci.md` / `.claude/rules/release.md` prose once the actual
  mechanics land (kept out of the implementation steps since those rule
  files describe behavior rather than define it).

## Implementation Steps

### Task 1: Build a universal GhosttyKit.xcframework
**Files:**
- Modify: `scripts/setup.sh`

- [ ] Change the zig build invocation's `-Dxcframework-target=native` to
      `-Dxcframework-target=universal` (or drop the flag entirely, since
      `universal` is zig's own default per `Config.zig`).
- [ ] Update the comment above `GHOSTTY_REV`/the build line that currently
      implies a host-arch-only build, to describe the universal
      (arm64+x86_64 macOS slice + iOS/iOS-sim slices) shape of the resulting
      xcframework.
- [ ] Rebuild once (`rm -rf GhosttyKit.xcframework agterm/Resources/ghostty
      agterm/Resources/terminfo && scripts/setup.sh`) and verify with
      `lipo -info` (or equivalent) that the macOS library slice inside
      `GhosttyKit.xcframework` contains both `arm64` and `x86_64`.

### Task 2: Build both architectures at the Xcode project level
**Files:**
- Modify: `project.yml`

- [ ] Change `ARCHS: arm64` (base settings) to build both architectures
      (e.g. `ARCHS: arm64 x86_64` or `$(ARCHS_STANDARD)`).
- [ ] Leave `Debug.ONLY_ACTIVE_ARCH: YES` / `Release.ONLY_ACTIVE_ARCH: NO`
      unchanged (Debug still builds only the host machine's active arch for
      fast iteration; Release builds both).
- [ ] Regenerate the Xcode project (`xcodegen generate`), do a local Release
      build (`scripts/build.sh`), and confirm via `lipo -info` on both the
      built `agterm` executable (note: Debug code lives in
      `agterm.debug.dylib`, but Release is a single Mach-O) and the bundled
      `agtermctl` that both `arm64` and `x86_64` slices are present.
- [ ] Do a plain Debug build (`scripts/run.sh`) to confirm normal
      day-to-day dev iteration still works unchanged.

### Task 3: CI cross-build + Rosetta smoke check
**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] No runner change needed — `build` job stays on `macos-26`;
      `scripts/build.sh` will cross-build both architectures in the same
      job once Tasks 1–2 land.
- [ ] Add a step after the app build: install Rosetta
      (`softwareupdate --install-rosetta --agree-to-license`), then
      force-run the built `agtermctl` CLI helper under x86_64
      (`arch -x86_64 build/DerivedData/Build/Products/Release/agterm.app/Contents/MacOS/agtermctl <a safe read-only subcommand>`)
      as the only automated Intel signal available (CI has no real Intel
      hardware and does not run XCUITests).
- [ ] Confirm the `ghosttykit-*` `actions/cache` key
      (`hashFiles('scripts/setup.sh')`) still invalidates correctly given
      the Task 1 edit changes the cached artifact's shape (it will, since
      the key hashes the whole script file).

### Task 4: Update the release script for a universal binary
**Files:**
- Modify: `scripts/release.sh`

- [ ] Update `release_notes()`'s install-note copy from *"Apple Silicon
      (arm64) only, macOS 14 or later."* to reflect universal support (e.g.
      *"Universal binary — runs natively on both Apple Silicon and Intel
      Macs, macOS 14 or later."*).
- [ ] Optionally add a `lipo -info` (or `file`) assertion on the signed app
      binary before notarizing, as a release-time guardrail that both
      architecture slices made it into the shipped artifact — fail loudly
      if either is missing.
- [ ] No changes needed to the sign/notarize/staple logic itself — it
      already operates arch-agnostically on whatever `xcodebuild` produced.
- [ ] Run a dry-run (`scripts/release.sh <version>`, no `--publish`) to
      confirm the app + DMG still sign, notarize `Accepted`, staple, and
      pass `spctl`.

### Task 5: Drop the arm64-only Homebrew cask restriction
**Files:**
- Modify: `packaging/agterm.rb`

- [ ] Remove the `depends_on arch: :arm64` line — single universal
      cask/DMG installs on both architectures (per user's choice; no
      separate arch-specific cask).
- [ ] No other cask changes needed (`version`/`sha256`/`url` are still
      rewritten by `scripts/release.sh` at release time).

### Task 6: Sync docs and marketing copy
**Files:**
- Modify: `README.md`, `site/index.html`, `site/docs.html`,
  `site/llms.txt`

- [ ] `README.md`: update the "Pre-built releases are for **Apple Silicon
      (arm64) Macs**..." line to describe universal (Apple Silicon + Intel)
      support.
- [ ] `site/index.html`: update the features-grid line, the two FAQ
      JSON-LD entries, and the hero/signed-notarized line that currently
      say "Apple Silicon" / "Apple Silicon (arm64)".
- [ ] `site/docs.html`: update the "signed and notarized for Apple Silicon
      (arm64) Macs" paragraph.
- [ ] `site/llms.txt`: update the Homebrew install line's "(Apple Silicon,
      macOS 14+, ...)" parenthetical.
- [ ] Do **not** touch `CHANGELOG.md` (release-only per repo convention —
      the universal-binary note goes in at actual release time) or the
      comment-only "Apple Silicon" mentions in `agterm/CLIInstaller.swift` /
      `agtermCore/Sources/agtermCore/CLIInstall.swift` (unrelated
      install-path comments, not arch checks).
- [ ] Move this plan to `docs/plans/completed/` once done (repo convention
      for completed plans).

## Post-Completion
*Manual / external — no checkboxes*
- Manual acceptance testing on the user's physical Intel Mac: install the
  built DMG (or `brew install --cask`), confirm launch, basic terminal use,
  and general responsiveness before cutting a real published release.
- Cut the first universal release via `scripts/release.sh <ver> --publish`
  once acceptance testing passes.
- Follow-up: update `.claude/rules/ci.md` and `.claude/rules/release.md`
  prose to reflect the new cross-build/Rosetta-smoke-check mechanics once
  they land (these rule files document behavior; kept out of the
  implementation steps above since editing them isn't itself required for
  the feature to work).
