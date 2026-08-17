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

Before the next release, launch the notarized build by hand once and exercise: first surface render, a
font-size or theme change forcing a pipeline rebuild, window translucency (the `dlopen(nil)`/`dlsym` path
in `agterm/Views/WindowAppearance.swift`), a session spawning and driving heavy scrollback, and
`agtermctl` from inside a session. First render loads the metallib compiled into libghostty at build time
and embedded in the binary, reached through `newLibraryWithData:`; only an optional custom shader
compiles from source at runtime via `newLibraryWithSource:`, and that produces GPU code rather than
CPU-executable pages. So a custom shader is worth including in the pass, but neither path is a reason to
keep an executable-memory exception.

Worth making a standing release step rather than a one-off, since no automated gate can replace it. The
boundary that matters: a PR merges on its own CI, but publication should stop until the signed artifact
has started and been exercised. Static analysis decides which entitlements belong in the signature; it
says nothing about whether the signed artifact runs, and the production path changes the signing identity
and then notarizes and publishes without ever launching. Whether that becomes a blocking step in
`scripts/release.sh` is a call for the maintainer, not something to add on the way past.

Surfaced by issue #448 and the entitlements split that answered it.
