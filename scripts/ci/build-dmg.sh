#!/usr/bin/env bash
# Build the launcher from this checkout and package it with the pinned Apple Silicon runtime.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $(uname -sm) == "Darwin arm64" ]] || { echo "Run on an Apple Silicon Mac." >&2; exit 1; }
source scripts/ci/runtime.env
out="$PWD/work/out"
mkdir -p "$out/dist"
stage=$(mktemp -d "$out/.dmg.XXXXXXXX")
mounted=0
cleanup() {
    if [[ $mounted == 1 ]]; then hdiutil detach "$stage/mount" -quiet || return; fi
    rm -rf "$stage"
}
trap cleanup EXIT

curl --fail --location --silent --show-error --retry 3 "$STELLA_RUNTIME_URL" -o "$stage/runtime.tar.gz"
echo "$STELLA_RUNTIME_SHA256  $stage/runtime.tar.gz" | shasum -a 256 -c -
export STELLA_PINNED_RUNTIME="$stage/runtime"
export KRUN_PREFIX="$STELLA_PINNED_RUNTIME"
mkdir "$STELLA_PINNED_RUNTIME"
tar -xzf "$stage/runtime.tar.gz" -C "$STELLA_PINNED_RUNTIME"
python3 scripts/ci/runtime.py verify "$STELLA_PINNED_RUNTIME" "$STELLA_PINNED_RUNTIME/guest"
STEAMAC_NO_BUNDLE=1 host/launcher/build.sh
host/launcher/bundle.sh "$out/steamac-vm"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$out/Stella.app/Contents/Info.plist")
name="Stella-$version-arm64.dmg"
mkdir "$stage/image" "$stage/mount"
ditto "$out/Stella.app" "$stage/image/Stella.app"
ln -s /Applications "$stage/image/Applications"
hdiutil create -quiet -volname Stella -srcfolder "$stage/image" -fs HFS+ -format UDZO "$stage/$name"
hdiutil verify "$stage/$name"
hdiutil attach "$stage/$name" -mountpoint "$stage/mount" -readonly -nobrowse -quiet
mounted=1
app="$stage/mount/Stella.app"
[[ $(readlink "$stage/mount/Applications") == /Applications ]]
[[ $(lipo -archs "$app/Contents/MacOS/steamac-vm") == arm64 ]]
codesign --verify --deep --strict "$app"
codesign -d --entitlements - --xml "$app" 2>/dev/null |
    python3 -c 'import plistlib, sys; sys.exit(plistlib.load(sys.stdin.buffer).get("com.apple.security.hypervisor") is not True)'
"$app/Contents/MacOS/steamac-vm" --help > /dev/null
hdiutil detach "$stage/mount" -quiet
mounted=0
mv -f "$stage/$name" "$out/dist/$name"
shasum -a 256 "$out/dist/$name"
