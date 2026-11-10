#!/usr/bin/env bash
# static musl builds of agterm-server and agtermctl from this tree, for an install on any Linux of the architecture.
# usage: scripts/server-build.sh aarch64|x86_64 [VERSION]   -> build/server/ARCH/{agterm-server,agtermctl}
# VERSION (default 0.0.0) is stamped into ServerVersion.current in the build's own copy of the tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_IMAGE=swift:6.3.2-noble
SDK=swift-6.3.2-RELEASE_static-linux-0.1.0
SDK_URL="https://download.swift.org/swift-6.3.2-release/static-sdk/swift-6.3.2-RELEASE/$SDK.artifactbundle.tar.gz"
# swift.org's published checksum for this bundle (api/v1/install/releases.json, 6.3.2, static-sdk)
SDK_SHA256=3fd798bef6f4408f1ea5a6f94ce4d4052830c4326ab85ebc04f983f01b3da407
# runs the built binary for its --version check; a static musl binary needs nothing from the image
CHECK_IMAGE=alpine:3.20

die() { echo "server-build: $*" >&2; exit 2; }

arch="${1:-}"
case "$arch" in
  aarch64 | x86_64) ;;
  *) die "usage: $0 aarch64|x86_64 [VERSION]" ;;
esac
version="${2:-0.0.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be x.y.z, got $version"
out="$ROOT/build/server/$arch"
bundle="$ROOT/build/server/$SDK.artifactbundle.tar.gz"
mkdir -p "$out"

# the swift image has no curl, so the bundle is fetched here and handed in read-only
[[ -s "$bundle" ]] || curl -fsSL -o "$bundle" "$SDK_URL"
[[ "$(shasum -a 256 "$bundle" | cut -d' ' -f1)" == "$SDK_SHA256" ]] \
  || die "$bundle does not match its published checksum; remove it to download again"

# the source tree is recreated each run so a removed file cannot reach the build; the named volume keeps the
# installed SDK and SwiftPM's scratch path, at the same tree path so its incremental state stays valid; the tree and
# the scratch path are per architecture, so two builds can run at once
docker run --rm --cpus 8 -v "$ROOT:/src:ro" -v "$bundle:/sdk.tar.gz:ro" -v agterm-server-build:/build -v "$out:/out" \
  -e SDK="$SDK" -e ARCH="$arch" -e VERSION="$version" "$SWIFT_IMAGE" bash -euo pipefail -c '
    swift sdk list --swift-sdks-path /build/sdks | grep -qx "$SDK" \
      || swift sdk install --swift-sdks-path /build/sdks /sdk.tar.gz >/dev/null
    rm -rf "/build/tree-$ARCH"
    mkdir -p "/build/tree-$ARCH"
    tar -C /src --exclude=./build --exclude=./agtermCore/.build --exclude=./.git --exclude=./agterm/Resources -cf - . \
      | tar -C "/build/tree-$ARCH" -xf -
    cd "/build/tree-$ARCH/agtermCore"
    stamp=Sources/AgtermServerKit/ServerVersion.swift
    sed -i "s/public static let current = \"0.0.0\"/public static let current = \"$VERSION\"/" "$stamp"
    grep -q "public static let current = \"$VERSION\"" "$stamp" || { echo "server-build: could not stamp $VERSION" >&2; exit 2; }
    build=(swift build -c release --swift-sdks-path /build/sdks --swift-sdk "$ARCH-swift-linux-musl"
      --scratch-path "/build/scratch-musl-$ARCH"
      -Xlinker --strip-all)
    "${build[@]}" --product agterm-server
    "${build[@]}" --product agtermctl
    cp "$("${build[@]}" --show-bin-path)/agterm-server" "$("${build[@]}" --show-bin-path)/agtermctl" /out/
  '
[[ -x "$out/agterm-server" && -x "$out/agtermctl" ]] || die "the $arch build left no binaries in $out"
# only the architecture Docker runs natively can be executed here; the other keeps the source stamp checked above
if [[ "$(docker info --format '{{.Architecture}}')" == "$arch" ]]; then
  reported="$(docker run --rm -v "$out:/out:ro" "$CHECK_IMAGE" /out/agterm-server --version)"
  [[ "$reported" == "$version" ]] || die "the $arch agterm-server reports version $reported, not $version"
else
  echo "server-build: $arch is not this Docker's native architecture; its version is checked by the source stamp only"
fi
echo "built $out"
