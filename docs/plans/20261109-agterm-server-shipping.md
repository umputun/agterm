# agterm-server shipping: release tarballs and `agtermctl server install`

## Overview
- Installing agterm-server today needs a repo checkout, Docker and zig on the Mac
  (`scripts/setup-zmx-linux.sh`, then `scripts/install-server.sh HOST`). That is a developer path, not a product one.
- Each Mac release ships static Linux tarballs, one per architecture, as GitHub release assets. The app carries
  their sha256, and `agtermctl server install [-p port] [-i identity] [-J jump] [-F config] HOST` installs or upgrades
  the server on HOST. No checkout, Docker or zig is needed on the Mac. The host needs what the installer already
  needs: ssh, bash, tar, and systemd with a user manager and logind (for linger).
- The tarball carries its own host-side installer, so the developer script and the release CLI run the same steps:
  layout under `~/.local/lib/agterm-server` swapped in by rename, the systemd user unit written only when absent,
  linger, start or restart, the running server's answer, `install-hooks`, and the PATH note.
- Part of the `linux-remote-server` branch and PR; it extends `20261106-linux-remote-server.md`.

## Context (from discovery)
- `scripts/install-server.sh`: probes `uname -m`, builds with `scripts/server-build.sh ARCH` (static musl in
  `swift:6.3.2-noble`), stages binaries, zmx, shell integration, terminfo, agent-status and the skill, streams a
  tar over ssh into `$lib.new` and renames it in, then runs a host-side bash heredoc for unit, linger, restart,
  the `version` probe through the running server's own environment, and `install-hooks`; a separate ssh connection
  prints the PATH note.
- `scripts/release.sh`: local and manual; calls `scripts/setup.sh`, bumps the plugin manifests and exits when they
  differ from HEAD, builds Release with `xcodebuild`, re-signs inside-out with Developer ID or takes the `SIGNED=0`
  branch, notarizes, builds the DMG, and `--publish` creates or edits the release, then `gh release upload --clobber`.
- `scripts/setup-zmx-linux.sh` stages zmx per architecture and the ghostty integration under `build/linux`, and is
  a no-op while its stamps are current.
- `TerminfoInstall` (agtermCore) plus `TerminfoCommands` (agtermctlKit) is the precedent: a CLI-only command running
  `ssh` locally, argv in core, the `-p -i -J -F` option set in `Connection`, destination validation, forced execution
  options, and a `posix_spawnp` runner that keeps ssh in the caller's foreground process group.
- `ServerVersion.current` is the literal `0.0.0`; `ServerCommand`'s `CommandConfiguration` has no `version:`.
- Surfaces stating the checkout install: `site/docs.html`, `site/llms.txt:15`, `ARCHITECTURE.md:47`, `README.md:21`.

## Decisions carried from the parent plan
| Decision (20261106-linux-remote-server.md) | Status | Note |
|---|---|---|
| executable name `agterm-server` | kept | tarball and asset names use it |
| whether the server ships with the Mac release or separately | changed: with the Mac release | same version, same `gh release`, checksums in the app |
| install layout, unit-once, linger refusal stops the install, hooks at the end | kept | moved into the tarball's `install.sh` unchanged |
| a running server keeps its open binary across an upgrade | kept | rename swap unchanged |

## Development Approach
- **testing approach**: Regular, with tests in the same task as the code they cover
- complete each task fully before moving to the next; all tests pass before the next task starts
- every task includes new or updated tests for its code changes, success and error paths
- update this plan when scope changes during implementation

## Testing Strategy
- **unit tests**: `cd agtermCore && swift test` for the core model, the spawn runner and the CLI, with the download,
  ssh and digest effects injected where a test cannot reach them.
- **shell**: `shellcheck` on every touched script.
- **container**: `scripts/server-container.sh check` installs through `scripts/install-server.sh`, which now packages a
  tarball and runs its `install.sh`, so the shared host path meets a real sshd and its fish login shell.
- **Linux**: the agtermCore, AgtermServerKit and agtermctlKit suites build and pass in the Linux container.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview
- `scripts/server-build.sh ARCH [VERSION]` stamps VERSION (default `0.0.0`) into `ServerVersion.current` in its
  throwaway source tree and, inside its container step, checks `agterm-server --version` prints it.
- `scripts/server-package.sh ARCH VERSION` builds via `server-build.sh`, stages the tree `install-server.sh` stages
  today plus `install.sh`, and writes `build/server/agterm-server-VERSION-linux-ARCH.tar.gz` and its `.sha256`.
- `scripts/server-host-install.sh` is today's remote heredoc as a file plus the PATH note. It ships in the tarball as
  `install.sh` and runs on the host from the swapped-in directory.
- `scripts/install-server.sh HOST` (developer path) packages for the host's arch as `0.0.0`, streams the tarball
  through the rename unpack, and runs `install.sh`. Behavior and exit codes unchanged.
- `scripts/release.sh VERSION` calls `scripts/setup-zmx-linux.sh`, packages both architectures before the Xcode build,
  writes `agterm-server.sha256` into the built app's `Contents/Resources`, re-seals on both branches (Developer ID,
  or ad-hoc on `SIGNED=0`, since writing into the bundle breaks xcodebuild's seal), and `--publish` uploads the DMG
  and both tarballs in one `gh release upload --clobber` after the create-or-edit.
- `agtermctl server install [-p port] [-i identity] [-J jump] [-F config] HOST` (macOS only):
  1. resolves its app bundle (as `version` does) and reads the version through `AppIdentity.installed(bundleURL:)` and
     `Contents/Resources/agterm-server.sha256`; a build without that file (a dev build, or a CLI copied out of the
     app) is refused, naming `scripts/install-server.sh`;
  2. runs `ssh … HOST uname -m` and refuses anything but aarch64 and x86_64;
  3. downloads `https://github.com/umputun/agterm/releases/download/vVERSION/agterm-server-VERSION-linux-ARCH.tar.gz`
     to a private temp file under a size cap, and refuses it unless its sha256 matches the app's line for that asset;
  4. streams the verified file into the rename unpack over ssh, then runs `install.sh` there.
  Exit codes: 0 installed, 3 installed with incomplete hooks, 1 for any refusal or failure with the reason on stderr.
- The command is CLI-only, like `terminfo install` and `clipboard set`: it opens no socket, runs `ssh` locally and has
  nothing for the app to dispatch or read back.

## Technical Details
- Asset name: `agterm-server-<version>-linux-<arch>.tar.gz`, arch exactly `aarch64` or `x86_64`. Entries at the archive
  root, written with `COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata`, as `install-server.sh` writes them today.
- Checksum file: UTF-8 lines `<64 hex>  <asset name>`; a missing, malformed or duplicate entry for the asset is an
  error, never a skip. The release script writes it into the bundle before the app is sealed and notarized, so the
  values a user runs against are the ones the release built; the CLI itself only reads them.
- Download: HTTPS only (redirects too), fixed host and path template, cap 256 MB, written to a `0600` temp file
  removed on every exit path. No retry inside the command.
- ssh: argv built in core (`ServerInstall`), never a shell string. It reuses `TerminfoInstall.Connection` (`-p -i -J -F`)
  with its destination validation (`RemoteSession.isPlain`, no leading `-`) and `TerminfoInstall.executionOptions`
  (`-T`, `StdinNull=no`, `SessionType=default`, `ForkAfterAuthentication=no`, `RemoteCommand=none`), which as
  command-line options win over any config file. No `BatchMode`: run by hand, a host-key or password prompt is
  answered at the terminal, as with `terminfo install`.
- Spawning: every ssh phase (probe, unpack, installer) runs through `TerminfoInstall`'s `posix_spawnp` path, hoisted
  into one shared core helper: stdin from a file or data, stdout captured for the arch probe, terminal stderr
  inherited, and ssh kept in the caller's foreground process group. Foundation's `Process` puts the child in a
  background group, where a prompt read from `/dev/tty` stops it with SIGTTIN. Darwin-only, as today.
- Host unpack: today's rename script joined into one line, since the account's login shell parses the quoted command
  and tcsh rejects a quoted newline; `install-server.sh` and the CLI send the same string.
- Host installer: the literal remote command `bash "$HOME/.local/lib/agterm-server/install.sh"`, the same from both
  paths and pinned in the argv tests.
- Order: nothing is streamed to the host until the downloaded file's sha256 matched; a test pins that a mismatch never
  starts the unpack.

## What Goes Where
- **Implementation Steps**: scripts, core model, CLI command, docs and skill, tests.
- **Post-Completion**: the first real release that publishes the tarballs, and an install from it on a real host.

## Implementation Steps

### Task 1: Packaging and release

**Files:**
- Create: `scripts/server-package.sh`, `scripts/server-host-install.sh`
- Modify: `scripts/install-server.sh`, `scripts/server-build.sh`, `scripts/release.sh`, `.claude/rules/release.md`
- Modify: `agtermCore/Sources/agterm-server/main.swift`, `agtermCore/Sources/AgtermServerKit/ServerVersion.swift` (doc)

- [x] `agterm-server --version` (`CommandConfiguration(version: ServerVersion.current)`); `server-build.sh ARCH [VERSION]`
      stamps VERSION in its throwaway tree (grep-verified before the build) and runs the built `--version` when the
      arch is Docker's native one; ⚠️ this Docker Desktop has no amd64 emulation (`exec format error`), so x86_64
      relies on the source stamp, and Eugene chose that over enabling emulation; the x86_64 binary is first run by
      the Post-Completion install on a real x86_64 host
- [x] `server-host-install.sh` is the remote heredoc plus the PATH note; `server-package.sh ARCH VERSION` writes the
      tarball (root entries, no xattrs) with it as `install.sh`, and its `.sha256`
- [x] `install-server.sh` packages for the host arch, streams through the one-line unpack, runs
      `bash "$HOME/.local/lib/agterm-server/install.sh"`, keeps its exit codes
- [x] `release.sh` checks Docker, calls `setup-zmx-linux.sh`, packages both arches before `xcodebuild`, writes
      `agterm-server.sha256` into the app before the re-seal (Developer ID, or ad-hoc on `SIGNED=0`), and uploads the
      DMG and tarballs in one `gh release upload --clobber`; `release.md` documents it
- [x] shellcheck every touched script; `server-container.sh start` and `check` pass on a fresh container

### Task 2: `agtermctl server install`

**Files:**
- Create: `agtermCore/Sources/agtermCore/ForegroundSpawn.swift`, `agtermCore/Sources/agtermCore/ServerInstall.swift`,
  `agtermCore/Sources/agtermctlKit/ServerCommands.swift`
- Create: `ForegroundSpawnTests.swift`, `ServerInstallTests.swift` (agtermCoreTests), `ServerCommandsTests.swift`
  (agtermctlKitTests)
- Modify: `agtermCore/Sources/agtermCore/TerminfoInstall.swift`, `agtermCore/Sources/agtermctlKit/Commands.swift`

- [x] hoist terminfo's `posix_spawnp` runner into `ForegroundSpawn` (stdin from data or file, stdout captured on
      request, inherited stderr, Darwin-only); `terminfo install` behavior and tests unchanged
- [x] `ServerInstall`: asset name and URL, arch check, checksum-line parsing, ssh argv from `TerminfoInstall.Connection`
      and its execution options with the remote strings equal to `install-server.sh`'s, exit mapping 0/3/1
- [x] `server install [-p -i -J -F] HOST` (macOS only): bundle version and checksum file, arch probe, download under
      the cap, sha256 check before anything reaches the host, unpack, installer; refusals for no checksum file, bad
      destination, unsupported arch, mismatch, oversize, ssh failure; temp file always removed
- [x] tests: the core rules, the runner, injected-effect CLI runs (success, each refusal, exit 3, mismatch never
      unpacks), and the tty check (`script` + a fake `ssh` that prints `riscv64` only after reading the answer from
      `/dev/tty`, ending at the arch refusal)
- [x] the new and affected tests pass on macOS and in the Linux container
- [x] ➕ `--from FILE` installs a tarball on the Mac instead of downloading (Eugene, after weighing the download
      against bundling 54-56 MB tarballs into a 23 MB DMG): read through `BoundedFile` into a private 0600 file that
      alone is hashed and streamed, same checksum line; tests pin the symlink snapshot, mismatch, oversize, unreadable
      ⚠️ staging-bundle acceptance, separate from the signed release-bundle checks: the signed 0.41.1 build's
      `Info.plist` and `agterm-server.sha256` with a freshly built CLI ran `--from` against the Ubuntu 20.04 x86_64 VM,
      exit 0, and the active service then reported 0.41.1; a published-download success stays Post-Completion

### Task 3: Docs and final checks

**Files:**
- Modify: `site/docs.html`, `site/commands.html`, `site/llms.txt`, `README.md`, `ARCHITECTURE.md`,
  `.claude/rules/control-api.md`, `plugins/agterm/skills/agterm/SKILL.md`, `reference.md`

- [x] docs, llms.txt, README and ARCHITECTURE lead with `agtermctl server install HOST`, the checkout path kept as the
      developer route; commands.html documents the command as CLI-only; control-api.md counts three exemptions; the
      skill points to it
- [x] partial release dry run on the finished tree (no `--publish`, 0.41.1): both tarballs built, and the Developer
      ID-signed bundle's `agtermctl server install --help` works and its checksum file matches the two tarballs
      ⚠️ an identity is in the keychain, so it ran the Developer ID branch: checksum file written before the re-seal,
      `codesign --verify --deep --strict` passes, `shasum -c` matches both tarballs, and the bundled CLI refused the
      published v0.41.1's 404 against an x86_64 host with exit 1 (the failure path; a successful released-tarball
      install stays Post-Completion). Notarization failed with exit 69, as this Mac has no `agterm-notary` profile, so
      staple, spctl and the DMG steps were not reached and the new `SIGNED=0` ad-hoc re-seal branch was not exercised;
      Eugene accepted this run as the dry run, notarize, staple and spctl being unchanged here
- [ ] full gates once: `make build`, `swift test`, `make test-app`, `make lint`, the Linux suite, the container check
- [ ] move this plan to `docs/plans/completed/`; the parent plan moves too only once its own open items (Mac-origin
      attach parity, the final UI-test gate) are done or Eugene waives them

## Post-Completion
- the first published release carrying the tarballs, and `agtermctl server install` from that app against a real
  Linux host of each architecture
- the agterm-linux fork: tell its maintainer about the new release assets if it wants to reuse them

Smells pre-check: skipped — non-Go project
