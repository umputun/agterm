---
paths:
  - "scripts/release.sh"
  - "packaging/agterm.rb"
---

## Release (`scripts/release.sh`)

- **Releases are local; there is no `release.yml`.** Run `scripts/release.sh <version> --publish` on the
  maintainer's Mac, which holds the `Developer ID Application: Brave Elk LLC` certificate and
  `agterm-notary` keychain profile. The script builds Release, signs/notarizes/staples the app and DMG,
  creates the tag and GitHub release, uploads the DMG, then pushes the Homebrew cask to
  `umputun/homebrew-apps` using the maintainer's `gh` auth. It needs no `HOMEBREW_TAP_PAT`. The DMG
  container must be codesigned before notarization or `spctl` rejects `hdiutil`'s unsigned image.
  Without `--publish`, the full build/sign/notarize/staple/`spctl` dry-run stops before upload.
- Each release also ships agterm-server: `release.sh` needs Docker running, runs `scripts/setup-zmx-linux.sh`, and
  packages `agterm-server-VERSION-linux-{aarch64,x86_64}.tar.gz` with `scripts/server-package.sh` before the Xcode
  build. Their sha256 lines go into the app as `Contents/Resources/agterm-server.sha256` before the re-seal (an
  ad-hoc re-seal on the unsigned path), and `--publish` uploads the DMG and both tarballs in one
  `gh release upload --clobber`. `agtermctl server install` trusts only that bundled file, so a tarball rebuilt after
  the app was sealed no longer installs.
- `release.sh` copies `packaging/agterm.rb` into the tap only when the tap has no cask, then rewrites
  just `version` and `sha256`. Any other cask edit is made by hand in `umputun/homebrew-apps` too, and the
  two files must stay identical apart from those two lines.
- Developer ID signing is inside-out: `agtermctl`, zmx and `agterm-session-host` are signed first with no
  entitlements, then Sparkle's XPC services, `Autoupdate`, `Updater.app` and the framework, then the app is sealed
  with its TCC entitlements from `agterm.entitlements`. The script rejects any helper carrying them and an app carrying
  a `com.apple.security.cs.` exception.
- Sparkle: `release.sh` builds with `AGTERM_UPDATE_FEED` set to the `releases/latest/download/appcast.xml` URL, the only
  build that gets an updater. After the DMG staple, `sign_update --account agterm` signs the DMG and the script writes
  `build/appcast.xml` with the version, `sparkle:minimumSystemVersion`, the CHANGELOG section as Markdown and the
  signed enclosure, uploaded in a second `gh release upload` once the DMG and tarballs are up. The EdDSA private key is in the login
  keychain under the `agterm` account, with an exported backup; losing it leaves existing installs unable to verify
  any later update. `sign_update` may ask for keychain access on its first use.
- `packaging/agterm.rb` declares `auto_updates true`: Sparkle updates a brew copy in place, and `brew upgrade` acts
  only when the installed bundle's version is older than the tap's, then installs the same notarized DMG.
- Before writing or committing a release section, put the exact `CHANGELOG.md` text in a temp file and
  pass it through the `draft-approval` skill's `draft-review.sh`; address annotations and get explicit
  chat approval. `release.sh:70-85` publishes that text as the GitHub release body.
- **Release only a `master` SHA whose CI `Build app` job passed.** Ordinary same-repo owner PRs skip it, so the
  master push run is the first run of its checks. `release.sh` rebuilds Release and checks the Developer ID signing,
  but only `Build app` runs the surface teardown test and the exact ad-hoc entitlement and plist parity checks. The
  pre-release push below runs it, since its plugin-manifest bump is in the Swift filter; a run with `Build app`
  skipped does not count.
- **Commit and push the changelog and website version to `master` before `release.sh --publish`.**
  `gh release create "$TAG"` has no `--target` (`release.sh:166`), so it tags `origin/master`, not local
  `HEAD`. The script pushes only its cloned Homebrew tap; the maintainer must push the main repo.
- Manually set `site/index.html`'s `SoftwareApplication.softwareVersion` in that same pre-release push;
  `release.sh` does not edit it. Cloudflare Pages deploys `site/` on push, and the DMG links already use
  GitHub's latest release.
- Bump `version` in `.claude-plugin/marketplace.json` and both `plugins/agterm/{.claude,.codex}-plugin/plugin.json`
  in that same commit.
  Otherwise `release.sh` bumps them itself and exits before building, asking for a commit and a re-run.
