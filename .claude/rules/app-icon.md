---
paths:
  - "agterm/AppIcon.icon/**"
  - "project.yml"
---

## App icon

- The icon is an **adaptive Icon Composer document** at `agterm/AppIcon.icon` (macOS 26 `.icon` format
  — layered, with Liquid Glass + light/dark/clear/tinted appearances the system renders LIVE).
  `ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon`; `CFBundleIconName` ends up `AppIcon` (actool writes
  it). actool compiles the `.icon` into `Assets.car` (the adaptive data) plus a legacy `AppIcon.icns`
  fallback for macOS < 26 — no hand-made `.appiconset`/`.icns` needed.
- **The `.icon` MUST be a target FILE, NOT nested inside `Assets.xcassets` (load-bearing).** actool only
  compiles a `.icon` passed as a DIRECT input; a `.icon` dropped inside an `.xcassets` is treated as
  an opaque folder and actool **silently emits nothing** (no error, no `Assets.car` — the app ends up
  icon-less).
  So `AppIcon.icon` lives at the top of the `agterm/` source dir (Xcode types it `wrapper.icon` and routes
  it to actool alongside the catalog: `actool …/AppIcon.icon …/Assets.xcassets --compile …`).
  To swap the design, replace `agterm/AppIcon.icon` (re-export from Icon Composer;
  `xattr -cr` it first — the source carries quarantine/provenance).
  A CONTENT swap recompiles on an incremental `make build`; but a STRUCTURAL asset-catalog change (adding/removing
  the icon, or the appiconset↔`.icon` swap) can make xcodebuild SKIP actool entirely — a "BUILD SUCCEEDED"
  with a STALE `Assets.car` and no new icon.
  Force it with `make clean` and confirm `Contents/Resources/AppIcon.icns`'s mtime actually updated.
- **xcodegen also lists the `.icon` in Copy Bundle Resources**, dropping a redundant LOOSE `AppIcon.icon`
  in the bundle.
  The `Bundle agtermctl CLI` postBuildScript `rm -rf`s it before the re-seal:
  a loose source `.icon` renders as the generic Icon-Composer **placeholder grid** (so it must not win
  over the compiled icon), and its source xattrs would trip `codesign --deep`.
- **Do NOT set `NSApp.applicationIconImage`.**
  `applicationIconImage` takes a STATIC `NSImage`, so setting it (even from the compiled asset) FREEZES
  the Dock to one flat rendering and defeats the adaptive icon — the symptom is a flat,
  non-glass, non-tinted Dock tile.
  The shipped app lets LaunchServices render the bundle `.icon` live.
  (An earlier `applicationWillFinishLaunching` override that set it for the ad-hoc Debug Dock tile was
  removed for exactly this reason.)
- **Debug builds from DerivedData may show a STALE Dock/Finder tile.**
  Icon Services caches by bundle PATH and the DerivedData path is reused across rebuilds,
  so a rebuilt dev app can show the prior (or placeholder) icon — NOT a bug.
  The deployed app (fresh install path) renders correctly.
  To verify a dev build's icon, copy the `.app` to a fresh path + `lsregister -f` it (or read `Contents/Resources/AppIcon.icns`
  directly).
