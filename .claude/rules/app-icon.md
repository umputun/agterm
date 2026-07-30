---
paths:
  - "agterm/AppIcon.icon/**"
  - "project.yml"
---

## App icon

- `agterm/AppIcon.icon` is a layered macOS 26 Icon Composer document with live Liquid Glass and
  light/dark/clear/tinted appearances. `ASSETCATALOG_COMPILER_APPICON_NAME` and the actool-written
  `CFBundleIconName` are `AppIcon`. actool emits adaptive data in `Assets.car` plus `AppIcon.icns` for
  macOS < 26; do not add a hand-made `.appiconset` or `.icns`.
- **Keep the `.icon` as a direct target file at `agterm/AppIcon.icon`, outside `Assets.xcassets`.**
  Xcode types it `wrapper.icon` and passes it directly to actool. Inside a catalog it is an opaque folder,
  and actool silently emits no `Assets.car`. Replace it with an Icon Composer export and run `xattr -cr`
  first because exports carry quarantine/provenance.
- Content replacements rebuild incrementally. After adding, removing, or switching catalog structure,
  run `make clean`: xcodebuild can otherwise report success while skipping actool and retaining a stale
  `Assets.car`. Confirm that `Contents/Resources/AppIcon.icns` has a new mtime.
- xcodegen also copies a redundant loose `AppIcon.icon`. The `Bundle agtermctl CLI` post-build script
  removes it before resealing because it can override the compiled icon with a placeholder grid and its
  xattrs can fail `codesign --deep`.
- **Never set `NSApp.applicationIconImage`.** It freezes the Dock to a static, flat `NSImage` and defeats
  adaptive rendering. LaunchServices must render the bundle icon.
- DerivedData reuses the bundle path, so Icon Services may show a stale Dock/Finder tile for a dev build.
  Verify by reading `Contents/Resources/AppIcon.icns`, or copy the app to a fresh path and run
  `lsregister -f`. A fresh installed path does not have this cache artifact.
