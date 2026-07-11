#!/usr/bin/env bash
# Build, sign, notarize, and package a release DMG locally, and (with --publish)
# upload it to a GitHub release and bump the Homebrew cask.
#
# Usage:
#   scripts/release.sh <version>            # build + sign + notarize + DMG (no publish)
#   scripts/release.sh <version> --publish  # also: gh release + cask bump/push
#
# Signing identity: auto-detected from the keychain ("Developer ID Application"),
# or override with AGTERM_SIGN_IDENTITY. With no identity it produces an AD-HOC
# DMG (not notarized) — a dry run by default, but set AGTERM_ALLOW_UNSIGNED=1 to
# --publish it as an unsigned release. Notary creds come from a keychain profile created
# with `xcrun notarytool store-credentials` (default name: agterm-notary,
# override with AGTERM_NOTARY_PROFILE).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/build"

VERSION="${1:-}"
PUBLISH=0
[ "${2:-}" = "--publish" ] && PUBLISH=1

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/release.sh <x.y.z> [--publish]" >&2
  exit 1
fi

TAG="v$VERSION"
DMG="$BUILD_DIR/agterm-$VERSION.dmg"
APP="$BUILD_DIR/DerivedData/Build/Products/Release/agterm.app"
NOTARY_PROFILE="${AGTERM_NOTARY_PROFILE:-agterm-notary}"
TAP_REPO="umputun/homebrew-apps"

# resolve the signing identity: explicit override, else the first Developer ID
# Application identity in the keychain, else ad-hoc dry-run.
SIGN_ID="${AGTERM_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi
if [ -n "$SIGN_ID" ]; then
  SIGNED=1
  echo "==> signing identity: $SIGN_ID"
else
  SIGNED=0
  echo "==> WARNING: no Developer ID Application identity found — building AD-HOC (dry-run, not notarized)"
fi

if [ "$PUBLISH" = "1" ] && [ "$SIGNED" = "0" ] && [ "${AGTERM_ALLOW_UNSIGNED:-0}" != "1" ]; then
  echo "refusing to --publish an ad-hoc (unsigned) build" >&2
  echo "set AGTERM_ALLOW_UNSIGNED=1 to publish the interim unsigned build (CI does this)" >&2
  exit 1
fi

# submit a path to the notary service and wait; fail loudly with the log on reject.
notarize() {
  local path="$1" json status id
  echo "==> notarizing $(basename "$path")"
  json="$(xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  status="$(printf '%s' "$json" | jq -r '.status')"
  id="$(printf '%s' "$json" | jq -r '.id')"
  if [ "$status" != "Accepted" ]; then
    echo "notarization failed: status=$status" >&2
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    exit 1
  fi
}

# build the GitHub release body: the matching CHANGELOG.md section followed by a
# short install note (signed + notarized; universal arm64 + x86_64, macOS 14+).
release_notes() {
  local section
  section="$(awk -v ver="v$VERSION" '
    $0 ~ "^## " ver "( |$)" {grab=1; next}
    grab && /^## / {exit}
    grab {body[++n]=$0}
    END {
      s=1; while (s<=n && body[s] ~ /^[[:space:]]*$/) s++
      while (n>=s && body[n] ~ /^[[:space:]]*$/) n--
      for (i=s; i<=n; i++) print body[i]
    }
  ' "$ROOT/CHANGELOG.md")"
  [ -n "$section" ] || echo "WARNING: no CHANGELOG.md section for v$VERSION — release body will be the install note only" >&2
  [ -n "$section" ] && printf '%s\n\n' "$section"
  cat <<EOF
---

Signed with a Developer ID certificate and notarized by Apple, so macOS Gatekeeper opens it with no extra steps. Universal binary (Apple Silicon + Intel), macOS 14 or later.

- **Homebrew:** \`brew install --cask umputun/apps/agterm\`
- **Direct download:** open the \`.dmg\` and drag \`agterm.app\` into \`/Applications\`.
EOF
}

# ── build ────────────────────────────────────────────────────────────────────
"$ROOT/scripts/setup.sh"
xcodegen generate >/dev/null
# plain Release build (NOT archive). The build is left ad-hoc here on purpose:
# Xcode's own final code-sign runs after the bundle phase and adds no secure
# timestamp, so trying to inject Developer ID at build time is racy. Instead we
# re-sign authoritatively below, AFTER xcodebuild returns.
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
xcodebuild -project agterm.xcodeproj -scheme agterm -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" GIT_COMMIT="$GIT_COMMIT" \
  build
[ -d "$APP" ] || { echo "expected app not found: $APP" >&2; exit 1; }

# authoritative Developer ID signing — AFTER xcodebuild so nothing clobbers it,
# with a secure --timestamp on every Mach-O (notarization requires it). Sign the
# nested helper first (inside-out), then re-sign + seal the app bundle.
if [ "$SIGNED" = "1" ]; then
  echo "==> signing Developer ID (timestamped)"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/agtermctl"
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/agterm/agterm.entitlements" --sign "$SIGN_ID" "$APP"
  codesign --verify --deep --strict "$APP"
fi

# ── notarize + staple the app ─────────────────────────────────────────────────
if [ "$SIGNED" = "1" ]; then
  ZIP="$BUILD_DIR/agterm-$VERSION.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl -a -vv --type execute "$APP"
fi

# ── package the DMG ───────────────────────────────────────────────────────────
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname agterm -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

# ── sign + notarize + staple the DMG ──────────────────────────────────────────
# codesign the DMG container itself (create → sign → notarize → staple), so the
# primary-signature assessment below has a signature to verify. hdiutil produces
# an unsigned image; without this the DMG notarizes+staples but spctl rejects it.
if [ "$SIGNED" = "1" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG"
fi

echo "==> built: $DMG"

if [ "$PUBLISH" != "1" ]; then
  echo "==> dry run complete (pass --publish to upload + bump the cask)"
  exit 0
fi

# ── publish: GitHub release + cask bump ───────────────────────────────────────
echo "==> publishing $TAG"
NOTES_FILE="$(mktemp)"
release_notes >"$NOTES_FILE"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release edit "$TAG" --title "Version $VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" --title "Version $VERSION" --notes-file "$NOTES_FILE"
fi
rm -f "$NOTES_FILE"
gh release upload "$TAG" "$DMG" --clobber

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
TAP_DIR="$(mktemp -d)"
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --depth=1 >/dev/null
CASK="$TAP_DIR/Casks/agterm.rb"
if [ ! -f "$CASK" ]; then
  mkdir -p "$TAP_DIR/Casks"
  cp "$ROOT/packaging/agterm.rb" "$CASK" # first publish: seed from the in-repo source of truth
fi
sed -i '' -E "s/^( *version )\".*\"/\1\"$VERSION\"/" "$CASK"
sed -i '' -E "s/^( *sha256 )\".*\"/\1\"$SHA\"/" "$CASK"
git -C "$TAP_DIR" add Casks/agterm.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
  echo "==> cask already at $VERSION, nothing to push"
else
  git -C "$TAP_DIR" commit -m "agterm $VERSION"
  git -C "$TAP_DIR" push
  echo "==> cask bumped to $VERSION"
fi
rm -rf "$TAP_DIR"
echo "==> done"
