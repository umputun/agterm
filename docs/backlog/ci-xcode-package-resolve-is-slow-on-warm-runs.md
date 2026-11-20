---
worth: maybe
where: .github/workflows/ci.yml
added: 2026-11-19
---
# xcodebuild resolves the package graph slowly even with every cache hit

Run 44679248666 (`76a7d005`, PR #1063): hosted shard 2 spent 47 s between `Resolve Package Graph` and
`Resolved source packages`, against a few seconds on shard 3, with the compilation, helper and package
checkout caches all restored. Its build step took 186 s against about 80 s on the other warm runs, so the
resolve explains part of that jump, not all of it. The log shows no fetching or updating lines, so remote
access during the resolve is not established.

- Measure `-skipPackageUpdates` alone on the CI xcodebuild calls (hosted `build-for-testing` and Build
  app's `scripts/build.sh` arguments), on matched warm inputs.
- Confirm a run with a cold `build/DerivedData/SourcePackages` still resolves the same package graph.
- Leave `-disableAutomaticPackageResolution` out: the generated workspace has no tracked
  `Package.resolved`, so that flag changes the dependency policy and risks a cold-build failure.
