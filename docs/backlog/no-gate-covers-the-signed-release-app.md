---
worth: next release
where: .github/workflows/ci.yml, scripts/release.sh
added: 2026-08-17
---
# nothing exercises a Developer ID signed Release app before it ships

CI builds Release, but signs it with the ad-hoc "Sign to Run Locally" identity and never launches it.
The hardened-runtime entitlements only take effect under a real Developer ID signature, so every gate the
project has is blind to whether the shipped app starts. `scripts/release.sh` is the sole place that signs,
notarizes and staples, and it runs on the maintainer's Mac with no launch step of its own.

This did not matter while the entitlements file had carried the same keys since the first commit. It does
now: the Release set dropped `allow-jit`, `allow-unsigned-executable-memory` and
`disable-library-validation`, and the static evidence that Release needs none of them is strong but not a
measurement. A missing hardened-runtime exception fails at dyld or on the exec page, so the failure is
loud, but it lands on users rather than on CI.

Before the next release, launch the notarized build by hand once and exercise: first surface render
(libghostty compiles its Metal shaders at runtime), a font-size or theme change forcing a pipeline
rebuild, window translucency (the `dlopen(nil)`/`dlsym` path in `agterm/Views/WindowAppearance.swift`), a
session spawning and driving heavy scrollback, and `agtermctl` from inside a session.

Worth considering as a standing release step rather than a one-off, since no automated gate can replace
it. Surfaced by issue #448 and the entitlements split that answered it.
