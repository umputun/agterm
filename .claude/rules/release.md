---
paths:
  - "scripts/release.sh"
---

## Release (`scripts/release.sh`)

- **Releases are local; there is no `release.yml`.** Run `scripts/release.sh <version> --publish` on the
  maintainer's Mac, which holds the `Developer ID Application: Brave Elk LLC` certificate and
  `agterm-notary` keychain profile. The script builds Release, signs/notarizes/staples the app and DMG,
  creates the tag and GitHub release, uploads the DMG, then pushes the Homebrew cask to
  `umputun/homebrew-apps` using the maintainer's `gh` auth. It needs no `HOMEBREW_TAP_PAT`. The DMG
  container must be codesigned before notarization or `spctl` rejects `hdiutil`'s unsigned image.
  Without `--publish`, the full build/sign/notarize/staple/`spctl` dry-run stops before upload.
- Developer ID signing is inside-out: `agtermctl` and zmx are signed first with no entitlements, then the
  app is sealed with its TCC entitlements. The script rejects either helper if app entitlements leak into it.
- Before writing or committing a release section, put the exact `CHANGELOG.md` text in a temp file and
  pass it through the `draft-approval` skill's `draft-review.sh`; address annotations and get explicit
  chat approval. `release.sh:70-85` publishes that text as the GitHub release body.
- **Commit and push the changelog and website version to `master` before `release.sh --publish`.**
  `gh release create "$TAG"` has no `--target` (`release.sh:166`), so it tags `origin/master`, not local
  `HEAD`. The script pushes only its cloned Homebrew tap; the maintainer must push the main repo.
- Manually set `site/index.html`'s `SoftwareApplication.softwareVersion` in that same pre-release push;
  `release.sh` does not edit it. Cloudflare Pages deploys `site/` on push, and the DMG links already use
  GitHub's latest release.
